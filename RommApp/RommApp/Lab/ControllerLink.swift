import Foundation
import Network

/// The phone driving a game running on the television.
///
/// This is the first slice of the accessory idea and it is deliberately
/// thin: the phone already knows how to draw a cabinet's panel and turn
/// touches into the five verbs the player speaks (a button, a stick, a
/// relative roll, an absolute aim, an off-screen shot), and both players
/// already know how to feed those verbs to a core. So nothing here
/// invents input. It carries those same five verbs over a wire and hands
/// them to the television's renderer exactly as its own overlay would.
///
/// WHAT THIS IS NOT YET, and the difference matters because the shipping
/// design turns on it: discovery here is Bonjour, which browses the local
/// network. The real feature must not do that. It learns which
/// television is playing from RomM, which both devices are already
/// authenticated to, and touches the network only once a person has
/// chosen a specific television. That keeps a phone on a stranger's Wi-Fi
/// completely inert, which a browse cannot promise. Bonjour is here
/// because it is what the aim lab already had working and this slice
/// exists to prove the input chain, not the rendezvous.
///
/// Likewise the receiver is opened by hand for now. In the shipping
/// design the television binds nothing until someone has enabled it, and
/// accepts no phone it has not been introduced to.
enum ControllerLink {
    static let bonjourType = "_cabinet-probe._udp"
    static let serviceName = "CabinetLink"

    /// One player action. Fixed width, no lengths and no allocation, so
    /// the only thing an unexpected packet can do is decode to nonsense
    /// inside a known range and be dropped.
    struct Packet {
        enum Kind: UInt8 {
            case hello = 0      // television to phone: what is running
            case button = 1     // a: RetroPad id, flag: down
            case stick = 2      // a, b: axis x 10000
            case relative = 3   // a, b: raw counts this frame
            case pointer = 4    // a, b: position x 10000, flag: down
            case offscreen = 5  // flag: aiming past the picture
            // The panel's own controls, not the game's: the pause menu
            // the phone shows is deliberately smaller than the
            // television's. Pause, save, load, and put away; anything
            // more belongs on the machine that owns the screen.
            case pause = 6      // flag: paused
            case saveState = 7
            case loadState = 8
            // The polite leave. Without it the television cannot tell
            // "put away on purpose" from "fell off the network", and
            // the two deserve opposite reactions: a deliberate leave
            // keeps the game running for the remote or a rejoin, a
            // drop pauses it, because nobody is holding anything.
            case goodbye = 9
        }

        var seq: UInt32 = 0
        var kind: Kind
        var flag: Bool = false
        var a: Int16 = 0
        var b: Int16 = 0

        static let size = 10

        func encoded() -> Data {
            var out = Data(capacity: Packet.size)
            withUnsafeBytes(of: seq.littleEndian) { out.append(contentsOf: $0) }
            out.append(kind.rawValue)
            out.append(flag ? 1 : 0)
            withUnsafeBytes(of: a.littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: b.littleEndian) { out.append(contentsOf: $0) }
            return out
        }

        /// Nil for anything that is not exactly a packet. Length is
        /// checked before any read, and an unknown kind is refused rather
        /// than defaulted, because a parser that guesses is the part of
        /// this an attacker would reach first.
        static func decode(_ data: Data) -> Packet? {
            guard data.count >= size else { return nil }
            let bytes = [UInt8](data)
            guard let kind = Kind(rawValue: bytes[4]) else { return nil }
            func i16(_ at: Int) -> Int16 {
                Int16(bitPattern: UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8)
            }
            var seq: UInt32 = 0
            for i in 0..<4 { seq |= UInt32(bytes[i]) << (8 * UInt32(i)) }
            return Packet(seq: seq, kind: kind, flag: bytes[5] != 0,
                          a: i16(6), b: i16(8))
        }
    }

    /// A shortname, as strict as the join key it effectively is: MAME
    /// romset names are lowercase letters, digits and a few punctuation
    /// marks, never long, and anything else is refused rather than
    /// sanitised.
    static func validShortname(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 32 else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyz0123456789_-.")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    /// The romset a television's advertisement names, if the endpoint
    /// is one of ours and the name passes the same strictness the hello
    /// packet does.
    static func shortname(fromService endpoint: NWEndpoint) -> String? {
        guard case let .service(name, _, _, _) = endpoint,
              name.hasPrefix("\(serviceName)-") else { return nil }
        return validShortname(String(name.dropFirst(serviceName.count + 1)))
    }

    static func parameters() -> NWParameters {
        let p = NWParameters.udp
        // Off, deliberately. Peer to peer keeps AWDL alive, which hops the
        // radio off channel about once a second and was the entire cause
        // of the stalls the aim lab first blamed on WiFi.
        p.includePeerToPeer = false
        p.serviceClass = .interactiveVoice
        return p
    }
}

// MARK: - Television

/// Listens for a phone and hands what it says to the game.
///
/// Deliberately owns no game state. It is given closures by whoever
/// starts it, so the television's player wires them to exactly the calls
/// its own controller path already makes, and this file never learns what
/// a renderer is.
final class ControllerLinkReceiver {
    /// What is running, sent to a phone the moment it connects so it can
    /// draw the right cabinet.
    private let shortname: String
    private let onButton: (Int, Bool) -> Void
    private let onStick: (Double, Double) -> Void
    private let onRelative: (Int, Int) -> Void
    private let onPointer: (Double, Double, Bool) -> Void
    private let onOffscreen: (Bool) -> Void
    private let onPause: (Bool) -> Void
    private let onSave: () -> Void
    private let onLoad: () -> Void
    private let onPhone: (Bool) -> Void

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "cabinet.link.receive", qos: .userInteractive)
    /// UDP reorders, so absolute positions carry a sequence and stale
    /// ones are dropped. Per connection, not per receiver: a phone that
    /// backgrounds and returns is a NEW connection whose numbering
    /// restarts at one, and a shared high-water mark silently discarded
    /// every stick and aim packet after a reconnect while letting
    /// buttons through, which is the worst kind of half-working.
    private var lastSeq: [ObjectIdentifier: UInt32] = [:]
    /// When each phone last said anything. Input flows constantly from
    /// a held phone (aim at 60Hz, every touch), so silence IS absence.
    private var lastHeard: [ObjectIdentifier: Date] = [:]
    private var liveness: DispatchSourceTimer?
    /// Generous next to the 60Hz reality, tight next to a person
    /// wondering why the game is still playing itself.
    private let dropAfter: TimeInterval = 5
    /// A drop is not a goodbye: deliberate leaves pass through here.
    private let onDrop: () -> Void

    init(shortname: String,
         onButton: @escaping (Int, Bool) -> Void,
         onStick: @escaping (Double, Double) -> Void,
         onRelative: @escaping (Int, Int) -> Void,
         onPointer: @escaping (Double, Double, Bool) -> Void,
         onOffscreen: @escaping (Bool) -> Void,
         onPause: @escaping (Bool) -> Void,
         onSave: @escaping () -> Void,
         onLoad: @escaping () -> Void,
         onPhone: @escaping (Bool) -> Void,
         onDrop: @escaping () -> Void) {
        self.shortname = shortname
        self.onButton = onButton
        self.onStick = onStick
        self.onRelative = onRelative
        self.onPointer = onPointer
        self.onOffscreen = onOffscreen
        self.onPause = onPause
        self.onSave = onSave
        self.onLoad = onLoad
        self.onPhone = onPhone
        self.onDrop = onDrop
    }

    func start() {
        guard listener == nil else { return }
        guard let l = try? NWListener(using: ControllerLink.parameters()) else { return }
        // The game rides in the service name, so a phone can know what
        // is playing, and show the person a truthful offer, without ever
        // connecting. The hello packet stays as confirmation once a
        // connection exists; this is for before one does.
        l.service = NWListener.Service(name: "\(ControllerLink.serviceName)-\(shortname)",
                                       type: ControllerLink.bonjourType)
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = l
        l.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.checkLiveness() }
        timer.resume()
        liveness = timer
    }

    /// Silence past the threshold is a drop. The stale connection is
    /// forgotten, the presence flag goes truthful, and the game pauses
    /// through the same reaction a Bluetooth controller's disconnect
    /// has always had: nobody is holding anything.
    private func checkLiveness() {
        let cutoff = Date().addingTimeInterval(-dropAfter)
        let dead = lastHeard.filter { $0.value < cutoff }
        guard !dead.isEmpty else { return }
        for key in dead.keys {
            lastHeard[key] = nil
            lastSeq[key] = nil
        }
        connections.removeAll { dead.keys.contains(ObjectIdentifier($0)) }
        if connections.isEmpty {
            onPhone(false)
            onDrop()
        }
    }

    func stop() {
        liveness?.cancel()
        liveness = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        onPhone(false)
    }

    private func accept(_ connection: NWConnection) {
        connections.removeAll { c in
            if case .cancelled = c.state { return true }
            if case .failed = c.state { return true }
            return false
        }
        lastSeq[ObjectIdentifier(connection)] = 0
        lastHeard[ObjectIdentifier(connection)] = Date()
        connections.append(connection)
        connection.start(queue: queue)
        // Tell the phone what cabinet to draw. Name first, so a phone that
        // joins mid-game shows the right panel immediately rather than
        // waiting for the next thing to happen.
        var hello = ControllerLink.Packet(kind: .hello).encoded()
        hello.append(contentsOf: Array(shortname.utf8.prefix(32)))
        connection.send(content: hello, completion: .idempotent)
        onPhone(true)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = ControllerLink.Packet.decode(data) {
                self.lastHeard[ObjectIdentifier(connection)] = Date()
                self.apply(packet, from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            } else {
                self.lastSeq[ObjectIdentifier(connection)] = nil
            }
        }
    }

    private var connectionForGoodbye: NWConnection?

    private func apply(_ p: ControllerLink.Packet, from connection: NWConnection) {
        connectionForGoodbye = connection
        defer { connectionForGoodbye = nil }
        // Aim and stick positions are absolute, so a stale one snaps the
        // control backwards and is worth dropping. Buttons are edges and
        // must never be dropped: losing an "up" leaves it held forever.
        let key = ObjectIdentifier(connection)
        let last = lastSeq[key] ?? 0
        let stale = p.seq != 0 && p.seq < last
        if p.seq > last { lastSeq[key] = p.seq }

        switch p.kind {
        case .hello:
            break
        case .button:
            onButton(Int(p.a), p.flag)
        case .stick:
            guard !stale else { return }
            onStick(Double(p.a) / 10000, Double(p.b) / 10000)
        case .relative:
            onRelative(Int(p.a), Int(p.b))
        case .pointer:
            guard !stale else { return }
            onPointer(Double(p.a) / 10000, Double(p.b) / 10000, p.flag)
        case .offscreen:
            onOffscreen(p.flag)
        case .pause:
            onPause(p.flag)
        case .saveState:
            onSave()
        case .loadState:
            onLoad()
        case .goodbye:
            // Deliberate. Forget the phone without pausing anything.
            connections.removeAll { $0 === connectionForGoodbye }
            if connections.isEmpty { onPhone(false) }
        }
    }
}

// MARK: - Phone

#if os(iOS)

/// Watches for a television playing an arcade game, for the Home offer.
///
/// Browse only, never a connection: the offer has to know what is
/// playing before the person decides anything, and deciding is theirs.
/// In the shipping design this knowledge comes from RomM presence and
/// no browse happens at all; this is the lab's stand-in, same as the
/// rest of the discovery here.
@MainActor
final class ControllerLinkScout: ObservableObject {
    /// The romset a television on this network is running, or nil.
    @Published private(set) var playing: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "cabinet.link.scout")

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: ControllerLink.bonjourType, domain: nil),
                                using: ControllerLink.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let name = results.compactMap { ControllerLink.shortname(fromService: $0.endpoint) }.first
            Task { @MainActor in self?.playing = name }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        playing = nil
    }
}

/// Finds the television, then speaks the panel's verbs to it.
@MainActor
final class ControllerLinkSender: ObservableObject {
    @Published private(set) var status = "looking for the television"
    @Published private(set) var connected = false
    /// The romset the television is running, once it has said so. The
    /// panel is built from this, which is why the phone draws the right
    /// cabinet without being told anything else.
    @Published private(set) var shortname: String?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "cabinet.link.send", qos: .userInteractive)
    private var seq: UInt32 = 0
    /// The liveness rule reads silence as absence, and a phone in touch
    /// mode is silent whenever nobody is touching it: an attract screen
    /// or a moment between lives would read as a drop and pause the
    /// game under a player who is right there. So the phone hums. A
    /// hello every two seconds says "still held" and means nothing
    /// else; the gun's 60Hz aim stream makes it redundant there, and
    /// redundant is fine.
    private var heartbeat: DispatchSourceTimer?
    /// True only across an explicit stop, so a failure-driven teardown
    /// can be told apart from one the user asked for. Backgrounding the
    /// app kills the UDP flow; coming back must not need a relaunch.
    private var stopping = false

    func start() {
        stopping = false
        let browser = NWBrowser(for: .bonjour(type: ControllerLink.bonjourType, domain: nil),
                                using: ControllerLink.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let first = results.first else { return }
            let named = ControllerLink.shortname(fromService: first.endpoint)
            Task { @MainActor in
                if let named { self.shortname = named }
                self.connect(to: first.endpoint)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.send(.init(kind: .hello))
            }
        }
        timer.resume()
        heartbeat = timer
    }

    func stop() {
        stopping = true
        heartbeat?.cancel(); heartbeat = nil
        // The polite leave, so the television keeps the game running
        // rather than pausing for a controller that left on purpose.
        if connected { send(.init(kind: .goodbye)) }
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
        connected = false
    }

    /// The foreground edge. If the link died while the app was away,
    /// begin again from the browse; if it is healthy, do nothing.
    func wake() {
        guard !connected, !stopping else { return }
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        start()
    }

    private func connect(to endpoint: NWEndpoint) {
        guard connection == nil else { return }
        let c = NWConnection(to: endpoint, using: ControllerLink.parameters())
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.connected = true
                    self?.status = "connected"
                    self?.startHeartbeat()
                    // The browse has done its job. Leaving it running is
                    // what kept AWDL awake and produced the stalls the
                    // aim lab spent an evening chasing.
                    self?.browser?.cancel()
                    self?.browser = nil
                case .failed, .cancelled:
                    guard let self else { return }
                    self.heartbeat?.cancel(); self.heartbeat = nil
                    self.connected = false
                    self.status = "disconnected"
                    // A failure with nobody having called stop() means
                    // the flow died under us, suspension being the
                    // common cause. Go back to looking; the sequence
                    // deliberately does not reset, so the television
                    // never sees numbering move backwards inside what it
                    // still thinks is one conversation.
                    if !self.stopping {
                        self.connection?.cancel()
                        self.connection = nil
                        self.start()
                    }
                default:
                    break
                }
            }
        }
        c.start(queue: queue)
        receive(on: c)
        // UDP has no handshake, so the television does not know we exist
        // until we say something. This is that.
        send(.init(kind: .offscreen, flag: false))
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count > ControllerLink.Packet.size,
               let packet = ControllerLink.Packet.decode(data), packet.kind == .hello {
                let raw = String(decoding: data.dropFirst(ControllerLink.Packet.size), as: UTF8.self)
                if let name = ControllerLink.validShortname(raw) {
                    Task { @MainActor in
                        self.shortname = name
                        self.status = name
                    }
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func send(_ packet: ControllerLink.Packet) {
        guard let connection else { return }
        var p = packet
        seq &+= 1
        p.seq = seq
        connection.send(content: p.encoded(), completion: .idempotent)
    }

    // The five verbs, named for what the player did rather than for the
    // wire, so the call sites read the same as the local ones.
    func button(_ id: Int, down: Bool) {
        send(.init(kind: .button, flag: down, a: Int16(clamping: id)))
    }

    func stick(x: Double, y: Double) {
        send(.init(kind: .stick, a: axis(x), b: axis(y)))
    }

    func relative(dx: Int, dy: Int) {
        send(.init(kind: .relative, a: Int16(clamping: dx), b: Int16(clamping: dy)))
    }

    func pointer(x: Double, y: Double, down: Bool) {
        send(.init(kind: .pointer, flag: down, a: axis(x), b: axis(y)))
    }

    func offscreen(_ off: Bool) {
        send(.init(kind: .offscreen, flag: off))
    }

    func pause(_ paused: Bool) {
        send(.init(kind: .pause, flag: paused))
    }

    func saveState() {
        send(.init(kind: .saveState))
    }

    func loadState() {
        send(.init(kind: .loadState))
    }

    private func axis(_ v: Double) -> Int16 {
        Int16(clamping: Int((v * 10000).rounded()))
    }
}

#endif
