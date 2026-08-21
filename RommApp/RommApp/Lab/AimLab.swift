import SwiftUI
import Network

/// The feel test for the phone-as-controller idea. A latency percentile
/// answers "how late", which turns out not to be the question anybody
/// cares about; this answers "does moving my hand feel connected to that
/// crosshair", which is the only thing that decides whether the feature
/// is worth building.
///
/// Phone shows a control surface and no game video, exactly as the idea
/// doc insists. Drag to aim, lift your finger to shoot. TV draws the
/// crosshair and the targets.
///
/// Launch (DEBUG only, both sides):
///   TV:    -cabinetAim receive
///   phone: -cabinetAim send
///
/// Transport is plain LAN UDP with peer-to-peer deliberately off and the
/// Bonjour browse cancelled the instant a peer is found. Both of those
/// are the point rather than housekeeping: a live browse or a p2p flag
/// keeps AWDL awake, and AWDL hops the radio off-channel for 50-100ms
/// about once a second, which is what ruined the first night of
/// measurements and made plain WiFi look unusable when it had never
/// actually been tested.
///
/// The shot coordinate is stamped at the instant of release and travels
/// in the same packet as the trigger, so transport delay can change when
/// a shot registers but never where it lands. That is the one design
/// idea from the doc worth keeping regardless of what the link measures.
enum AimLab {
    enum Role { case send, receive }

    static let bonjourType = "_cabinet-probe._udp"
    static let sendHz = 100.0

    static let launchRole: Role? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-cabinetAim"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "send": return .send
        case "receive": return .receive
        default: return nil
        }
    }()

    static func nowMS() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}

/// 20 bytes: magic, kind (0 aim, 1 shot), flags, pad, seq u32,
/// sendTime u64, x i16, y i16. Coordinates are normalised to
/// -32767...32767 across the phone's usable surface.
struct AimPacket {
    static let size = 20
    static let magic: UInt8 = 0xCC

    var kind: UInt8
    var seq: UInt32
    var sendTimeNS: UInt64
    var x: Int16
    var y: Int16

    func encoded() -> Data {
        var d = Data(capacity: Self.size)
        d.append(Self.magic); d.append(kind); d.append(0); d.append(0)
        withUnsafeBytes(of: seq.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: sendTimeNS.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: y.littleEndian) { d.append(contentsOf: $0) }
        return d
    }

    init(kind: UInt8, seq: UInt32, sendTimeNS: UInt64, x: Int16, y: Int16) {
        self.kind = kind; self.seq = seq; self.sendTimeNS = sendTimeNS; self.x = x; self.y = y
    }

    init?(_ data: Data) {
        guard data.count >= Self.size, data[data.startIndex] == Self.magic else { return nil }
        let b = data.startIndex
        kind = data[b + 1]
        seq = data.subdata(in: b+4..<b+8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        sendTimeNS = data.subdata(in: b+8..<b+16).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
        x = Int16(littleEndian: data.subdata(in: b+16..<b+18).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        y = Int16(littleEndian: data.subdata(in: b+18..<b+20).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
    }
}

/// 1-Euro filter (Casiez et al.): a low-pass whose cutoff rises with
/// speed, so a still hand gets heavy smoothing and no visible tremor
/// while a fast sweep passes through nearly raw. The standard answer for
/// pointing devices; a fixed blend has to pick one of those and lose the
/// other.
final class OneEuro {
    private var lastValue: Double?
    private var lastDeriv = 0.0
    private var lastT: Double?
    /// Tuned for aiming rather than drawing: the floor keeps a resting
    /// hand steady, and the high beta opens the filter almost completely
    /// the moment the hand actually moves, so smoothing never reads as
    /// drag during a sweep.
    private let minCutoff = 1.8, beta = 0.6, dCutoff = 1.0

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    func filter(_ value: Double, at tMS: Double) -> Double {
        let t = tMS / 1000
        guard let lv = lastValue, let lt = lastT, t > lt else {
            lastValue = value; lastT = t; return value
        }
        let dt = t - lt
        let deriv = (value - lv) / dt
        lastDeriv += alpha(dCutoff, dt) * (deriv - lastDeriv)
        let cutoff = minCutoff + beta * abs(lastDeriv)
        let out = lv + alpha(cutoff, dt) * (value - lv)
        lastValue = out; lastT = t
        return out
    }
}

private func udpParameters() -> NWParameters {
    let p = NWParameters.udp
    // Off, on purpose. See the note at the top of this file.
    p.includePeerToPeer = false
    p.serviceClass = .interactiveVoice
    return p
}

// MARK: - Phone

#if os(iOS)
import CoreMotion

/// Gyro aiming, which is the actual thing being tested: does pointing a
/// phone at a TV feel like pointing at a TV.
///
/// Attitude comes from `.xArbitraryZVertical`, deliberately not a
/// magnetic-north frame. A television is a large magnet next to a large
/// speaker magnet, so heading based on the magnetometer is unusable in
/// exactly the place this has to work. The cost of that choice is that
/// yaw has no absolute reference and drifts, which is why recentring is a
/// first-class control here rather than a nicety.
final class AimSender: ObservableObject {
    @Published var status = "looking for the TV"
    @Published var connected = false
    @Published var shots = 0
    /// Degrees of rotation that span half the screen. Small numbers mean
    /// a twitchy, wrist-scale aim; large numbers mean whole-arm sweeps.
    /// Exposed because the right value depends on how far the couch is
    /// from the television, which no default can know.
    @Published var degreesToEdge: Double = 14
    @Published var invertY = false
    @Published var invertX = false

    /// Mouse is the Magic Remote model, rate control with edge
    /// re-anchoring. Gun is absolute pointing through a two-shot
    /// calibration: fire at the centre of the television, then at the
    /// top-right corner of the picture, and the mapping, including axis
    /// signs and your distance from the set, falls out of those two
    /// measurements the way arcade lightguns always did it.
    enum Mode: String, CaseIterable {
        case mouse = "Mouse", gun = "Gun", spinner = "Spin", wheel = "Wheel"
    }
    enum CalStep { case centre, corner, corner2, done }
    @Published var mode: Mode = .mouse
    @Published var calStep: CalStep = .centre

    private let queue = DispatchQueue(label: "cabinet.aim.send", qos: .userInteractive)
    private let motion = CMMotionManager()
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var timer: DispatchSourceTimer?
    private var seq: UInt32 = 0

    private let lock = NSLock()
    /// Air-mouse model, the one LG's Magic Remote uses, not a laser
    /// pointer: the gyro's angular RATE moves the cursor the way a mouse
    /// moves a pointer, and nothing ever asks where the phone is
    /// absolutely aimed. Drift stops mattering because the cursor clamps
    /// at the screen edge and the anchor implicitly re-forms there, the
    /// same reason a mouse never needs recalibrating when it runs out of
    /// desk. It also allows smoothing on velocity, which is invisible,
    /// where smoothing a position always reads as lag.
    private var cursorX = 0.0, cursorY = 0.0
    private var smoothedRateX = 0.0, smoothedRateY = 0.0
    private var attitude: CMAttitude?
    private var centreAttitude: CMAttitude?
    /// Per-axis tangent spans, averaged from the two corner shots so one
    /// slightly missed shot skews the map by half as much.
    private var tanU = 0.0, tanV = 0.0
    private var trU = 0.0, trV = 0.0
    /// Aim history for trigger rewind: the tap that fires also tips the
    /// phone, so a shot is scored where you aimed 70ms before contact,
    /// the same trick arcade guns and Wii shooters used.
    private var history: [(t: Double, x: Double, y: Double)] = []
    /// Spinner and wheel both produce a single bounded axis, which is what
    /// a dial or a steering column actually is: not a position on screen.
    private var axis = 0.0
    private var zeroRoll: Double?
    private var rollAngle = 0.0
    private let euroX = OneEuro(), euroY = OneEuro()

    func start() {
        let browser = NWBrowser(for: .bonjour(type: AimLab.bonjourType, domain: nil), using: udpParameters())
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let first = results.first else { return }
            self.connect(to: first.endpoint)
            self.browser?.cancel()
            self.browser = nil
        }
        browser.start(queue: queue)
        startMotion()
        startTimer()
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else {
            DispatchQueue.main.async { self.status = "no motion sensors" }
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / AimLab.sendHz
        let q = OperationQueue()
        q.qualityOfService = .userInteractive
        // Serial, which CoreMotion's own docs require: the default queue
        // concurrency is unlimited, so update handlers ran in parallel
        // and wrote attitude samples out of order. Invisible while the
        // hand moves slowly, since neighbouring samples are nearly
        // equal; a fast sweep interleaves samples that differ a lot and
        // the crosshair visibly time-travels.
        q.maxConcurrentOperationCount = 1
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: q) { [weak self] m, _ in
            guard let self, let m else { return }
            // The horizontal sweep is rotation about GRAVITY, not about
            // the phone's own z axis: measured in the device frame, a
            // naturally uptilted phone leaks part of every sweep into an
            // axis that was not being read, so the cursor slowed down as
            // the hand relaxed. Projecting the rotation rate onto the
            // gravity vector makes posture irrelevant.
            let g = m.gravity
            let sweep = m.rotationRate.x * g.x + m.rotationRate.y * g.y + m.rotationRate.z * g.z
            let dt = 1.0 / AimLab.sendHz
            let alpha = 0.35 // rate smoothing, invisible at this cadence
            self.lock.lock()
            self.smoothedRateX += alpha * (sweep - self.smoothedRateX)
            self.smoothedRateY += alpha * (-m.rotationRate.x - self.smoothedRateY)
            let gn = self.gain(self.smoothedRateX, self.smoothedRateY)
            self.cursorX = min(1, max(-1, self.cursorX + self.smoothedRateX * gn * dt))
            // 1.7x: the screen is roughly half as tall as it is wide, and
            // matching normalized gains made the same wrist arc cover far
            // less picture vertically. This equalises inches per degree.
            self.cursorY = min(1, max(-1, self.cursorY + self.smoothedRateY * gn * 1.7 * dt * (self.invertY ? -1 : 1)))
            self.attitude = m.attitude.copy() as? CMAttitude
            // Roll straight off gravity: absolute, drift-free, and
            // unaffected by how the phone is yawed relative to the TV,
            // which is the whole reason a wheel is easier than a gun.
            self.rollAngle = atan2(g.x, -g.y)
            if self.mode == .wheel {
                let zero = self.zeroRoll ?? self.rollAngle
                if self.zeroRoll == nil { self.zeroRoll = zero }
                var d = self.rollAngle - zero
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                let full = 40.0 * .pi / 180
                self.axis = max(-1, min(1, d / full))
            }
            self.lock.unlock()
        }
    }

    /// Point at the middle of the television, then call this. Everything
    /// after is measured from here.
    /// Snaps the cursor to the middle. With rate control this is a
    /// convenience rather than a necessity, kept because it is also how a
    /// player would find a lost cursor.
    func recenter() {
        lock.lock(); cursorX = 0; cursorY = 0; axis = 0; zeroRoll = nil; lock.unlock()
    }

    /// Mouse-style acceleration: slow rotation is precise, a flick
    /// crosses the screen. Sensitivity comes from the sweep slider, kept
    /// so the couch distance is still tunable.
    private func gain(_ rx: Double, _ ry: Double) -> Double {
        let speed = (rx * rx + ry * ry).squareRoot()
        let base = 9.0 / max(degreesToEdge, 3)
        return base * (1 + min(speed, 6) * 0.45)
    }

    /// Pointing direction relative to the centre-shot reference, as a
    /// horizontal and vertical angle pair. Small rotations only in
    /// practice, since the whole screen spans a few degrees of wrist.
    private func gunUV() -> (Double, Double)? {
        guard let a = attitude?.copy() as? CMAttitude, let c = centreAttitude else { return nil }
        a.multiply(byInverseOf: c)
        return (-a.yaw, a.pitch)
    }

    /// Thumb rotation on the pad, click-wheel style. Bounded rather than
    /// free-spinning because the games this serves (Arkanoid's paddle,
    /// Tempest's ring position) map a dial onto a bounded position.
    func spin(byRadians d: Double) {
        lock.lock()
        let turns = max(degreesToEdge, 5) / 14
        axis = max(-1, min(1, axis + d / (turns * 2 * .pi) * 2))
        lock.unlock()
    }

    func axisValue() -> Double { lock.lock(); defer { lock.unlock() }; return axis }

    func resetAxis() { lock.lock(); axis = 0; zeroRoll = nil; lock.unlock() }

    private func currentAim() -> (Double, Double) {
        lock.lock(); defer { lock.unlock() }
        if mode == .spinner || mode == .wheel { return (axis, 0) }
        if mode == .gun {
            guard calStep == .done, let (u, v) = gunUV() else { return (0, 0) }
            // Tangent projection, because the screen is flat and equal
            // angles do not cover equal inches of it: linear mapping put
            // edge shots visibly inside where the phone pointed.
            let now = AimLab.nowMS()
            let x = euroX.filter(tan(u) / tanU, at: now)
            let y = euroY.filter(-(tan(v) / tanV), at: now)
            let cx = max(-1, min(1, x)), cy = max(-1, min(1, y))
            history.append((now, cx, cy))
            if history.count > 32 { history.removeFirst(history.count - 32) }
            return (cx, cy)
        }
        return (invertX ? -cursorX : cursorX, cursorY)
    }

    /// Aim roughly 70ms before now, for scoring a shot.
    private func rewoundAim() -> (Double, Double)? {
        let cutoff = AimLab.nowMS() - 70
        return history.last(where: { $0.t <= cutoff }).map { ($0.x, $0.y) }
    }

    /// Tells the TV where to draw the calibration ring. A sentinel of
    /// (32767, 32767) clears it. Sent three times because UDP.
    private func sendCalTarget(_ x: Int16, _ y: Int16) {
        queue.async {
            self.seq &+= 1
            let p = AimPacket(kind: 2, seq: self.seq,
                              sendTimeNS: DispatchTime.now().uptimeNanoseconds, x: x, y: y)
            let d = p.encoded()
            for _ in 0..<3 { self.connection?.send(content: d, completion: .idempotent) }
        }
    }

    func announceMode() {
        queue.async {
            self.seq &+= 1
            let raw: Int16 = self.mode == .spinner ? 1 : (self.mode == .wheel ? 2 : 0)
            let p = AimPacket(kind: 3, seq: self.seq,
                              sendTimeNS: DispatchTime.now().uptimeNanoseconds, x: raw, y: 0)
            let d = p.encoded()
            for _ in 0..<3 { self.connection?.send(content: d, completion: .idempotent) }
        }
    }

    func announceCalStep() {
        announceMode()
        switch (mode, calStep) {
        case (.gun, .centre):  sendCalTarget(0, 0)
        case (.gun, .corner):  sendCalTarget(32767 / 4 * 3, -32767 / 4 * 3)
        case (.gun, .corner2): sendCalTarget(-32767 / 4 * 3, 32767 / 4 * 3)
        default:               sendCalTarget(32767, 32767)
        }
    }

    /// The two calibration pulls. Returns true when the pull was consumed
    /// by calibration rather than being a shot.
    func calibrationPull() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard mode == .gun, calStep != .done else { return false }
        switch calStep {
        case .centre:
            centreAttitude = attitude?.copy() as? CMAttitude
            DispatchQueue.main.async { self.calStep = .corner; self.announceCalStep() }
        case .corner:
            // Top-right of the picture, screen (+1, -1).
            guard let (u, v) = gunUV(), abs(u) > 0.005, abs(v) > 0.005 else { return true }
            trU = tan(u); trV = tan(v)
            DispatchQueue.main.async { self.calStep = .corner2; self.announceCalStep() }
        case .corner2:
            // Bottom-left, screen (-1, +1): the mirror measurement, so the
            // per-axis span is the average of two shots rather than one.
            guard let (u, v) = gunUV(), abs(u) > 0.005, abs(v) > 0.005 else { return true }
            // The rings sit at 0.75 of the way to each corner, kept off
            // the very edge so they are comfortably visible, so the
            // measured span covers 0.75 of a screen unit, not 1.0.
            tanU = (trU - tan(u)) / 2 / 0.75
            tanV = (trV - tan(v)) / 2 / 0.75
            guard abs(tanU) > 0.003, abs(tanV) > 0.003 else { return true }
            DispatchQueue.main.async { self.calStep = .done; self.announceCalStep() }
        case .done: break
        }
        return true
    }

    func recalibrate() {
        lock.lock(); centreAttitude = nil; tanU = 0; tanV = 0; history.removeAll(); lock.unlock()
        calStep = .centre
        announceCalStep()
    }

    private static func q(_ v: Double) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }

    /// Sent the moment the trigger is pulled rather than on the next tick,
    /// carrying the aim sampled in the same breath. Transport delay can
    /// then change when the shot registers but never where it lands.
    /// Three copies because this is UDP and a dropped trigger is the one
    /// lost packet a player would actually feel.
    func shoot() {
        if calibrationPull() { return }
        lock.lock()
        let rewound = mode == .gun ? rewoundAim() : nil
        lock.unlock()
        let (x, y) = rewound ?? currentAim()
        queue.async {
            self.seq &+= 1
            let p = AimPacket(kind: 1, seq: self.seq,
                              sendTimeNS: DispatchTime.now().uptimeNanoseconds,
                              x: Self.q(x), y: Self.q(y))
            let data = p.encoded()
            for _ in 0..<3 { self.connection?.send(content: data, completion: .idempotent) }
        }
        DispatchQueue.main.async { self.shots += 1 }
    }

    private func connect(to endpoint: NWEndpoint) {
        let c = NWConnection(to: endpoint, using: udpParameters())
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.status = "connected, point at the middle and recentre"
                    self?.connected = true
                case .failed(let e):
                    self?.status = "failed: \(e)"; self?.connected = false
                default: break
                }
            }
        }
        c.start(queue: queue)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer = t
        t.schedule(deadline: .now(), repeating: 1.0 / AimLab.sendHz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in
            guard let self, let c = self.connection, c.state == .ready else { return }
            let (x, y) = self.currentAim()
            self.seq &+= 1
            let p = AimPacket(kind: 0, seq: self.seq,
                              sendTimeNS: DispatchTime.now().uptimeNanoseconds,
                              x: Self.q(x), y: Self.q(y))
            c.send(content: p.encoded(), completion: .idempotent)
        }
        t.resume()
    }

    func stop() {
        timer?.cancel(); connection?.cancel(); browser?.cancel()
        motion.stopDeviceMotionUpdates()
    }
}

/// A click wheel. Thumb angle around the centre drives the dial, and a
/// light haptic fires every detent, which is what gives a virtual spinner
/// the sense of mass and notches that a real one has from its bearing.
/// Detents are spaced in finger travel, not in output, so they feel even
/// regardless of sensitivity.
private struct SpinPad: View {
    @ObservedObject var sender: AimSender
    @State private var lastAngle: Double?
    @State private var detentAccum = 0.0
    @State private var visual = 0.0
    private let detent = UIImpactFeedbackGenerator(style: .light)
    private static let detentStep = 14.0 * .pi / 180

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 26)
                ForEach(0..<24, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.25))
                        .frame(width: 3, height: 12)
                        .offset(y: -(min(geo.size.width, geo.size.height) / 2 - 13))
                        .rotationEffect(.degrees(Double(i) * 15))
                }
                Circle().fill(Color.orange)
                    .frame(width: 26, height: 26)
                    .offset(y: -(min(geo.size.width, geo.size.height) / 2 - 13))
                    .rotationEffect(.radians(visual))
                Text(String(format: "%+.2f", sender.axisValue()))
                    .font(.title3.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x))
                        defer { lastAngle = a }
                        guard let last = lastAngle else { return }
                        var d = a - last
                        while d > .pi { d -= 2 * .pi }
                        while d < -.pi { d += 2 * .pi }
                        // A jump this large is a finger lift and replace,
                        // not a spin; feeding it would fling the dial.
                        guard abs(d) < 1.0 else { return }
                        sender.spin(byRadians: d)
                        visual += d
                        detentAccum += abs(d)
                        if detentAccum >= Self.detentStep {
                            detentAccum = 0
                            detent.impactOccurred(intensity: 0.7)
                        }
                    }
                    .onEnded { _ in lastAngle = nil; detentAccum = 0 }
            )
        }
    }
}

/// Hold the phone like a remote, top edge towards the television. The
/// screen shows no game video at all, which is the idea doc's rule and
/// also the reason this can be looked away from: everything you need to
/// see is on the TV.
struct AimSenderView: View {
    @StateObject private var sender = AimSender()
    @State private var flash = false
    @State private var firing = false
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)

    private var prompt: String {
        if sender.mode == .spinner { return "Drag in circles on the wheel. Tap FIRE to launch." }
        if sender.mode == .wheel { return "Hold sideways and tilt like a wheel. Recentre sets straight-ahead." }
        guard sender.mode == .gun else { return "Sweep to aim. Tap to shoot." }
        switch sender.calStep {
        case .centre: return "Point at the ring on the TV and pull the trigger. A phone has no barrel: any pointing habit works, just use the same one for all three."
        case .corner: return "Now the second ring. Same grip, same habit."
        case .corner2: return "Last ring."
        case .done:   return "Calibrated. Point and shoot."
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 22) {
                Text("Cabinet aim test").font(.headline).foregroundStyle(.white)
                Text(sender.status).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Picker("mode", selection: $sender.mode) {
                    ForEach(AimSender.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: sender.mode) { _, _ in
                    sender.resetAxis()
                    sender.announceCalStep()
                }

                Text(prompt).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)

                if sender.mode == .spinner {
                    SpinPad(sender: sender)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // The whole middle of the screen is the trigger, so it can
                // be found with a thumb without looking down.
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(flash ? Color.orange : Color.white.opacity(0.10))
                    Text("FIRE").font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: sender.mode == .spinner ? 90 : .infinity)
                .contentShape(Rectangle())
                // A tap gesture fires on finger-up; a trigger should fire
                // on contact. DragGesture with zero distance reports the
                // touch the moment it lands.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !firing else { return }
                            firing = true
                            haptic.impactOccurred()
                            sender.shoot()
                            flash = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { flash = false }
                        }
                        .onEnded { _ in firing = false }
                )

                Button {
                    if sender.mode == .gun { sender.recalibrate() } else { sender.recenter() }
                } label: {
                    Text(sender.mode == .gun ? "Recalibrate" : "Recentre").font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(.white)
                }

                VStack(spacing: 6) {
                    HStack {
                        Text("sweep").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $sender.degreesToEdge, in: 5...45)
                        Text("\(Int(sender.degreesToEdge))°").font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary).frame(width: 34)
                    }
                    HStack(spacing: 18) {
                        Toggle("Invert V", isOn: $sender.invertY)
                        Toggle("Invert H", isOn: $sender.invertX)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text("\(sender.shots) shots").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .padding(.top, 40)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true; sender.start() }
        .onDisappear { sender.stop() }
    }
}
#endif

// MARK: - TV

/// Position lives in plain vars behind a lock and is read once per drawn
/// frame, never published. Publishing at the packet rate would invalidate
/// SwiftUI a hundred times a second and manufacture exactly the stutter
/// this screen exists to look for.
final class AimReceiver: ObservableObject {
    @Published var status = "waiting for a phone"
    @Published var score = 0
    @Published var misses = 0
    @Published var linkNote = ""

    struct Target: Identifiable { let id = UUID(); var x: Double; var y: Double; var r: Double }

    private let lock = NSLock()
    private var x = 0.0, y = 0.0
    private var vx = 0.0, vy = 0.0
    private var lastAimAt = 0.0
    private var lastSeq: UInt32 = 0
    private var calTarget: (x: Double, y: Double)?
    /// 0 pointer, 1 dial, 2 wheel. Decides which instrument this screen
    /// draws, announced by the phone so the two never disagree.
    private var instrument: Int16 = 0
    private var ball = (x: 0.0, y: -0.3, vx: 0.62, vy: 0.78)
    private var lastTick = AimLab.nowMS()
    private var lastShot: (x: Double, y: Double, at: Double)?
    private(set) var targets: [Target] = []

    private let queue = DispatchQueue(label: "cabinet.aim.recv", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var arrivals: [Double] = []
    private var packets = 0

    init() {
        targets = (0..<4).map { _ in Self.randomTarget() }
    }

    private static func randomTarget() -> Target {
        Target(x: Double.random(in: -0.75...0.75), y: Double.random(in: -0.6...0.6), r: 0.075)
    }

    /// The crosshair is drawn ahead of the last packet along its own
    /// velocity, covering the age of that packet plus roughly two frames
    /// of display pipeline. Right for every smooth motion, cheap for
    /// reversals, and the reason streamed games feel closer than their
    /// latency says. Capped so a stale packet cannot fling it.
    func aimPoint() -> (Double, Double) {
        lock.lock(); defer { lock.unlock() }
        let age = min((AimLab.nowMS() - lastAimAt) + 33, 80) / 1000
        return (max(-1, min(1, x + vx * age)), max(-1, min(1, y + vy * age)))
    }

    func instrumentKind() -> Int16 { lock.lock(); defer { lock.unlock() }; return instrument }

    /// A ball to actually chase, because a dial with nothing to track
    /// tells you nothing about whether the dial is any good. Stepped from
    /// the draw loop, which is accurate enough for a feel test.
    func stepBall() -> (bx: Double, by: Double, paddle: Double) {
        lock.lock(); defer { lock.unlock() }
        let now = AimLab.nowMS()
        let dt = min((now - lastTick) / 1000, 0.05)
        lastTick = now
        let paddle = x
        guard instrument != 0 else { return (ball.x, ball.y, paddle) }
        ball.x += ball.vx * dt; ball.y += ball.vy * dt
        if ball.x < -1 { ball.x = -1; ball.vx = abs(ball.vx) }
        if ball.x > 1 { ball.x = 1; ball.vx = -abs(ball.vx) }
        if ball.y < -1 { ball.y = -1; ball.vy = abs(ball.vy) }
        if ball.y > 0.86 {
            if abs(ball.x - paddle) < 0.18 {
                ball.vy = -abs(ball.vy)
                // Angle off the paddle by where it struck, the thing that
                // makes a paddle game a game rather than a reflex test.
                ball.vx += (ball.x - paddle) * 1.6
                ball.vx = max(-1.4, min(1.4, ball.vx))
                ball.y = 0.86
            } else if ball.y > 1.15 {
                ball = (0, -0.3, ball.vx < 0 ? -0.62 : 0.62, 0.78)
            }
        }
        return (ball.x, ball.y, paddle)
    }

    func calibrationTarget() -> (Double, Double)? {
        lock.lock(); defer { lock.unlock() }; return calTarget
    }

    func recentShot() -> (x: Double, y: Double, age: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = lastShot else { return nil }
        let age = (AimLab.nowMS() - s.at) / 1000
        return age < 0.5 ? (s.x, s.y, age) : nil
    }

    func start() {
        guard let l = try? NWListener(using: udpParameters()) else {
            DispatchQueue.main.async { self.status = "could not open the listener" }
            return
        }
        listener = l
        l.service = NWListener.Service(name: "CabinetAim", type: AimLab.bonjourType)
        l.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.connections.append(c)
            self.receive(on: c)
            c.start(queue: self.queue)
            DispatchQueue.main.async { self.status = "phone connected" }
        }
        l.start(queue: queue)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let p = AimPacket(data) { self.handle(p) }
            if error == nil { self.receive(on: c) }
        }
    }

    private func handle(_ p: AimPacket) {
        let nx = Double(p.x) / 32767, ny = Double(p.y) / 32767
        let now = AimLab.nowMS()

        if p.kind == 3 {
            lock.lock(); instrument = p.x; ball = (0, -0.3, 0.62, 0.78); lock.unlock()
            return
        }

        if p.kind == 2 {
            lock.lock()
            calTarget = (p.x == 32767 && p.y == 32767) ? nil : (nx, ny)
            lock.unlock()
            return
        }

        lock.lock()
        // UDP does not promise ordering even on one LAN, and an aim
        // packet applied after a newer one snaps the crosshair backwards,
        // felt as jumping during fast sweeps. Aim packets older than the
        // newest seen are dropped; shots are never dropped, they are too
        // rare to reorder and losing one costs a hit. The distance check
        // lets a phone relaunch, whose seq restarts near zero, take over
        // without waiting for the counter to catch up.
        let stale = p.seq < lastSeq && lastSeq - p.seq < 1000
        if stale && p.kind == 0 { lock.unlock(); return }
        if !stale { lastSeq = p.seq }
        if p.kind == 0 {
            let dt = (now - lastAimAt) / 1000
            if dt > 0.001 && dt < 0.2 {
                // Blended rather than raw so one packet's jitter does not
                // become the whole prediction.
                vx += 0.5 * ((nx - x) / dt - vx)
                vy += 0.5 * ((ny - y) / dt - vy)
            } else { vx = 0; vy = 0 }
            lastAimAt = now
        }
        x = nx; y = ny
        var hit = false
        if p.kind == 1 {
            lastShot = (nx, ny, now)
            if let i = targets.firstIndex(where: { hypot($0.x - nx, $0.y - ny) < $0.r }) {
                targets[i] = Self.randomTarget()
                hit = true
            }
        }
        lock.unlock()

        // Link health, sampled rather than published per packet.
        arrivals.append(now)
        packets += 1
        if packets % 50 == 0 {
            let gaps = zip(arrivals, arrivals.dropFirst()).map { $1 - $0 }
            arrivals.removeAll(keepingCapacity: true)
            let worst = gaps.max() ?? 0
            let note = String(format: "worst gap %.0f ms in the last half second", worst)
            DispatchQueue.main.async { self.linkNote = note }
        }

        if p.kind == 1 {
            DispatchQueue.main.async {
                if hit { self.score += 1 } else { self.misses += 1 }
            }
        }
    }

    func stop() { listener?.cancel(); connections.forEach { $0.cancel() } }
}

struct AimReceiverView: View {
    @StateObject private var receiver = AimReceiver()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                TimelineView(.animation) { _ in
                    Canvas { ctx, size in
                        func point(_ nx: Double, _ ny: Double) -> CGPoint {
                            CGPoint(x: (nx + 1) / 2 * size.width, y: (ny + 1) / 2 * size.height)
                        }
                        for t in receiver.targets {
                            let c = point(t.x, t.y)
                            let r = t.r * size.width / 2
                            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)),
                                       with: .color(.orange), lineWidth: 6)
                        }
                        if let s = receiver.recentShot() {
                            let c = point(s.x, s.y)
                            let r = 18 + s.age * 120
                            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)),
                                       with: .color(.white.opacity(1 - s.age * 2)), lineWidth: 3)
                        }
                        let kind = receiver.instrumentKind()
                        if kind != 0 {
                            let (bx, by, paddle) = receiver.stepBall()
                            let pc = point(paddle, 0.92)
                            let w = 0.18 * size.width / 2
                            ctx.fill(Path(roundedRect: CGRect(x: pc.x - w, y: pc.y - 9, width: w*2, height: 18),
                                          cornerRadius: 9), with: .color(kind == 2 ? .cyan : .green))
                            let b = point(bx, by)
                            ctx.fill(Path(ellipseIn: CGRect(x: b.x - 12, y: b.y - 12, width: 24, height: 24)),
                                     with: .color(.orange))
                            return
                        }
                        if let (tx, ty) = receiver.calibrationTarget() {
                            let c = point(tx, ty)
                            for r in [26.0, 52.0] {
                                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r*2, height: r*2)),
                                           with: .color(.cyan), lineWidth: 5)
                            }
                            return
                        }
                        let (ax, ay) = receiver.aimPoint()
                        let c = point(ax, ay)
                        ctx.stroke(Path { p in
                            p.move(to: CGPoint(x: c.x - 34, y: c.y)); p.addLine(to: CGPoint(x: c.x + 34, y: c.y))
                            p.move(to: CGPoint(x: c.x, y: c.y - 34)); p.addLine(to: CGPoint(x: c.x, y: c.y + 34))
                        }, with: .color(.green), lineWidth: 4)
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)),
                                   with: .color(.green), lineWidth: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Cabinet aim test").font(.title3).foregroundStyle(.white)
                    Text(receiver.status).foregroundStyle(.secondary)
                    Text("hits \(receiver.score)   misses \(receiver.misses)")
                        .font(.title3.monospacedDigit()).foregroundStyle(.white)
                    Text(receiver.linkNote).font(.caption).foregroundStyle(.secondary)
                }
                .padding(50)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onAppear { receiver.start() }
            .onDisappear { receiver.stop() }
        }
        .ignoresSafeArea()
    }
}
