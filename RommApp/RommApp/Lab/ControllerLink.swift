import Foundation
import Network

/// The phone driving a game running on the television.
///
/// This is deliberately thin: the phone already knows how to draw a
/// cabinet's panel and turn touches into the five verbs the player
/// speaks (a button, a stick, a relative roll, an absolute aim, an
/// off-screen shot), and both players already know how to feed those
/// verbs to a core. So nothing here invents input. It carries those same
/// five verbs over a wire and hands them to the television's renderer
/// exactly as its own overlay would.
///
/// The rendezvous is the settled design of
/// docs/scope-phone-controller-pairing.md. The television binds nothing
/// unless its "Allow a phone as a controller" setting is on and a game
/// is running. The first time a given phone connects, the television
/// shows a short code, the person types it on the phone, and both sides
/// store a shared secret through ControllerPairing; that is the last
/// time anyone does anything. A phone the television has never met gets
/// that pairing conversation instead of a control connection, and its
/// input is not applied. Discovery is Bonjour and stays Bonjour in the
/// shipping design: pairing is what makes browsing harmless, since a
/// phone on a stranger's network finds a television it cannot prove
/// anything to and does nothing. An older plan gated discovery through
/// RomM presence instead; the design doc replaced it, see "What was
/// originally planned, and why it changed" there.
enum ControllerLink {
    static let bonjourType = "_cabinet-probe._udp"
    static let serviceName = "CabinetLink"

    /// One player action. Fixed width, no lengths and no allocation, so
    /// the only thing an unexpected packet can do is decode to nonsense
    /// inside a known range and be dropped. Pairing kinds append a
    /// payload after the fixed header, the same way hello appends the
    /// romset name, and every payload is length-checked before a byte
    /// of it is read.
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
            // The front door. A phone announces who it is; a known
            // phone gets hello back and only then does its input
            // count, an unknown one is sent to pairing.
            case join = 10          // phone to tv: phoneID (8)
            case pairNeeded = 11    // tv to phone: tvID (8)
            case pairRequest = 12   // phone to tv: phoneID (8) + public key (32)
            case pairChallenge = 13 // tv to phone: tvID (8) + public key (32) + salt (16)
            case pairProof = 14     // phone to tv: phoneID (8) + proof (32)
            case pairSuccess = 15   // tv to phone: acknowledgement (32)
            case pairFail = 16      // tv to phone: a: reason, b: tries left
        }

        /// pairFail's `a` field. Small and explicit, so the phone can
        /// say something truthful instead of "error".
        enum FailReason: Int16 {
            case wrongCode = 1
            case cancelled = 2
            case busy = 3
            case expired = 4
            case storage = 5
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
///
/// A connection starts as a stranger. Input only counts once it has
/// joined, which takes a stored pairing; everything else it sends is a
/// pairing conversation or noise.
final class ControllerLinkReceiver {
    /// What is running, sent to a phone the moment it joins so it can
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
    /// The code to show on screen, or nil to take it down. The overlay
    /// is the player view's; this only says what is true.
    private let onPairingCode: (String?) -> Void

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "cabinet.link.receive", qos: .userInteractive)

    /// Everything known about one connection. UDP reorders, so absolute
    /// positions carry a sequence and stale ones are dropped, per
    /// connection: a phone that backgrounds and returns is a NEW
    /// connection whose numbering restarts at one, and a shared
    /// high-water mark would silently discard every stick and aim packet
    /// after a reconnect while letting buttons through, which is the
    /// worst kind of half-working.
    private struct Peer {
        var joined = false
        var phoneID: Data?
        /// When this phone last said anything. Input flows constantly
        /// from a held phone (aim at 60Hz, every touch, a heartbeat
        /// otherwise), so silence IS absence.
        var lastHeard: Date
        var lastSeq: UInt32 = 0
    }
    private var peers: [ObjectIdentifier: Peer] = [:]

    private var liveness: DispatchSourceTimer?
    /// Generous next to the 60Hz reality, tight next to a person
    /// wondering why the game is still playing itself.
    private let dropAfter: TimeInterval = 5
    /// A drop is not a goodbye: deliberate leaves pass through here.
    private let onDrop: () -> Void

    /// This television's own name on the link, for pairing.
    private let tvID = ControllerPairing.deviceID
    /// The one pairing attempt allowed at a time, if any.
    private var acceptor: ControllerPairing.Acceptor?
    /// A code that sat unanswered this long is taken down. Long enough
    /// to fetch the phone from another room, short enough that a
    /// wandering overlay does not haunt the game.
    private let pairingTimeout: TimeInterval = 90
    /// Set after three wrong codes. While it holds, new pairing
    /// requests are answered busy, so a guesser gets three tries per
    /// half minute instead of a stream.
    private var pairingLockedUntil: Date?
    /// The last successful pairing's acknowledgement, kept briefly so a
    /// phone whose success reply was lost in transit can ask again and
    /// get the same answer instead of a dead end.
    private var lastAck: (phoneID: Data, ack: Data, at: Date)?

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
         onPairingCode: @escaping (String?) -> Void,
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
        self.onPairingCode = onPairingCode
        self.onDrop = onDrop
    }

    func start() {
        guard listener == nil else { return }
        guard let l = try? NWListener(using: ControllerLink.parameters()) else { return }
        // The game rides in the service name, so a phone can know what
        // is playing, and show the person a truthful offer, without ever
        // connecting. The hello packet stays as confirmation once a
        // phone has joined; this is for before one does.
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
    /// forgotten; if it was the last joined phone, the presence flag
    /// goes truthful and the game pauses through the same reaction a
    /// Bluetooth controller's disconnect has always had: nobody is
    /// holding anything. A stranger going quiet mid-pairing pauses
    /// nothing, and its code comes down on its own timeout below.
    private func checkLiveness() {
        let cutoff = Date().addingTimeInterval(-dropAfter)
        let dead = peers.filter { $0.value.lastHeard < cutoff }
        if !dead.isEmpty {
            let hadJoined = peers.values.contains { $0.joined }
            for key in dead.keys { peers[key] = nil }
            connections.removeAll { c in
                guard dead.keys.contains(ObjectIdentifier(c)) else { return false }
                c.cancel()
                return true
            }
            let hasJoined = peers.values.contains { $0.joined }
            if hadJoined, !hasJoined {
                onPhone(false)
                onDrop()
            }
        }
        if let acceptor, Date().timeIntervalSince(acceptor.startedAt) > pairingTimeout {
            self.acceptor = nil
            onPairingCode(nil)
        }
    }

    func stop() {
        liveness?.cancel()
        liveness = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        peers.removeAll()
        acceptor = nil
        onPairingCode(nil)
        onPhone(false)
    }

    private func accept(_ connection: NWConnection) {
        connections.removeAll { c in
            if case .cancelled = c.state { return true }
            if case .failed = c.state { return true }
            return false
        }
        peers[ObjectIdentifier(connection)] = Peer(lastHeard: Date())
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = ControllerLink.Packet.decode(data) {
                self.peers[ObjectIdentifier(connection)]?.lastHeard = Date()
                self.apply(packet, payload: Data(data.dropFirst(ControllerLink.Packet.size)),
                           from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    /// The moment a phone becomes a controller: it gets told what is
    /// running so it can draw the right panel, and its input starts to
    /// count. Reached by proving a stored pairing (join) or by finishing
    /// a fresh one (pairProof), never any other way.
    private func markJoined(_ connection: NWConnection, phoneID: Data) {
        let key = ObjectIdentifier(connection)
        guard var peer = peers[key] else { return }
        let alreadyJoined = peer.joined
        peer.joined = true
        peer.phoneID = phoneID
        peers[key] = peer
        var hello = ControllerLink.Packet(kind: .hello).encoded()
        hello.append(contentsOf: Array(shortname.utf8.prefix(32)))
        connection.send(content: hello, completion: .idempotent)
        if !alreadyJoined { onPhone(true) }
    }

    private func reply(_ kind: ControllerLink.Packet.Kind, payload: Data = Data(),
                       a: Int16 = 0, b: Int16 = 0, on connection: NWConnection) {
        let packet = ControllerLink.Packet(kind: kind, a: a, b: b)
        connection.send(content: packet.encoded() + payload, completion: .idempotent)
    }

    private func fail(_ reason: ControllerLink.Packet.FailReason, triesLeft: Int16 = 0,
                      on connection: NWConnection) {
        reply(.pairFail, a: reason.rawValue, b: triesLeft, on: connection)
    }

    private func apply(_ p: ControllerLink.Packet, payload: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard let peer = peers[key] else { return }

        switch p.kind {
        case .join:
            guard payload.count >= 8 else { return }
            let phoneID = Data(payload.prefix(8))
            if ControllerPairing.secret(forPeer: phoneID) != nil {
                markJoined(connection, phoneID: phoneID)
            } else {
                reply(.pairNeeded, payload: tvID, on: connection)
            }
            return

        case .pairRequest:
            guard payload.count == 8 + 32 else { return }
            let phoneID = Data(payload.prefix(8))
            let phonePub = Data(payload.suffix(32))
            if let until = pairingLockedUntil, until > Date() {
                fail(.busy, on: connection)
                return
            }
            if let acceptor {
                if acceptor.phoneID == phoneID, acceptor.phonePub == phonePub {
                    // The same request again is a retry, not a rival:
                    // answer with the same challenge so the exchange
                    // converges instead of forking.
                    reply(.pairChallenge, payload: acceptor.challengePayload, on: connection)
                    return
                }
                if acceptor.phoneID == phoneID {
                    // Same phone, new key: its app restarted mid-pair.
                    // Start over with a fresh code below.
                    self.acceptor = nil
                } else {
                    // A second phone while one is mid-pair. One code on
                    // screen at a time; the second asks again later.
                    fail(.busy, on: connection)
                    return
                }
            }
            guard let fresh = ControllerPairing.Acceptor(phoneID: phoneID, phonePub: phonePub, tvID: tvID)
            else { return }
            acceptor = fresh
            onPairingCode(fresh.code)
            reply(.pairChallenge, payload: fresh.challengePayload, on: connection)
            return

        case .pairProof:
            guard payload.count == 8 + 32 else { return }
            let phoneID = Data(payload.prefix(8))
            let proof = Data(payload.suffix(32))
            guard let acceptor, acceptor.phoneID == phoneID else {
                if let lastAck, lastAck.phoneID == phoneID,
                   Date().timeIntervalSince(lastAck.at) < 60 {
                    // Its success reply was lost; say it again.
                    reply(.pairSuccess, payload: lastAck.ack, on: connection)
                    markJoined(connection, phoneID: phoneID)
                } else {
                    fail(.expired, on: connection)
                }
                return
            }
            switch acceptor.verify(proof: proof) {
            case .success(let secret, let ack):
                do {
                    try ControllerPairing.savePairing(secret: secret, forPeer: phoneID)
                    lastAck = (phoneID, ack, Date())
                    self.acceptor = nil
                    onPairingCode(nil)
                    reply(.pairSuccess, payload: ack, on: connection)
                    markJoined(connection, phoneID: phoneID)
                } catch {
                    self.acceptor = nil
                    onPairingCode(nil)
                    fail(.storage, on: connection)
                }
            case .wrong(let triesLeft):
                fail(.wrongCode, triesLeft: Int16(triesLeft), on: connection)
            case .cancelled:
                self.acceptor = nil
                onPairingCode(nil)
                pairingLockedUntil = Date().addingTimeInterval(30)
                fail(.cancelled, on: connection)
            }
            return

        case .hello, .pairNeeded, .pairChallenge, .pairSuccess, .pairFail:
            // Heartbeat, or kinds only the television sends. Nothing to
            // do; the receive loop has already refreshed liveness.
            return

        default:
            break
        }

        // Everything from here is control input, and a stranger has
        // none. This gate is what the join conversation above earns.
        guard peer.joined else { return }

        // Aim and stick positions are absolute, so a stale one snaps the
        // control backwards and is worth dropping. Buttons are edges and
        // must never be dropped: losing an "up" leaves it held forever.
        let last = peer.lastSeq
        let stale = p.seq != 0 && p.seq < last
        if p.seq > last { peers[key]?.lastSeq = p.seq }

        switch p.kind {
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
            connection.cancel()
            peers[key] = nil
            connections.removeAll { $0 === connection }
            if !peers.values.contains(where: { $0.joined }) { onPhone(false) }
        default:
            break
        }
    }
}

// MARK: - Phone

#if os(iOS)

/// Watches for a television playing an arcade game, for the Home offer.
///
/// Browse only, never a connection: the offer has to know what is
/// playing before the person decides anything, and deciding is theirs.
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

/// Finds the television, joins or pairs as the television requires,
/// then speaks the panel's verbs to it.
@MainActor
final class ControllerLinkSender: ObservableObject {
    /// Where the conversation stands, which is also what the panel
    /// screen should be showing.
    enum Phase: Equatable {
        case searching
        /// Connected, announcing this phone, waiting to be recognised
        /// or sent to pairing.
        case joining
        /// The television has shown a code and is waiting for it to be
        /// typed here. triesLeft counts down on wrong entries.
        case codeEntry(triesLeft: Int)
        /// A code has been sent; the television is judging it.
        case verifying
        case connected
        /// Over, with a sentence saying why. retry() starts again.
        case ended(String)
    }

    @Published private(set) var phase: Phase = .searching
    @Published private(set) var status = "looking for the television"
    @Published private(set) var connected = false
    /// The romset the television is running, once a join has been
    /// answered. The panel is built from this, which is why the phone
    /// draws the right cabinet without being told anything else.
    @Published private(set) var shortname: String?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "cabinet.link.send", qos: .userInteractive)
    private var seq: UInt32 = 0
    /// One slow drumbeat drives everything that repeats: the join
    /// retries (UDP loses things), the proof retries, and the
    /// heartbeat that keeps the television's liveness rule from reading
    /// an idle touch panel as an absent one. An attract screen or a
    /// moment between lives would otherwise read as a drop and pause
    /// the game under a player who is right there.
    private var ticker: DispatchSourceTimer?
    /// The pairing attempt in progress, if the television demanded one.
    private var requester: ControllerPairing.Requester?
    /// The last proof sent, kept for retries until the television
    /// answers one way or the other.
    private var pendingProof: Data?
    /// True only across an explicit stop, so a failure-driven teardown
    /// can be told apart from one the user asked for. Backgrounding the
    /// app kills the UDP flow; coming back must not need a relaunch.
    private var stopping = false

    func start() {
        stopping = false
        phase = .searching
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

    private func startTicker() {
        ticker?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        timer.resume()
        ticker = timer
    }

    private func tick() {
        switch phase {
        case .joining:
            if let requester {
                send(.init(kind: .pairRequest), payload: requester.requestPayload)
            } else {
                send(.init(kind: .join), payload: ControllerPairing.deviceID)
            }
        case .verifying:
            if let pendingProof {
                send(.init(kind: .pairProof), payload: pendingProof)
            }
        case .codeEntry, .connected:
            // Still here: the person is typing, or playing.
            send(.init(kind: .hello))
        case .searching, .ended:
            break
        }
    }

    func stop() {
        stopping = true
        ticker?.cancel(); ticker = nil
        // The polite leave, so the television keeps the game running
        // rather than pausing for a controller that left on purpose.
        if connected { send(.init(kind: .goodbye)) }
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
        connected = false
        phase = .searching
        requester = nil
        pendingProof = nil
    }

    /// The foreground edge. If the link died while the app was away,
    /// begin again from the browse; if it is healthy, do nothing.
    func wake() {
        guard !connected, !stopping else { return }
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        requester = nil
        pendingProof = nil
        start()
    }

    /// The Try Again button after an ended pairing: same connection if
    /// it survived, fresh join either way.
    func retry() {
        guard case .ended = phase else { return }
        requester = nil
        pendingProof = nil
        if connection != nil {
            phase = .joining
            send(.init(kind: .join), payload: ControllerPairing.deviceID)
        } else {
            wake()
        }
    }

    /// The typed code, judged by the television. Wrong answers come
    /// back as pairFail and land in codeEntry with one fewer try.
    func submitCode(_ code: String) {
        guard case .codeEntry = phase, let requester,
              let proof = requester.proof(code: code) else { return }
        let payload = requester.phoneID + proof
        pendingProof = payload
        phase = .verifying
        send(.init(kind: .pairProof), payload: payload)
    }

    private func connect(to endpoint: NWEndpoint) {
        guard connection == nil else { return }
        let c = NWConnection(to: endpoint, using: ControllerLink.parameters())
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    guard let self else { return }
                    self.phase = .joining
                    self.status = "found the television"
                    self.startTicker()
                    // UDP has no handshake, so the television does not
                    // know we exist until we say something. This is
                    // that, and the ticker repeats it until answered.
                    self.send(.init(kind: .join), payload: ControllerPairing.deviceID)
                    // The browse has done its job. Leaving it running is
                    // what kept AWDL awake and produced the stalls the
                    // aim lab spent an evening chasing.
                    self.browser?.cancel()
                    self.browser = nil
                case .failed, .cancelled:
                    guard let self else { return }
                    self.ticker?.cancel(); self.ticker = nil
                    self.connected = false
                    self.status = "disconnected"
                    self.requester = nil
                    self.pendingProof = nil
                    // A failure with nobody having called stop() means
                    // the flow died under us, suspension being the
                    // common cause. Go back to looking; the sequence
                    // deliberately does not reset, so the television
                    // never sees numbering move backwards inside what it
                    // still thinks is one conversation.
                    if !self.stopping {
                        self.phase = .searching
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
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = ControllerLink.Packet.decode(data) {
                let payload = Data(data.dropFirst(ControllerLink.Packet.size))
                Task { @MainActor in self.handle(packet, payload: payload) }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func handle(_ packet: ControllerLink.Packet, payload: Data) {
        switch packet.kind {
        case .hello:
            // Joined. The name confirms which cabinet to draw.
            if let name = ControllerLink.validShortname(String(decoding: payload, as: UTF8.self)) {
                shortname = name
                status = name
            }
            requester = nil
            pendingProof = nil
            phase = .connected
            connected = true

        case .pairNeeded:
            guard case .joining = phase, requester == nil else { return }
            status = "this television needs pairing"
            let fresh = ControllerPairing.Requester(phoneID: ControllerPairing.deviceID)
            requester = fresh
            send(.init(kind: .pairRequest), payload: fresh.requestPayload)

        case .pairChallenge:
            guard case .joining = phase, let requester else { return }
            if requester.acceptChallenge(payload) {
                phase = .codeEntry(triesLeft: 3)
            }

        case .pairSuccess:
            guard let requester, payload.count == 32 else { return }
            guard let secret = requester.acceptSuccess(payload), let tvID = requester.tvID else {
                end("The television's answer did not check out, so nothing was stored.")
                return
            }
            do {
                try ControllerPairing.savePairing(secret: secret, forPeer: tvID)
                self.requester = nil
                pendingProof = nil
                phase = .joining
                send(.init(kind: .join), payload: ControllerPairing.deviceID)
            } catch {
                end("This phone could not store the pairing.")
            }

        case .pairFail:
            switch ControllerLink.Packet.FailReason(rawValue: packet.a) {
            case .wrongCode:
                pendingProof = nil
                phase = .codeEntry(triesLeft: max(1, Int(packet.b)))
            case .cancelled:
                end("Three wrong codes. The television took the code down; try again for a fresh one.")
            case .busy:
                end("The television is pairing another phone. Try again in a moment.")
            case .expired:
                end("The code expired. Try again for a fresh one.")
            case .storage:
                end("The television could not store the pairing.")
            case nil:
                end("Pairing failed.")
            }

        default:
            break
        }
    }

    private func end(_ message: String) {
        requester = nil
        pendingProof = nil
        phase = .ended(message)
    }

    private func send(_ packet: ControllerLink.Packet, payload: Data = Data()) {
        guard let connection else { return }
        var p = packet
        seq &+= 1
        p.seq = seq
        connection.send(content: p.encoded() + payload, completion: .idempotent)
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
