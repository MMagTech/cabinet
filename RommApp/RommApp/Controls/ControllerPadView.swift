#if os(iOS)
import CoreMotion
import AVFoundation
import CoreHaptics
import SwiftUI

/// The phone as the steering wheel itself: gravity-referenced roll,
/// turned into the same relative dial counts the touch spinner sends,
/// so the television cannot tell a tilted phone from a spun thumb.
///
/// Relative on purpose. The aim lab's wheel mode feeds cores that read
/// an absolute analog axis; MAME's driving cabinets here are dials, and
/// a dial accumulates. Tracking the CHANGE in roll each tick means no
/// calibration, no drift to matter, and turning the phone half a turn
/// turns the cabinet's wheel about a full one.
final class TiltSteering {
    private let motion = CMMotionManager()
    private var neutral: Double?
    private var sent = 0.0
    /// Counts per radian of roll away from neutral. 768 counts is one
    /// dial turn, so a quarter turn of phone is about full lock, which
    /// keeps both hands inside a comfortable arc.
    private let gain = 244.0
    var send: ((Int) -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        neutral = nil
        sent = 0
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] dm, _ in
            guard let self, let dm else { return }
            // Roll from gravity alone, ABSOLUTE, measured from wherever
            // the phone was held when steering began: that grip is
            // straight ahead, the same calibrate-from-the-hands rule the
            // rotary tilt uses. The first version accumulated relative
            // deltas instead, which meant a long corner wound the phone
            // further and further with no way back: Marcus ended up
            // "in some awkward positions", exactly the wind-up a real
            // wheel's limited travel exists to prevent. Absolute also
            // self-centres: level the phone and the wheel is straight,
            // and gravity never drifts.
            let angle = atan2(dm.gravity.x, dm.gravity.y)
            guard let neutral = self.neutral else { self.neutral = angle; return }
            var away = angle - neutral
            if away > .pi { away -= 2 * .pi }
            if away < -.pi { away += 2 * .pi }
            // Negated: the dial counts the opposite way from the
            // gravity angle in this grip, found on the first live run.
            let target = -away * self.gain
            let delta = Int(target - self.sent)
            if delta != 0 {
                self.sent += Double(delta)
                self.send?(delta)
            }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        neutral = nil
    }
}

/// The phone as the lightgun itself: point it at the television, tap
/// anywhere to fire.
///
/// This is the aim lab's air-mouse model, constants and all, arriving
/// where it was always headed. Rate control rather than absolute
/// pointing (the LG Magic Remote's model, the lab's conclusion after
/// absolute Euler aiming jumped everywhere): the gyro's angular rate
/// moves the crosshair, the edges clamp so drift re-anchors itself,
/// and nothing ever needs calibrating. The horizontal sweep is the
/// rotation projected onto GRAVITY, not the phone's own z axis, so a
/// relaxed, uptilted grip does not slow the cursor: the lab found that
/// leak by feel and the fix by projection.
///
/// The trigger is a touch anywhere, and the shot is scored where the
/// aim was about 70ms BEFORE the tap, because the tap itself nudges
/// the phone: the same rewind arcade guns and Wii shooters used, kept
/// from the lab's gun mode even though the aiming model here is the
/// mouse one.
/// How much wrist crosses the screen, as a named choice rather than a
/// constant that only exists in a source file. "Snap" is the default
/// because Marcus's verdict on anything slower was immediate: shots
/// come from anywhere on the screen, so the response ceiling is the
/// reflex, not the cursor.
enum AimSpeed: String, CaseIterable {
    case relaxed, fast, snap

    static let key = "com.mmagtech.RommApp.linkAimSpeed"

    static var current: AimSpeed {
        AimSpeed(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .snap
    }

    var degreesToEdge: Double {
        switch self {
        case .relaxed: return 12
        case .fast: return 7
        case .snap: return 4.5
        }
    }

    var label: String {
        switch self {
        case .relaxed: return "Relaxed"
        case .fast: return "Fast"
        case .snap: return "Snap"
        }
    }
}

final class GunAim {
    private let motion = CMMotionManager()
    private var smoothedRateX = 0.0, smoothedRateY = 0.0
    /// Where the gun is actually pointed, which is NOT always on the
    /// screen: a reload is a sweep past the bezel, so the aim has to
    /// be allowed off the picture and back without losing anything.
    ///
    /// It used to be clamped in place, and that was the drift. Each
    /// frame integrated from the clamped value, so wrist rotation that
    /// happened while pinned at an edge was thrown away going out and
    /// counted in full coming back: an out-and-back sweep that should
    /// cancel exactly left the aim short by however far past the bezel
    /// it went. Simulated against this same arithmetic: 20 degrees
    /// past the edge came back at -0.36, 40 degrees came back pinned
    /// to the OPPOSITE edge, while the unclamped control returned to
    /// 0.00 every time. Reported by Marcus on Lethal Enforcers, where
    /// it compounds because every reload is by definition a sweep past
    /// the edge.
    ///
    /// Bounded rather than free: two screens of travel is more than
    /// any reload needs and keeps a wild swing from stranding the aim
    /// somewhere it takes a recentre to escape.
    private var aimX = 0.0, aimY = 0.0
    private let aimBound = 2.0
    /// What the game is told, the aim clamped onto the picture.
    private var cursorX: Double { min(1, max(-1, aimX)) }
    private var cursorY: Double { min(1, max(-1, aimY)) }
    /// How far past the picture the gun must point before it counts
    /// as off the screen, so a hair of overshoot on an edge target
    /// never reads as a reload and a deliberate sweep out does.
    private let offscreenThreshold = 0.35
    private(set) var isOffscreen = false
    /// Fired on the edge in and out, so the wire only carries changes.
    var offscreenChanged: ((Bool) -> Void)?
    /// Aim history for the trigger rewind, ~a quarter second of it.
    private var history: [(t: Double, x: Double, y: Double)] = []
    /// Degrees of wrist that span half the screen. The lab's 14 was
    /// tuned for a cursor; a gun is snapped between targets, not
    /// steered, and at 14 Marcus's verdict was "way too slow for being
    /// a gun". 7 doubles the speed; the velocity-scaled gain below
    /// already makes fast flicks faster still.
    var degreesToEdge = AimSpeed.current.degreesToEdge
    /// Continuous aim out, ~60Hz, down = false.
    var aim: ((Double, Double) -> Void)?

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        aimX = 0; aimY = 0
        smoothedRateX = 0; smoothedRateY = 0
        history.removeAll()
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            let g = m.gravity
            let sweep = m.rotationRate.x * g.x + m.rotationRate.y * g.y + m.rotationRate.z * g.z
            let dt = 1.0 / 60.0
            let alpha = 0.35
            smoothedRateX += alpha * (sweep - smoothedRateX)
            smoothedRateY += alpha * (-m.rotationRate.x - smoothedRateY)
            let speed = (smoothedRateX * smoothedRateX + smoothedRateY * smoothedRateY).squareRoot()
            let gain = (9.0 / max(degreesToEdge, 3)) * (1 + min(speed, 6) * 0.45)
            let rawX = aimX + smoothedRateX * gain * dt
            aimX = min(aimBound, max(-aimBound, rawX))
            // 1.7x: the screen is half as tall as it is wide, and equal
            // normalized gains made the same wrist arc cover far less
            // picture vertically.
            let rawY = aimY + smoothedRateY * gain * 1.7 * dt
            aimY = min(aimBound, max(-aimBound, rawY))
            // The reload gesture: the cabinet's own, shoot past the
            // screen. Now that the aim keeps its place off the picture
            // instead of pinning, this is simply where the gun points:
            // a hair past an edge target is not a reload, a deliberate
            // sweep out is. It used to accumulate pressure frame by
            // frame because the clamp left nothing else to measure,
            // and that accumulator would fire almost instantly against
            // a real off-picture distance.
            let off = max(abs(aimX), abs(aimY)) > 1 + offscreenThreshold
            if off != isOffscreen {
                isOffscreen = off
                offscreenChanged?(off)
            }
            let now = Date.timeIntervalSinceReferenceDate as Double
            history.append((now, cursorX, cursorY))
            if history.count > 20 { history.removeFirst(history.count - 20) }
            aim?(cursorX, cursorY)
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }

    /// Wherever the phone points right now becomes the centre of the
    /// screen. Rate control has no absolute reference, so this is not a
    /// calibration, it is a declaration, and it is instant. The lab
    /// called recentring a first-class control; this is that control.
    func recenter() {
        aimX = 0; aimY = 0
        smoothedRateX = 0; smoothedRateY = 0
        if isOffscreen { isOffscreen = false; offscreenChanged?(false) }
        history.removeAll()
        aim?(0, 0)
    }

    /// Where the gun was pointed just before the finger landed.
    func rewoundAim() -> (Double, Double) {
        let target = Date.timeIntervalSinceReferenceDate - 0.07
        let past = history.last { $0.t <= target } ?? history.first
        guard let past else { return (cursorX, cursorY) }
        return (past.x, past.y)
    }
}

/// The phone as the cabinet's control panel, for a game running on the
/// television.
///
/// Deliberately almost nothing: the television says which romset it is
/// running, the same resolution chain the local player uses turns that
/// into a panel, and the same TouchControlPad draws it. The only
/// difference from playing locally is where the five verbs go, which is
/// the entire point: the panel work and the accessory feature are one
/// thing, and everything fixed on one is fixed on the other.
///
/// Reached from Home's TV Controller row, which is also the moment the
/// phone first touches the network: browsing starts when this screen
/// appears and not before, the settled design's rule. The lab's
/// -cabinetLink launch argument opens it directly too.
struct ControllerPadView: View {
    /// True when this panel IS the app, the guest's controller-only
    /// root rather than a screen presented over Home. A root has
    /// nowhere to dismiss to, so the close button is withheld and the
    /// screen's own navigation chrome carries the way out instead.
    /// Defaults to false, so both existing callers behave exactly as
    /// they did.
    var isRoot = false

    @StateObject private var link = ControllerLinkSender()
    /// The DS bottom screen's decoder, inert until the television
    /// offers a stream. Owned here so it survives panel re-renders and
    /// dies with the screen.
    @StateObject private var dsVideo = DSVideoClient()
    /// The warp rumble under the split; see DSWarpHaptics below.
    @State private var warp = DSWarpHaptics()
    /// When the current transit began, and whether the landing has
    /// revealed the picture. The stream is usually ready long before
    /// the performance ends; the reveal waits so the thump and the
    /// bottom screen appearing are always one moment.
    @State private var dsTransitStart: Date?
    @State private var dsRevealed = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    /// The Menu pill's question. Putting the phone down mid-game is the
    /// touch equivalent of unplugging a controller, so it takes a
    /// deliberate answer, never a stray tap or a swipe.
    @State private var confirmingExit = false
    /// Guest root only: this phone has put the controller away and is
    /// deliberately not looking for a television until asked.
    @State private var putAway = false
    /// Tilt steering on the driving cabinets: default off, wheel by
    /// touch, exactly as Marcus specced it. Persisted because a person
    /// who steers by tilt steers by tilt every session.
    @AppStorage("com.mmagtech.RommApp.linkTiltSteering") private var tiltSteering = false
    @State private var tilt = TiltSteering()
    /// The gun is the phone by default: pointing at the television IS
    /// the feature, per Marcus. The toggle drops back to touch aiming
    /// for a couch angle the gyro cannot serve.
    @AppStorage("com.mmagtech.RommApp.linkGyroGun") private var gyroGun = true
    @State private var gunAim = GunAim()
    @State private var triggerHeld = false
    /// The pairing code being typed. Cleared on submit, so a wrong
    /// answer leaves an empty field rather than the failed guess.
    @State private var codeInput = ""
    /// True once searching has lasted long enough to deserve an
    /// explanation; see waitingView.
    @State private var searchHintReady = false
    /// The delayed exact-landscape pin, held so leaving the screen can
    /// cancel it. Untracked, it could fire after the exit's unlock and
    /// leave the whole app wedged in landscape; found on device after
    /// a run of quick reconnects.
    @State private var pinTask: Task<Void, Never>?
    @FocusState private var codeFieldFocused: Bool

    /// True exactly when the pad itself is on screen, which is the
    /// same condition the body draws it under. Kept as one property so
    /// the chrome above can never disagree with what is drawn.
    /// Landscape now, then pinned to whichever landscape it settled
    /// in once the rotation has finished.
    private func goLandscape() {
        OrientationLock.lockToLandscape()
        pinTask?.cancel()
        pinTask = Task {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
            OrientationLock.pinCurrentLandscape()
        }
    }

    private var panelIsLive: Bool {
        !putAway && link.connected && link.shortname != nil
    }

    var body: some View {
        ZStack {
            if putAway {
                putAwayView
            } else {
            // Black belongs to the cabinet panel alone. The states
            // before it, searching, pairing, failing, are app UI and
            // sit on the system background with semantic colors, the
            // way PairingView's flow does. The panel needs a proven
            // session, not just a name: discovery alone sets shortname
            // (the Bonjour service name carries the game), and an
            // unpaired phone must land in code entry, not on a dead
            // panel the television ignores.
            if link.connected, let shortname = link.shortname {
                Color.black.ignoresSafeArea()
                pad(for: shortname)
            } else {
                Color(.systemBackground).ignoresSafeArea()
                switch link.phase {
                case .codeEntry(let triesLeft):
                    pairingEntry(triesLeft: triesLeft)
                case .verifying:
                    waitingView("Checking the code")
                case .ended(let message):
                    endedView(message)
                case .cooldown(let until):
                    cooldownView(until: until)
                case .connected:
                    // Paired through the television's settings screen,
                    // where nothing is playing yet. The panel takes
                    // over on its own when a game starts.
                    pairedIdleView
                default:
                    waitingView(link.status)
                }
            }
            }
        }
        .overlay(alignment: .topLeading) {
            // A way out that exists before a connection does. The live
            // panel keeps the Menu pill as its only door, so putting
            // the phone down mid-game stays a deliberate act; this is
            // for the person who tapped the row with no television
            // playing.
            if link.shortname == nil, !isRoot {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        // Chrome belongs to the states BEFORE the panel, never to the
        // panel itself. A guest's screen needs a title and a menu
        // while it is looking for a television, and needs to be edge
        // to edge black the moment it becomes a control panel, exactly
        // like the phone that arrived here from Home.
        //
        // Getting this wrong is what Marcus saw as N64 looking
        // "squished" on his daughter's phone and not on his: the
        // navigation bar, its large title and the status bar were
        // still there, so her pad was drawn into a shorter box and
        // every normalised height compressed to fit. The four pills
        // along the top took it worst, sitting at 6% where the bar
        // was, which is why the arrangement read as different rather
        // than merely smaller.
        .statusBarHidden(!isRoot || panelIsLive)
        .toolbar(isRoot && !panelIsLive ? .visible : .hidden, for: .navigationBar)
        .navigationTitle(isRoot && !panelIsLive ? "Controller" : "")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            link.start()
        }
        // The landscape lock belongs to the cabinet panel, not to the
        // states before it: searching and code entry follow the device
        // like any screen, and a code is typed on a portrait keyboard.
        // Once the panel exists, force landscape, let the rotation
        // settle, then pin that exact one so tilt steering cannot flip
        // the interface mid-corner.
        .onChange(of: panelIsLive) { _, live in
            guard live else { return }
            goLandscape()
        }
        .task {
            // onChange alone never fires for a value that is ALREADY
            // true when the screen appears, which a fast reconnect or
            // a rebuilt view can both produce. The panel draws
            // landscape controls unconditionally, so missing the lock
            // means drawing them into a portrait box: far worse than
            // the squeeze this file just fixed, and the same shape of
            // bug. Cheap to close, so closed.
            if panelIsLive { goLandscape() }
        }
        .onDisappear {
            pinTask?.cancel()
            pinTask = nil
            OrientationLock.unlock()
            tilt.stop()
            gunAim.stop()
            link.stop()
        }
        .onChange(of: tiltSteering) { _, on in
            if on { tilt.send = { [weak link] dx in link?.relative(dx: dx, dy: 0) }; tilt.start() }
            else { tilt.stop() }
        }
        // Backgrounding kills the UDP flow. Coming back must reconnect
        // by itself: Marcus switched apps on the first live run and came
        // back to a dead panel, which reads as the feature breaking, not
        // as a network event.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { link.wake() }
        }
        .confirmationDialog(
            "Paused", isPresented: $confirmingExit, titleVisibility: .visible
        ) {
            // Every road out of this menu resumes the game except the
            // one that also resumes it: putting the panel away leaves
            // the game running on the television, ready for the remote
            // or for this phone to come back.
            // A guest drives someone else's game, on someone else's
            // server, into someone else's save slots. Saving and
            // loading are the owner's to do, from the television or
            // from their own phone, so a controller-only phone is not
            // offered them at all rather than offered them and
            // refused.
            if !isRoot {
                Button("Save State") {
                    link.saveState()
                    link.pause(false)
                }
                Button("Load Latest State") {
                    link.loadState()
                    link.pause(false)
                }
            }
            Button("Put Away Controller", role: .destructive) {
                link.pause(false)
                // A guest's panel IS the app, so there is nothing to
                // dismiss to and dismiss() did nothing at all. Leaving
                // means leaving the television: say goodbye, drop the
                // link, and rest until this phone asks for another
                // one. Without the resting state the panel would
                // simply find the same television again and walk
                // straight back in.
                if isRoot {
                    link.stop()
                    putAway = true
                } else {
                    dismiss()
                }
            }
            Button("Resume", role: .cancel) {
                link.pause(false)
            }
        }
    }

    /// Which player this phone is, worn where the mode pills live and
    /// in their style. A pad has no opinion about this because a human
    /// plugged it in; a phone says it out loud.
    /// Nothing until this phone has earned a seat. An unseated phone
    /// wearing "P1" would be a lie the moment a second person picks
    /// one up, and the badge appears on the first button anyway.
    @ViewBuilder
    private var playerBadge: some View {
        if let player = link.playerIndex {
            Text("P\(player + 1)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
        }
    }

    /// The phases where the hint about the television's requirements
    /// is the truthful explanation for the wait.
    private var stillLooking: Bool {
        switch link.phase {
        case .searching, .joining: return true
        default: return false
        }
    }

    private func waitingView(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            // The looking state covers four different absences (Wi-Fi
            // off, wrong network, switch off, no game running) and
            // sitting in it silently reads as broken. After a few
            // seconds, name what the television actually requires.
            if searchHintReady, stillLooking {
                Text("On the Apple TV, turn on \u{201C}Allow a phone as a controller\u{201D} in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .transition(.opacity)
            }
        }
        .padding(24)
        .task {
            try? await Task.sleep(for: .seconds(6))
            withAnimation { searchHintReady = true }
        }
    }

    private var pairedIdleView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Paired to your TV")
                .font(.title2.bold())
            // The durable rule, not this screen's mechanics: pairing
            // was the one-time part, and Home is the everyday door.
            // Deliberately no "arcade": the panel is headed for every
            // core by release, per Marcus.
            Text("Whenever a game is playing on your TV, Home will offer the controls.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 460)
        .padding(24)
    }

    /// The passcode-lockout pattern: three wrong codes, a live
    /// countdown in the code's own style, and nothing to press. When
    /// it reaches zero the sender rejoins by itself and a fresh code
    /// appears on the television.
    private func cooldownView(until: Date) -> some View {
        VStack(spacing: 14) {
            Text("Three wrong codes")
                .font(.title2.bold())
            Text(timerInterval: Date.now...until, countsDown: true)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("A fresh code will appear on the TV.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 460)
        .padding(24)
    }

    private func endedView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { link.retry() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 460)
        .padding(24)
    }

    /// The other half of the television's corner card: the same
    /// PairingView gesture, a code appears, you approve it once, it
    /// never asks again. Typed here in the code style that screen
    /// established. Typing the sixth digit submits by itself.
    /// Guest root only: the controller is put away. Nothing is being
    /// looked for, which is the point, so the screen says so and one
    /// button starts again.
    private var putAwayView: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Controller put away")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Find a TV") {
                putAway = false
                link.start()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func pairingEntry(triesLeft: Int) -> some View {
        VStack(spacing: 14) {
            Text("Enter the code on your TV")
                .font(.title2.bold())
            TextField("000 000", text: $codeInput)
                .keyboardType(.numberPad)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .focused($codeFieldFocused)
                .frame(maxWidth: 300)
                .onChange(of: codeInput) { _, raw in
                    let digits = String(raw.filter(\.isNumber).prefix(6))
                    if digits != raw { codeInput = digits }
                    if digits.count == 6 {
                        link.submitCode(digits)
                        codeInput = ""
                    }
                }
            if triesLeft < 3 {
                Text(triesLeft == 1 ? "Wrong code. Last try." : "Wrong code. \(triesLeft) tries left.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: 460)
        .padding(24)
        .onAppear { codeFieldFocused = true }
    }

    /// A complete off-screen shot as one press: flag up, trigger pull,
    /// trigger release, flag down, with enough frames between each for
    /// the core to sample every state. The core reads the flag through
    /// osd_xy_device_read on the same poll that reads the trigger, so
    /// the ordering is what makes it a reload and not a stray shot.
    private func fireOffscreenShot() {
        let (x, y) = gunAim.rewoundAim()
        link.offscreen(true)
        link.pointer(x: x, y: y, down: true)
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            link.pointer(x: x, y: y, down: false)
            try? await Task.sleep(for: .milliseconds(50))
            link.offscreen(false)
        }
    }

    /// Aim streams continuously with the trigger up, so the game's own
    /// crosshair tracks the phone even between shots.
    private func startGunAim() {
        gunAim.degreesToEdge = AimSpeed.current.degreesToEdge
        gunAim.aim = { [weak link] x, y in link?.pointer(x: x, y: y, down: false) }
        gunAim.offscreenChanged = { [weak link] off in link?.offscreen(off) }
        gunAim.start()
    }

    /// The phone as a Nintendo DS: the system's own buttons around the
    /// one thing only a phone can be, the touchscreen. The layout is
    /// nds.json's landscape arrangement, the same file the local player
    /// draws, whose controls hug the edges precisely because its centre
    /// is spoken for; here the centre holds the stylus surface instead
    /// of the picture. Touches map to the frame's lower half, where
    /// melonDS keeps its touchscreen, through the same coordinates the
    /// local player's surface sends. The picture stays on the
    /// television for now: the surface draws only a faint plate, and
    /// the finger's feedback is the core's own cursor on the TV. The
    /// bottom screen itself arrives here when the video leg is built.
    /// The phone as any console's pad: the platform's own landscape
    /// layout, the same file the local player draws from, spread over
    /// a screen with no picture on it. Everything the DS panel does
    /// minus the screen, and every verb goes over the same wire.
    ///
    /// Layout resolution is deliberately the base one: iOS's player
    /// swaps in the six-button Genesis and Avenue Pad variants from
    /// settings, and those are the local player's own preference
    /// lookups, not something a companion phone should second-guess
    /// from across the room.
    private func consolePad(system: String) -> some View {
        Group {
            if let layout = ControlLayout.named(system) {
                TouchControlPad(
                    // The companion arrangement when this platform has
                    // one: no picture here, so the controls get the
                    // whole screen rather than the gutters.
                    items: layout.companionOrLandscapeItems(),
                    send: { id, down in
                        if id == RetroPad.overlay {
                            if down {
                                link.pause(true)
                                confirmingExit = true
                            }
                            return
                        }
                        link.button(id, down: down)
                    },
                    sendStick: { _, x, y in link.stick(x: x, y: y) },
                    sendRelative: { dx, dy in link.relative(dx: dx, dy: dy) },
                    sendPointer: { x, y, down in link.pointer(x: x, y: y, down: down) },
                    sendOffscreen: { off in link.offscreen(off) },
                    system: system,
                    material: true,
                    opacity: 1.0
                )
            } else {
                // A television naming a layout this build does not
                // carry: say so rather than showing an empty screen.
                VStack(spacing: 8) {
                    Image(systemName: "gamecontroller")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("This game needs a newer Cabinet on this phone")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .top) { playerBadge.padding(.top, 10) }
    }

    private func dsPad() -> some View {
        ZStack {
            if let layout = ControlLayout.named("nds") {
                TouchControlPad(
                    items: layout.items(landscape: true),
                    send: { id, down in
                        if id == RetroPad.overlay {
                            if down {
                                link.pause(true)
                                confirmingExit = true
                            }
                            return
                        }
                        link.button(id, down: down)
                    },
                    sendStick: { _, x, y in link.stick(x: x, y: y) },
                    sendRelative: { _, _ in },
                    sendPointer: { _, _, _ in },
                    sendOffscreen: { _ in },
                    system: "nds",
                    material: true,
                    opacity: 1.0
                )
            }
            DSPanelTouchSurface(video: dsVideo, revealed: dsRevealed) { x, y, down in
                link.pointer(x: x, y: y, down: down)
            }
        }
        .onChange(of: link.videoOffer) { _, offer in
            if let offer, let host = link.remoteHost {
                dsRevealed = false
                dsTransitStart = Date()
                warp.beginTransit()
                dsVideo.connect(host: host, port: offer.port, token: offer.token)
            } else {
                warp.abort()
                dsRevealed = false
                dsTransitStart = nil
                dsVideo.disconnect()
            }
        }
        .onChange(of: dsVideo.receiving) { _, on in
            guard on else {
                // A real stream ending is the screen going home; a
                // spool that never arrived never lands, teardown
                // publishes no change for it.
                if dsRevealed { warp.depart() }
                dsRevealed = false
                return
            }
            // The stream is ready; the performance may not be. Hold
            // the reveal for whatever remains of the transit, then
            // land the thump and the picture together.
            let elapsed = dsTransitStart.map { Date().timeIntervalSince($0) } ?? .infinity
            let remaining = max(0, DSWarpHaptics.transitSeconds - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                guard dsVideo.receiving else { return }
                warp.land()
                withAnimation(.easeOut(duration: 0.18)) { dsRevealed = true }
            }
        }
        .onAppear {
            // An offer that arrived before the panel did (the join
            // races the navigation) still connects.
            if let offer = link.videoOffer, let host = link.remoteHost {
                dsRevealed = false
                dsTransitStart = Date()
                warp.beginTransit()
                dsVideo.connect(host: host, port: offer.port, token: offer.token)
            }
        }
        .onDisappear {
            warp.abort()
            dsVideo.disconnect()
        }
    }

    private func pad(for shortname: String) -> some View {
        // A namespaced shortname is a system, not a romset: every
        // non-arcade television advertises "<layout>.<rom id>",
        // because a console's panel is the same for every game on it
        // and filenames cannot pass shortname validation anyway.
        // Nintendo DS is the one with a screen in it. A bare
        // shortname is a romset, and a cabinet, resolved below.
        if let dot = shortname.firstIndex(of: ".") {
            let system = String(shortname[shortname.startIndex..<dot])
            if system == "nds" { return AnyView(dsPad()) }
            return AnyView(consolePad(system: system))
        }
        // The television is running MAME (the arcade receiver only
        // starts there), so resolve against that core's own data, the
        // same call NativePlayerView makes.
        let profile = ArcadeProfileStore.shared.resolve(
            shortname: shortname, using: .mame2003Plus)
        let analog = AnalogControls.controls(forShortname: shortname)
        // The companion arrangement, not the local player's: those
        // layouts share their screen with the picture, and stretching
        // one over a phone with no picture put a tiny trackball in a
        // corner of a black expanse.
        let layout = ArcadeLayout.companion(for: profile, analog: analog)
        let isDriving = (analog?.pedals ?? 0) > 0
        let isGun = (analog?.lightgun ?? 0) > 0
        // Air mode is a pistol grip: the phone stands upright, so it
        // gets its own portrait interface rather than the landscape
        // panel read sideways. Everything below is the touch panel.
        if isGun && gyroGun {
            return AnyView(airGunView(layout: layout))
        }
        return AnyView(GeometryReader { _ in
            TouchControlPad(
                items: layout.items(landscape: true),
                send: { id, down in
                    // Menu pauses the game and opens the panel's own
                    // menu: a deliberately smaller one than the
                    // television's. Save, load, put away, resume.
                    if id == RetroPad.overlay {
                        if down {
                            link.pause(true)
                            confirmingExit = true
                        }
                        return
                    }
                    link.button(id, down: down)
                },
                sendStick: { _, x, y in link.stick(x: x, y: y) },
                sendRelative: { dx, dy in link.relative(dx: dx, dy: dy) },
                sendPointer: { x, y, down in
                    // Gyro gun: the touch is only the trigger. Its
                    // position on the phone means nothing; the aim is
                    // where the phone points, rewound past the tap's
                    // own nudge. Touch aiming is the fallback mode.
                    if isGun && gyroGun {
                        let (ax, ay) = gunAim.rewoundAim()
                        link.pointer(x: ax, y: ay, down: down)
                    } else {
                        link.pointer(x: x, y: y, down: down)
                    }
                },
                sendOffscreen: { off in link.offscreen(off) },
                system: "arcade:\(shortname)",
                material: true,
                opacity: 1.0
            )
        }
        // The safe area stays respected on purpose: ignoring it put the
        // wheel under the camera housing in landscape. The black ground
        // behind the pad still bleeds edge to edge; only the controls
        // keep clear of hardware.
        .overlay(alignment: .top) {
            HStack(spacing: 10) {
                playerBadge
                // Only the driving cabinets get the mode choice;
                // everything else has no wheel for the phone to be.
                if isDriving || isGun {
                    Button {
                        if isGun { gyroGun.toggle() } else { tiltSteering.toggle() }
                    } label: {
                        Label(
                            isGun ? (gyroGun ? "Aiming with the phone" : "Aiming by touch")
                                  : (tiltSteering ? "Tilt On" : "Tilt Off"),
                            systemImage: (isGun ? gyroGun : tiltSteering)
                                ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // Point at the middle of the television, press this,
                    // and the aim is true from that moment. The same
                    // move enabling air mode makes implicitly; here it
                    // is on demand, because a couch shifts.
                    if isGun && gyroGun {
                        Button {
                            gunAim.recenter()
                        } label: {
                            Label("Recenter", systemImage: "scope")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        // The insurance next to the gesture: one press
                        // is a complete off-screen shot. The gesture
                        // (sweep past the bezel and fire) is the
                        // cabinet's own and stays primary; this is for
                        // certainty under fire, when an edge enemy and
                        // a reload must not be one flick apart.
                        Button {
                            fireOffscreenShot()
                        } label: {
                            Label("Reload", systemImage: "arrow.trianglehead.2.counterclockwise")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 6)
        }
        .onAppear {
            if isDriving && tiltSteering {
                tilt.send = { [weak link] dx in link?.relative(dx: dx, dy: 0) }
                tilt.start()
            }
            if isGun && gyroGun { startGunAim() }
        }
        .onChange(of: gyroGun) { _, on in
            if isGun && on { startGunAim() } else { gunAim.stop() }
        })
    }

    /// The gun's own interface: portrait, upright, one honest trigger.
    ///
    /// Everything the landscape panel scattered is rethought for one
    /// hand: the lower half of the screen is a single marked trigger
    /// where the thumb already rests, the game's other buttons sit in a
    /// row above it, and the service controls shrink to the top. The
    /// first air-mode run reused the landscape panel and Marcus's
    /// review was exact: everything sideways, and the trigger only ever
    /// found by accident.
    private func airGunView(layout: ControlLayout) -> some View {
        let extras = layout.items(landscape: true).filter {
            $0.kind == .button && $0.input != RetroPad.b
        }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                playerBadge
                ForEach(["Coin": RetroPad.select, "Start": RetroPad.start].sorted(by: { $0.key < $1.key }), id: \.key) { name, id in
                    Button {
                        link.button(id, down: true)
                        Task { try? await Task.sleep(for: .milliseconds(60)); link.button(id, down: false) }
                    } label: {
                        Text(name)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    link.pause(true)
                    confirmingExit = true
                } label: {
                    Text("Menu")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 10)

            HStack(spacing: 8) {
                Button { gyroGun = false } label: {
                    Label("Touch aim", systemImage: "hand.point.up.left")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { gunAim.recenter() } label: {
                    Label("Recenter", systemImage: "scope")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                Button { fireOffscreenShot() } label: {
                    Label("Reload", systemImage: "arrow.trianglehead.2.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)

            Spacer(minLength: 12)

            // The game's other buttons: grenade and friends, one row,
            // big enough to hit without looking down.
            if !extras.isEmpty {
                HStack(spacing: 18) {
                    ForEach(Array(extras.enumerated()), id: \.offset) { _, item in
                        if let id = item.input {
                            Button {
                                link.button(id, down: true)
                                Task { try? await Task.sleep(for: .milliseconds(60)); link.button(id, down: false) }
                            } label: {
                                Text(item.label ?? "")
                                    .font(.title2.weight(.bold))
                                    .frame(width: 84, height: 84)
                                    .background(.thinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.bottom, 14)
            }

            // The trigger. Half the screen, labelled, under the thumb.
            // Press fires at the rewound aim; holding holds the trigger,
            // which is what an automatic weapon in these games wants.
            Rectangle()
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        .padding(8)
                )
                .overlay(
                    Label("Fire", systemImage: "target")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                )
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !triggerHeld else { return }
                            triggerHeld = true
                            let (x, y) = gunAim.rewoundAim()
                            link.pointer(x: x, y: y, down: true)
                        }
                        .onEnded { _ in
                            triggerHeld = false
                            let (x, y) = gunAim.rewoundAim()
                            link.pointer(x: x, y: y, down: false)
                        }
                )
                .frame(height: UIScreen.main.bounds.height * 0.42)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        // The gyro's lifecycle lives HERE now, not on the landscape
        // branch: when this view took over air mode, the start call
        // stayed behind on a branch that no longer renders, so the aim
        // stream never began. No stream, no crosshair movement on the
        // television, and every shot landed dead centre. Found by
        // Marcus asking where the crosshair went.
        .onAppear {
            OrientationLock.lockToPortrait()
            startGunAim()
        }
        .onDisappear {
            OrientationLock.lockToLandscape()
            gunAim.stop()
            // Same pin as the panel's own appearance, for the trip back
            // from air mode.
            Task {
                try? await Task.sleep(for: .seconds(1))
                OrientationLock.pinCurrentLandscape()
            }
        }
    }
}



/// The stylus surface on the phone panel: a 4:3 plate standing in for
/// the DS bottom screen, centred in the gap nds.json's landscape
/// controls leave open. Coordinates leave here in libretro pointer
/// space over melonDS's whole stacked frame, x across [-1, 1] and y in
/// [0, 1] (the frame's lower half is the touchscreen), the identical
/// mapping DSScreenLayout.pointer feeds the local player. Drags clamp
/// at the plate's edge until the finger lifts, a stylus pressed
/// against the bezel, and the plate is deliberately quiet: a hairline
/// and a whisper of fill, since the eyes belong on the television.
private struct DSPanelTouchSurface: View {
    @ObservedObject var video: DSVideoClient
    /// The landing's gate: the stream may be ready early, but the
    /// picture appears only when the performance says so.
    var revealed: Bool
    let sendPointer: (_ x: Double, _ y: Double, _ down: Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.height * 0.66 * 4 / 3, geo.size.width * 0.44)
            let h = w * 3 / 4
            let rect = CGRect(
                x: (geo.size.width - w) / 2,
                y: (geo.size.height - h) / 2,
                width: w, height: h
            )
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
                .overlay {
                    // The live bottom screen, the moment it exists;
                    // until then the quiet plate is the promise of it.
                    if video.receiving && revealed {
                        DSVideoLayerView(layer: video.displayLayer)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("dsPanel"))
                        .onChanged { g in
                            let u = min(max((g.location.x - rect.minX) / rect.width, 0), 1)
                            let v = min(max((g.location.y - rect.minY) / rect.height, 0), 1)
                            sendPointer(u * 2 - 1, v, true)
                        }
                        .onEnded { g in
                            let u = min(max((g.location.x - rect.minX) / rect.width, 0), 1)
                            let v = min(max((g.location.y - rect.minY) / rect.height, 0), 1)
                            sendPointer(u * 2 - 1, v, false)
                        }
                )
        }
        .coordinateSpace(name: "dsPanel")
    }
}
/// The warp drive under the DS split. The first version tracked the
/// stream's real transit and taught the obvious lesson: the wire is
/// too fast to feel, a tenth of a second of blip. Magic owns its own
/// clock, so this is a fixed performance, about 1.4 seconds, and the
/// picture's reveal waits for the landing (the stream is ready long
/// before; it holds behind the curtain). The texture is a warp
/// charge, not a hum: a continuous rumble climbing to full strength
/// under a train of accelerating ticks, a cut to silence, then a
/// double-hit landing, heavy strike and settle. Departure stays a
/// short falling rumble with no impact.
private final class DSWarpHaptics {
    /// How long the spool runs before the landing may fire. The
    /// reveal is held to this, so the thump and the picture are
    /// always one moment.
    static let transitSeconds: TimeInterval = 1.4

    private var engine: CHHapticEngine?
    private var transit: CHHapticAdvancedPatternPlayer?

    private func runningEngine() -> CHHapticEngine? {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        if let engine { return engine }
        guard let fresh = try? CHHapticEngine() else { return nil }
        fresh.isAutoShutdownEnabled = true
        engine = fresh
        return fresh
    }

    func beginTransit() {
        guard let engine = runningEngine(), (try? engine.start()) != nil else { return }
        transit = nil
        let spool = Self.transitSeconds
        var events: [CHHapticEvent] = [
            CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ],
                relativeTime: 0, duration: spool),
        ]
        // The charge: ticks accelerating from a slow knock to a race,
        // each harder than the last. Spacing shrinks geometrically so
        // the rhythm itself says "almost there".
        var t: TimeInterval = 0.12
        var gap: TimeInterval = 0.22
        var strength: Float = 0.45
        while t < spool - 0.08 {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: min(strength, 1.0)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
                ],
                relativeTime: t))
            t += gap
            gap = max(gap * 0.82, 0.045)
            strength += 0.06
        }
        let climb = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.0, value: 0.35),
                .init(relativeTime: spool * 0.5, value: 0.75),
                .init(relativeTime: spool, value: 1.0),
            ],
            relativeTime: 0)
        let sharpen = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: [
                .init(relativeTime: 0.0, value: 0.1),
                .init(relativeTime: spool, value: 0.8),
            ],
            relativeTime: 0)
        guard let pattern = try? CHHapticPattern(events: events, parameterCurves: [climb, sharpen]),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        transit = player
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    /// Drop out of warp: kill the charge, one beat of nothing, then
    /// the double hit: the strike, and the settle right behind it.
    func land() {
        try? transit?.stop(atTime: CHHapticTimeImmediate)
        transit = nil
        guard let engine = runningEngine(), (try? engine.start()) != nil else { return }
        let strike = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.7),
            ],
            relativeTime: 0.09)
        let settle = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35),
            ],
            relativeTime: 0.19)
        guard let pattern = try? CHHapticPattern(events: [strike, settle], parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    /// The screen going home: a short fall, no impact.
    func depart() {
        try? transit?.stop(atTime: CHHapticTimeImmediate)
        transit = nil
        guard let engine = runningEngine(), (try? engine.start()) != nil else { return }
        let fall = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ],
            relativeTime: 0, duration: 0.45)
        let fade = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0.0, value: 1.0),
                .init(relativeTime: 0.45, value: 0.0),
            ],
            relativeTime: 0)
        guard let pattern = try? CHHapticPattern(events: [fall], parameterCurves: [fade]),
              let player = try? engine.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    /// A transit that never arrived: fade out and say nothing.
    func abort() {
        try? transit?.stop(atTime: CHHapticTimeImmediate)
        transit = nil
    }
}

/// Hosts the decoder's display layer in UIKit, where layers live. The
/// layer fills the hosting view; SwiftUI decides the view's frame.
private struct DSVideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    final class HostView: UIView {
        var hosted: AVSampleBufferDisplayLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { self.layer.addSublayer(hosted) }
                setNeedsLayout()
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.hosted = layer
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        if uiView.hosted !== layer { uiView.hosted = layer }
    }
}
#endif
