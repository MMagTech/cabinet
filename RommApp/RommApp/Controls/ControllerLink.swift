import CryptoKit
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
/// unless its "Allow a phone as a controller" setting is on, and then
/// only while a game is running or its settings screen is open as a
/// pairing lobby. The first time a given phone connects, the television
/// shows a short code, the person types it on the phone, and both sides
/// store a shared secret through ControllerPairing; that is the last
/// time anyone does anything. A phone the television has never met gets
/// that pairing conversation instead of a control connection. Every
/// packet after joining carries proof of the paired secret, an HMAC tag
/// under a per-session key, checked before a single byte of input is
/// parsed; no proof, no parsing. Discovery is Bonjour and stays Bonjour in the
/// shipping design: pairing is what makes browsing harmless, since a
/// phone on a stranger's network finds a television it cannot prove
/// anything to and does nothing. An older plan gated discovery through
/// RomM presence instead; the design doc replaced it, see "What was
/// originally planned, and why it changed" there.
/// One advertisement at a time. A pairing screen can still be alive
/// underneath a game launched over it, so the player posts these and
/// the pairing screen yields its listener while a game holds one.
///
/// Shared rather than tvOS-only since 2026-08-30, when the Mac started
/// hosting phones too. The string keeps its original tvOS name so a
/// phone and a host that predate the move still agree.
extension Notification.Name {
    static let cabinetGameLinkStarted = Notification.Name("com.mmagtech.RommAppTV.gameLinkStarted")
    static let cabinetGameLinkEnded = Notification.Name("com.mmagtech.RommAppTV.gameLinkEnded")
}

enum ControllerLink {
    static let bonjourType = "_cabinet-probe._udp"
    static let serviceName = "CabinetLink"
    /// The port byte a hello carries before any seat is claimed. 255
    /// rather than 0, because 0 is player one and a phone that has
    /// not played is not player one.
    static let unseatedPort = 255

    /// One player action. Fixed width, no lengths and no allocation, so
    /// the only thing an unexpected packet can do is decode to nonsense
    /// inside a known range and be dropped. Pairing kinds append a
    /// payload after the fixed header, the same way hello appends the
    /// romset name, and every payload is length-checked before a byte
    /// of it is read.
    struct Packet {
        enum Kind: UInt8 {
            // From the television: tvID (8) + nonce (16) + proof (8) +
            // player port (1) + the running romset's name. From a
            // joined phone: empty, a tagged heartbeat saying still
            // held.
            case hello = 0
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
            /// Television to phone, after a join: where the bottom
            /// screen's video stream lives. Payload is an 8-byte tag
            /// over the rest (session key, context "t2p-video"), a
            /// 2-byte big-endian TCP port, and a 16-byte connect
            /// token. Port zero, tagged the same way, revokes a
            /// standing offer. Phones that predate this kind drop it
            /// unread, which is the packet format's own rule.
            case videoOffer = 17
            /// Television to phone: which player you just became.
            /// Sent when a seat is claimed, not at join, because a
            /// phone is nobody until somebody plays on it. Payload is
            /// an 8-byte tag over the port byte, under the session
            /// key, so a seat cannot be forged any more than input
            /// can. Phones that predate this kind drop it unread.
            case seat = 18
            /// Television to phone: the game just knocked the motor.
            /// A phone holding a seat IS that player's controller, and
            /// on an Apple TV it is the only thing in the room with a
            /// Taptic Engine, so without this the person holding it
            /// feels nothing a game ever does. Payload is an 8-byte
            /// tag over the body (session key, context "t2p-rumble"),
            /// then one flag byte for the strong motor and two
            /// big-endian bytes of strength. Tagged like every other
            /// television-to-phone kind, so nobody on the network can
            /// buzz a stranger's phone. Phones that predate this kind
            /// drop it unread, which is the packet format's own rule.
            case rumble = 19
            /// Phone to television: which step of sighting in the gun
            /// the phone is on, in `a`, using SightingStep's raw value.
            /// The phone owns the sequence because the phone owns the
            /// measurements; the television only has to draw a target
            /// where this says to and get out of the way when it says
            /// done. Deliberately not player input: sighting in is not
            /// playing and must not claim a seat. Televisions that
            /// predate this kind drop it unread, which is the packet
            /// format's own rule, and a phone sighting in against one
            /// simply gets no targets drawn.
            case sighting = 20
            /// Television to phone: the running game drew on player
            /// one's VMU LCD. Payload is an 8-byte tag over the body
            /// (session key, context "t2p-vmulcd"), then 192 bytes:
            /// the 48x32 1-bit frame, row-major, 8 pixels per byte,
            /// bit 7 leftmost. Sent when the picture changes, which is
            /// how often a real game wrote its VMU, plus once at join
            /// so a late phone starts current. The display half of the
            /// companion design: the phone-as-controller screen shows
            /// this in the Dreamcast pad where the real controller's
            /// VMU window sat. Phones that predate this kind drop it
            /// unread, which is the packet format's own rule.
            case vmuLCD = 21

            /// True for the kinds a person generates by playing, which
            /// is what earns a seat. Deliberately excludes the
            /// heartbeat (arriving is not playing) and the menu verbs
            /// (pausing or putting the controller away needs no seat,
            /// and never did).
            var isPlayerInput: Bool {
                switch self {
                case .button, .stick, .relative, .pointer, .offscreen:
                    return true
                default:
                    return false
                }
            }
            // The front door. A phone announces who it is with a fresh
            // nonce; a known phone gets hello back carrying the
            // television's nonce and proof, the two nonces plus the
            // stored secret make the session key, and only packets
            // proving that key count as input. An unknown phone is sent
            // to pairing instead.
            case join = 10          // phone to tv: phoneID (8) + nonce (16)
            case pairNeeded = 11    // tv to phone: tvID (8)
            case pairRequest = 12   // phone to tv: phoneID (8) + public key (32)
            case pairChallenge = 13 // tv to phone: tvID (8) + public key (32) + salt (16)
            case pairProof = 14     // phone to tv: phoneID (8) + proof (32)
            case pairSuccess = 15   // tv to phone: acknowledgement (32)
            case pairFail = 16      // tv to phone: a: reason, b: tries left, or seconds for the lockout reasons
        }

        /// pairFail's `a` field. Small and explicit, so the phone can
        /// say something truthful instead of "error".
        enum FailReason: Int16 {
            case wrongCode = 1
            case cancelled = 2
            case busy = 3
            case expired = 4
            case storage = 5
            /// Paired, welcome, and out of seats: both player slots
            /// are taken, exactly as a third gamepad finds them.
            case full = 6
            /// Three wrong codes put the television in a short
            /// guessing lockout. Distinct from busy so the phone can
            /// say what is actually happening instead of blaming a
            /// phone that does not exist.
            case cooldown = 7
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

    /// The standard sliding window against replay, DTLS's shape: a
    /// sequence number is admitted once, ever. Higher than anything
    /// seen slides the window forward; within the last sixty four and
    /// unseen is honest reordering and admitted; seen already, or older
    /// than the window, is refused. Sixty four packets is about a
    /// second at input rates, far past any reordering a LAN produces.
    /// Only run AFTER a packet's tag verifies, so garbage cannot move
    /// the window.
    struct ReplayWindow {
        private var high: UInt32 = 0
        private var seen: UInt64 = 0

        mutating func admit(_ seq: UInt32) -> Bool {
            guard seq != 0 else { return false }
            if seq > high {
                let shift = UInt64(seq - high)
                seen = shift >= 64 ? 0 : seen << shift
                seen |= 1
                high = seq
                return true
            }
            let offset = UInt64(high - seq)
            guard offset < 64 else { return false }
            let mask: UInt64 = 1 << offset
            guard seen & mask == 0 else { return false }
            seen |= mask
            return true
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
/// Where a gun is in the business of learning where the television is.
///
/// Three pulls: the middle of the picture, then two opposite corners, and
/// the mapping from wrist angle to a spot on screen falls out of them,
/// including which way round the axes go and how far away the player is
/// sitting. Exactly how an arcade cabinet's gun was set up, and the same
/// sequence the aim lab proved out.
///
/// The corners are at 0.75 of the way out rather than the very edge, so
/// the target is comfortably on the picture and nobody is asked to shoot
/// at a bezel.
enum SightingStep: Int, Sendable {
    case centre = 0, farCorner = 1, nearCorner = 2, done = 3

    /// Where the television should draw the target, in the same -1...1
    /// screen space the pointer channel already speaks.
    var target: (x: Double, y: Double)? {
        switch self {
        case .centre: return (0, 0)
        case .farCorner: return (0.75, -0.75)
        case .nearCorner: return (-0.75, 0.75)
        case .done: return nil
        }
    }

    var prompt: String {
        switch self {
        case .centre: return "Shoot the middle"
        case .farCorner: return "Shoot the top right"
        case .nearCorner: return "Shoot the bottom left"
        case .done: return "Ready"
        }
    }
}

final class ControllerLinkReceiver {
    /// What is running, sent to a phone the moment it joins so it can
    /// draw the right cabinet.
    private let shortname: String
    /// Which seat a joining phone gets, by paired identity, or nil for
    /// a full house. Handed in as a closure for the same reason as the
    /// verbs below: the slot rule lives with the pads, and this file
    /// never learns what a controller manager is. Called on the
    /// receive queue; the owner decides how to reach its own world.
    private let assignPort: (Data) -> Int?
    /// A deliberate goodbye gives the seat back. Drops do not; the
    /// seat outliving a Wi-Fi blip is what keeps two players from
    /// swapping ports mid-game.
    private let releasePort: (Data) -> Void
    private let onButton: (Int, Int, Bool) -> Void
    private let onStick: (Int, Double, Double) -> Void
    private let onRelative: (Int, Int, Int) -> Void
    private let onPointer: (Int, Double, Double, Bool) -> Void
    private let onOffscreen: (Int, Bool) -> Void
    /// Set rather than injected, because sighting in is optional: the
    /// Controllers page runs a receiver too and has no screen to draw a
    /// target on. Nil simply means nothing is drawn, which is also what
    /// a television that predates this kind does.
    var onSighting: ((Int, SightingStep) -> Void)?
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
        /// True once a packet has proven the session key, and not one
        /// moment earlier: a join names a stored pairing, but names are
        /// public, so presence is only believed of proof.
        var joined = false
        var phoneID: Data?
        /// The nonce the phone's join carried. A repeat join with the
        /// same nonce is a retry and gets the cached hello; a new nonce
        /// is a new session and re-derives everything.
        var phoneNonce: Data?
        var sessionKey: SymmetricKey?
        /// The seat this phone holds, or nil while it holds none.
        /// Seats are claimed by the first input a person actually
        /// sends, never at join: a phone left open on a table beats
        /// any human reaching for a controller, so joining could not
        /// be allowed to mean playing. See the claim in handle().
        var port: Int?
        /// The datagram flow this peer lives on, kept so an offer made
        /// after the join (the video server starts when the game side
        /// is ready, not when the phone arrives) can still reach them.
        var connection: NWConnection?
        /// The exact hello sent for this session, kept so retries
        /// converge on one answer.
        var helloPayload: Data?
        var window = ControllerLink.ReplayWindow()
        /// When this phone last said anything believable. Input flows
        /// constantly from a held phone (aim at 60Hz, every touch, a
        /// heartbeat otherwise), so silence IS absence. For a joined
        /// phone only proven packets refresh this; a stranger's
        /// pairing traffic counts, because its crypto speaks for
        /// itself and all it buys is not being forgotten mid-type.
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
    /// Which connection asked for the code on screen. A pairing slot
    /// belongs to the phone that opened it, and there is only one, so
    /// when that phone goes quiet the slot has to come back rather
    /// than sit out its full timeout: for those seconds a code stood
    /// on the television belonging to nobody, while every OTHER phone
    /// asking to pair was told another phone was pairing. Found on
    /// hardware 2026-08-23, a second phone refused for a minute and a
    /// half and then working on its own, which is what a slot ageing
    /// out looks like from the couch.
    private var acceptorKey: ObjectIdentifier?
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
         assignPort: @escaping (Data) -> Int?,
         releasePort: @escaping (Data) -> Void,
         onButton: @escaping (Int, Int, Bool) -> Void,
         onStick: @escaping (Int, Double, Double) -> Void,
         onRelative: @escaping (Int, Int, Int) -> Void,
         onPointer: @escaping (Int, Double, Double, Bool) -> Void,
         onOffscreen: @escaping (Int, Bool) -> Void,
         onPause: @escaping (Bool) -> Void,
         onSave: @escaping () -> Void,
         onLoad: @escaping () -> Void,
         onPhone: @escaping (Bool) -> Void,
         onPairingCode: @escaping (String?) -> Void,
         onDrop: @escaping () -> Void) {
        self.shortname = shortname
        self.assignPort = assignPort
        self.releasePort = releasePort
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

    /// Everything holds this receiver weakly (the connection handler,
    /// the liveness timer), so dropping it without stop() deallocates
    /// it while its listener would otherwise keep running: a deaf
    /// zombie that still owns the Bonjour name and answers nobody.
    /// Tearing down here makes that whole class of bug impossible.
    deinit {
        liveness?.cancel()
        listener?.cancel()
        connections.forEach { $0.cancel() }
    }

    func start() {
        guard listener == nil else { return }
        guard let l = try? NWListener(using: ControllerLink.parameters()) else { return }
        // The game rides in the service name, so a phone can know what
        // is playing without ever connecting. An empty shortname is the
        // lobby: the television's settings screen listening so a phone
        // can pair with no game running; its hello names no game and
        // the phone waits for one. The hello packet stays as
        // confirmation once a phone has joined.
        let serviceName = shortname.isEmpty
            ? ControllerLink.serviceName
            : "\(ControllerLink.serviceName)-\(shortname)"
        l.service = NWListener.Service(name: serviceName, type: ControllerLink.bonjourType)
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
            let joinedDied = dead.contains { $0.value.joined }
            if let acceptorKey, dead.keys.contains(acceptorKey) {
                // Whoever was mid-pairing is gone. Take the code down
                // with them and free the slot for the next phone.
                acceptor = nil
                self.acceptorKey = nil
                onPairingCode(nil)
            }
            for key in dead.keys { peers[key] = nil }
            connections.removeAll { c in
                guard dead.keys.contains(ObjectIdentifier(c)) else { return false }
                c.cancel()
                return true
            }
            if joinedDied {
                // ANY player's drop pauses, the reaction a pad
                // disconnect has always had: their person is standing
                // there holding nothing, whoever else is still in. The
                // presence flag stays truthful for whoever remains,
                // and the dropped phone's seat stays claimed, so
                // coming back means coming back as the same player.
                onPhone(peers.values.contains { $0.joined })
                onDrop()
            }
        }
        if let acceptor, Date().timeIntervalSince(acceptor.startedAt) > pairingTimeout {
            self.acceptor = nil
            self.acceptorKey = nil
            onPairingCode(nil)
        }
    }

    /// The standing video offer, replayed to every phone that joins
    /// while it stands. Port zero is the revocation.
    private var videoOffer: (port: UInt16, token: Data)?

    /// Tell joined phones where the bottom screen's stream lives. The
    /// offer keeps standing, so a phone that joins later hears it too.
    func offerVideo(port: UInt16, token: Data) {
        videoOffer = (port, token)
        for peer in peers.values where peer.joined {
            sendVideoOffer(port: port, token: token, to: peer)
        }
    }

    /// Withdraw the offer and tell whoever heard it. Phones also treat
    /// the stream's own connection dying as the end, so this is
    /// courtesy, not load-bearing.
    func revokeVideo() {
        guard videoOffer != nil else { return }
        videoOffer = nil
        let noToken = Data(count: 16)
        for peer in peers.values where peer.joined {
            sendVideoOffer(port: 0, token: noToken, to: peer)
        }
    }

    /// The last VMU LCD frame sent, kept so a phone that joins with a
    /// game already mid-play starts from the current picture instead of
    /// a blank window: the videoOffer's standing-offer pattern.
    private var vmuFrame: Data?

    /// Player one's VMU screen changed. 192 packed bytes as Kind.vmuLCD
    /// documents; anything else is refused rather than trimmed. Safe to
    /// call from any thread: the send happens on the receive queue, the
    /// same discipline sendRumble follows.
    func sendVMULCD(_ packed: Data) {
        guard packed.count == 192 else { return }
        queue.async {
            self.vmuFrame = packed
            for peer in self.peers.values where peer.joined {
                self.sendVMULCDFrame(packed, to: peer)
            }
        }
    }

    private func sendVMULCDFrame(_ packed: Data, to peer: Peer) {
        guard let key = peer.sessionKey, let connection = peer.connection else { return }
        let tag = ControllerPairing.tag(key: key, context: "t2p-vmulcd", bytes: packed)
        reply(.vmuLCD, payload: tag + packed, on: connection)
    }

    /// Tell a phone which player it just became. Tagged under the
    /// session key, the same standard the hello and the video offer
    /// meet, so a seat cannot be forged.
    private func sendSeat(_ port: Int, to peer: Peer, on connection: NWConnection) {
        guard let key = peer.sessionKey else { return }
        let body = Data([UInt8(clamping: port)])
        let tag = ControllerPairing.tag(key: key, context: "t2p-seat", bytes: body)
        reply(.seat, payload: tag + body, on: connection)
    }

    /// Knock the motor on whichever phone holds this seat, if one
    /// does. Silent when the seat belongs to a real controller or to
    /// nobody, which is every case but the companion one, so this
    /// costs a dictionary walk and nothing else.
    func sendRumble(port: Int, strong: Bool, strength: UInt16) {
        queue.async {
            guard let peer = self.peers.values.first(where: { $0.port == port }),
                  let key = peer.sessionKey, let connection = peer.connection
            else { return }
            var body = Data([strong ? 1 : 0])
            body.append(UInt8(strength >> 8)); body.append(UInt8(strength & 0xff))
            let tag = ControllerPairing.tag(key: key, context: "t2p-rumble", bytes: body)
            self.reply(.rumble, payload: tag + body, on: connection)
        }
    }

    private func sendVideoOffer(port: UInt16, token: Data, to peer: Peer) {
        guard let key = peer.sessionKey, let connection = peer.connection else { return }
        var body = Data()
        body.append(UInt8(port >> 8)); body.append(UInt8(port & 0xff))
        body.append(token.prefix(16))
        let tag = ControllerPairing.tag(key: key, context: "t2p-video", bytes: body)
        reply(.videoOffer, payload: tag + body, on: connection)
    }

    func stop() {
        videoOffer = nil
        vmuFrame = nil
        liveness?.cancel()
        liveness = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        peers.removeAll()
        acceptor = nil
        acceptorKey = nil
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
                self.apply(packet, payload: Data(data.dropFirst(ControllerLink.Packet.size)),
                           from: connection)
            }
            if error == nil {
                self.receive(on: connection)
            }
        }
    }

    private func reply(_ kind: ControllerLink.Packet.Kind, payload: Data = Data(),
                       a: Int16 = 0, b: Int16 = 0, on connection: NWConnection) {
        let packet = ControllerLink.Packet(kind: kind, a: a, b: b)
        connection.send(content: packet.encoded() + payload, completion: .idempotent)
    }

    private func fail(_ reason: ControllerLink.Packet.FailReason, b: Int16 = 0,
                      on connection: NWConnection) {
        reply(.pairFail, a: reason.rawValue, b: b, on: connection)
    }

    private func apply(_ p: ControllerLink.Packet, payload: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        guard let peer = peers[key] else { return }

        switch p.kind {
        case .join:
            guard payload.count >= 8 + 16 else { return }
            peers[key]?.lastHeard = Date()
            let phoneID = Data(payload.prefix(8))
            let phoneNonce = Data(payload.dropFirst(8).prefix(16))
            guard let secret = ControllerPairing.secret(forPeer: phoneID) else {
                reply(.pairNeeded, payload: tvID, on: connection)
                return
            }
            if peer.phoneNonce == phoneNonce, let cached = peer.helloPayload {
                // The same join again means our hello got lost. Same
                // answer, so retries converge on one session.
                reply(.hello, payload: cached, on: connection)
                return
            }
            // No seat here. Joining is arriving, not playing, and a
            // phone that merely reconnected while sitting on a table
            // would otherwise take player one from whoever is
            // actually reaching for a controller. The seat is claimed
            // by the first input below, and a full house is answered
            // then, when somebody actually tried to play.
            let port = ControllerLink.unseatedPort
            // A fresh nonce is a fresh session: new keys, new replay
            // window, and joined goes back to unproven until the first
            // tagged packet lands.
            let tvNonce = ControllerPairing.randomBytes(16)
            let nameBytes = Data(shortname.utf8.prefix(32))
            // Which player this phone is, under the proof, so not
            // even the cosmetic byte can be forged. At join this is
            // always the unseated marker; the real seat arrives in
            // its own tagged packet the moment one is claimed.
            let portByte = Data([UInt8(clamping: port)])
            let helloKey = ControllerPairing.helloKey(secret: secret, phoneNonce: phoneNonce)
            let helloTag = ControllerPairing.tag(
                key: helloKey, context: "t2p-hello", bytes: tvID + tvNonce + portByte + nameBytes)
            let helloPayload = tvID + tvNonce + helloTag + portByte + nameBytes
            peers[key] = Peer(
                phoneID: phoneID,
                phoneNonce: phoneNonce,
                sessionKey: ControllerPairing.sessionKey(
                    secret: secret, phoneNonce: phoneNonce, tvNonce: tvNonce),
                port: nil,
                connection: connection,
                helloPayload: helloPayload,
                lastHeard: Date()
            )
            reply(.hello, payload: helloPayload, on: connection)
            return

        case .pairRequest:
            guard payload.count == 8 + 32 else { return }
            peers[key]?.lastHeard = Date()
            let phoneID = Data(payload.prefix(8))
            let phonePub = Data(payload.suffix(32))
            if let until = pairingLockedUntil, until > Date() {
                // The phone runs a countdown off this and retries by
                // itself, the passcode-lockout pattern, so the seconds
                // are the message.
                fail(.cooldown, b: Int16(clamping: Int(until.timeIntervalSinceNow.rounded(.up))), on: connection)
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
                    self.acceptorKey = nil
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
            acceptorKey = key
            onPairingCode(fresh.code)
            reply(.pairChallenge, payload: fresh.challengePayload, on: connection)
            return

        case .pairProof:
            guard payload.count == 8 + 32 else { return }
            peers[key]?.lastHeard = Date()
            let phoneID = Data(payload.prefix(8))
            let proof = Data(payload.suffix(32))
            guard let acceptor, acceptor.phoneID == phoneID else {
                if let lastAck, lastAck.phoneID == phoneID,
                   Date().timeIntervalSince(lastAck.at) < 60 {
                    // Its success reply was lost; say it again. The
                    // phone joins properly on its own from here.
                    reply(.pairSuccess, payload: lastAck.ack, on: connection)
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
                    self.acceptorKey = nil
                    onPairingCode(nil)
                    // Paired, not yet joined: the phone follows up
                    // with a join and earns presence with its first
                    // proven packet, the same road every session takes.
                    reply(.pairSuccess, payload: ack, on: connection)
                } catch {
                    self.acceptor = nil
                    self.acceptorKey = nil
                    onPairingCode(nil)
                    fail(.storage, on: connection)
                }
            case .wrong(let triesLeft):
                fail(.wrongCode, b: Int16(triesLeft), on: connection)
            case .cancelled:
                self.acceptor = nil
                self.acceptorKey = nil
                onPairingCode(nil)
                pairingLockedUntil = Date().addingTimeInterval(30)
                fail(.cancelled, b: 30, on: connection)
            }
            return

        case .pairNeeded, .pairChallenge, .pairSuccess, .pairFail:
            // Kinds only this side sends. Arriving here they are noise.
            return

        default:
            break
        }

        // Everything from here, the heartbeat included, is the phone
        // driving a game, and it must prove itself before a single
        // byte of it is treated as input: a session key from the join
        // handshake, a valid tag over the exact header bytes, and a
        // sequence number this session has never admitted. No proof,
        // no parsing.
        guard let sessionKey = peer.sessionKey,
              payload.count >= ControllerPairing.tagLength,
              ControllerPairing.validTag(
                  Data(payload.prefix(ControllerPairing.tagLength)),
                  key: sessionKey, context: "p2t", bytes: p.encoded()),
              peers[key]!.window.admit(p.seq)
        else { return }

        peers[key]?.lastHeard = Date()
        if !peer.joined {
            peers[key]?.joined = true
            onPhone(true)
            if let offer = videoOffer, let fresh = peers[key] {
                sendVideoOffer(port: offer.port, token: offer.token, to: fresh)
            }
            if let frame = vmuFrame, let fresh = peers[key] {
                sendVMULCDFrame(frame, to: fresh)
            }
        }

        // Aim and stick positions are absolute, so a stale one snaps the
        // control backwards and is worth dropping. Buttons are edges and
        // must never be dropped: losing an "up" leaves it held forever.
        // The replay window has already refused duplicates; this is
        // ordering, not security.
        let last = peer.lastSeq
        let stale = p.seq < last
        if p.seq > last { peers[key]?.lastSeq = p.seq }

        // The seat, claimed by playing rather than by arriving. Only
        // the kinds a person generates count: a heartbeat is not
        // playing, and neither is opening the app. The claim happens
        // before the input is dispatched, in this same frame, so the
        // button that earns the seat still reaches the game.
        var port = peers[key]?.port
        if port == nil, p.kind.isPlayerInput {
            guard let phoneID = peer.phoneID else { return }
            guard let claimed = assignPort(phoneID) else {
                // Every seat is taken, and now is when it matters:
                // somebody pressed something and nothing happened.
                fail(.full, on: connection)
                return
            }
            peers[key]?.port = claimed
            port = claimed
            sendSeat(claimed, to: peers[key]!, on: connection)
        }

        switch p.kind {
        case .hello:
            // The heartbeat: nothing but the liveness it just bought.
            break
        case .button:
            guard let port else { return }
            onButton(port, Int(p.a), p.flag)
        case .stick:
            guard !stale, let port else { return }
            onStick(port, Double(p.a) / 10000, Double(p.b) / 10000)
        case .relative:
            guard let port else { return }
            onRelative(port, Int(p.a), Int(p.b))
        case .pointer:
            guard !stale, let port else { return }
            onPointer(port, Double(p.a) / 10000, Double(p.b) / 10000, p.flag)
        case .offscreen:
            guard let port else { return }
            onOffscreen(port, p.flag)
        case .sighting:
            guard let port, let step = SightingStep(rawValue: Int(p.a)) else { return }
            onSighting?(port, step)
        case .pause:
            onPause(p.flag)
        case .saveState:
            onSave()
        case .loadState:
            onLoad()
        case .goodbye:
            // Deliberate. Forget the phone, give the seat back, pause
            // nothing.
            if let phoneID = peer.phoneID { releasePort(phoneID) }
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

/// Watches for a television playing an arcade game, for Home's offer.
///
/// Browse only, never a connection, and only on a phone that has
/// paired before: the never-paired majority must never browse, which
/// is the local-network prompt promise, while a paired phone browsing
/// is exactly what pairing made harmless. The design doc's
/// browse-after-a-tap rule was amended for this on 2026-08-23; the
/// offer got to be truthful again in exchange.
@MainActor
final class ControllerLinkScout: ObservableObject {
    /// The romset a television on this network is running, or nil.
    /// Lobby advertisements (no game) never set this.
    @Published private(set) var playing: String?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "cabinet.link.scout")
    /// The advertisement the browser is currently reporting, believed
    /// only once a television has answered for it.
    private var advertised: (name: String, endpoint: NWEndpoint)?
    private var probe: NWConnection?
    private var prover: DispatchSourceTimer?
    /// When the television last actually answered. A Bonjour record
    /// outlives the thing that published it whenever the goodbye is
    /// missed, which a killed app or a Wi-Fi hiccup both manage, so
    /// an advertisement alone is a rumour.
    private var lastAnswer = Date.distantPast

    func start() {
        guard ControllerPairing.hasAnyPairing else { return }
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: ControllerLink.bonjourType, domain: nil),
                                using: ControllerLink.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let found = results.compactMap { r -> (String, NWEndpoint)? in
                guard let name = ControllerLink.shortname(fromService: r.endpoint) else { return nil }
                return (name, r.endpoint)
            }.first
            Task { @MainActor in
                if found?.0 != self.advertised?.name {
                    // A different game, or none: nothing carries over
                    // from the last one, including its proof.
                    self.lastAnswer = .distantPast
                    self.playing = nil
                }
                self.advertised = found
                self.askTelevision()
            }
        }
        self.browser = browser
        browser.start(queue: queue)

        // Keep asking. A game that ends while the card is up has to
        // take the card down with it, and the only honest signal is
        // the television going quiet.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 4, repeating: 4)
        timer.setEventHandler { [weak self] in Task { @MainActor in self?.askTelevision() } }
        timer.resume()
        prover = timer
    }

    /// Ask the advertised television whether it is really there, and
    /// believe the card only while one keeps answering.
    ///
    /// The question is a join, which since seats became something a
    /// person claims by playing is genuinely just arriving: it takes
    /// no seat, and because this never sends a tagged packet it never
    /// counts as joined, so it cannot mark this phone present or
    /// pause anybody's game when it stops.
    private func askTelevision() {
        guard let advertised else {
            probe?.cancel(); probe = nil
            playing = nil
            return
        }
        // Two silent rounds and the rumour is dropped.
        if lastAnswer > .distantPast, Date().timeIntervalSince(lastAnswer) > 9 {
            playing = nil
        }
        probe?.cancel()
        let c = NWConnection(to: advertised.endpoint, using: ControllerLink.parameters())
        probe = c
        let name = advertised.name
        c.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            var packet = ControllerLink.Packet(kind: .join)
            packet.seq = 0
            let payload = ControllerPairing.deviceID + ControllerPairing.randomBytes(16)
            c.send(content: packet.encoded() + payload, completion: .idempotent)
            Task { @MainActor in self?.listenForAnswer(on: c, name: name) }
        }
        c.start(queue: queue)
    }

    private func listenForAnswer(on connection: NWConnection, name: String) {
        connection.receiveMessage { [weak self] data, _, _, _ in
            guard let data, ControllerLink.Packet.decode(data) != nil else { return }
            // Any answer at all proves a television is there and still
            // advertising this game; what it says does not matter.
            Task { @MainActor in
                self?.lastAnswer = Date()
                self?.playing = name
            }
        }
    }

    func stop() {
        prover?.cancel(); prover = nil
        probe?.cancel(); probe = nil
        browser?.cancel()
        browser = nil
        advertised = nil
        lastAnswer = .distantPast
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
        /// Three wrong codes: the television is refusing attempts
        /// until the deadline. The panel shows a countdown and the
        /// ticker retries by itself the moment it passes, the
        /// passcode-lockout pattern, so a fresh code simply appears.
        case cooldown(until: Date)
        /// Over, with a sentence saying why. retry() starts again.
        case ended(String)
    }

    @Published private(set) var phase: Phase = .searching {
        didSet { if oldValue != phase { phaseChangedAt = Date() } }
    }
    /// When the phase last moved, for the two giving-up rules in
    /// tick(). Everything else is event driven.
    private var phaseChangedAt = Date()
    @Published private(set) var status = "Looking for a TV"
    @Published private(set) var connected = false
    /// The romset the television is running, once a join has been
    /// answered. The panel is built from this, which is why the phone
    /// draws the right cabinet without being told anything else.
    @Published private(set) var shortname: String?
    /// Which player this phone is, zero based, or nil while it is
    /// nobody. A phone earns a seat by playing, not by joining, so
    /// this stays nil from the handshake until the first button, and
    /// the panel simply wears no badge until then. Two people
    /// staring at identical panels not knowing who is who is a bad
    /// first thirty seconds; two people both told they are player one
    /// would be worse.
    @Published private(set) var playerIndex: Int?
    /// Where the television says the bottom screen's stream lives, nil
    /// until a proven offer arrives and back to nil when one is
    /// revoked. The DS panel watches this and dials in.
    @Published private(set) var videoOffer: VideoOffer?
    /// Player one's VMU screen as the television last sent it, 192
    /// packed bytes (Kind.vmuLCD), nil until a Dreamcast game draws
    /// one. The DC panel's little window watches this.
    @Published private(set) var vmuLCD: Data?

    struct VideoOffer: Equatable {
        let port: Int
        let token: Data
    }

    /// Fired on the main thread when the game knocks this player's
    /// motor. A closure rather than a published property because a
    /// rumble is an event, not a state: two identical knocks in a row
    /// are two knocks, and a property would swallow the second.
    var onRumble: ((_ strong: Bool, _ strength: UInt16) -> Void)?

    /// The television's address, for dialing the stream: the video
    /// connection goes to the same host the datagrams already reach.
    var remoteHost: NWEndpoint.Host? {
        guard case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint
        else { return nil }
        return host
    }

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "cabinet.link.send", qos: .userInteractive)
    private var seq: UInt32 = 0
    /// This conversation's contribution to the session key, fresh per
    /// connection, so no two sessions ever share one.
    private var phoneNonce = Data()
    /// Set the moment the television's hello proves itself, and the
    /// reason every packet sent after that carries a tag.
    private var sessionKey: SymmetricKey?
    /// One slow drumbeat drives everything that repeats: the join
    /// retries (UDP loses things), the proof retries, and the
    /// heartbeat that keeps the television's liveness rule from reading
    /// an idle touch panel as an absent one. An attract screen or a
    /// moment between lives would otherwise read as a drop and pause
    /// the game under a player who is right there.
    private var ticker: DispatchSourceTimer?
    /// The pairing attempt in progress, if the television demanded one.
    private var requester: ControllerPairing.Requester?
    /// Where the current connection points, and the endpoint most
    /// recently given up on. Game relaunches on the television leave
    /// stale Bonjour advertisements behind for a while; without this,
    /// a retry could glue itself to the same dead one it just left.
    private var currentEndpoint: NWEndpoint?
    private var avoidEndpoint: (key: String, until: Date)?
    /// Hellos that failed their proof, counted so a television whose
    /// stored secret no longer matches ours surfaces as re-pairing
    /// instead of as silence.
    private var badHelloCount = 0
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
            guard let self else { return }
            Task { @MainActor in
                // Skip the endpoint that just went dead under us, if
                // any; fall back to it only when nothing else exists.
                var candidates = Array(results)
                if let avoid = self.avoidEndpoint, avoid.until > Date() {
                    let living = candidates.filter { String(describing: $0.endpoint) != avoid.key }
                    if !living.isEmpty { candidates = living }
                }
                // A game beats the lobby when both are advertised,
                // which can briefly happen as one hands off to the
                // other.
                let best = candidates.first { ControllerLink.shortname(fromService: $0.endpoint) != nil }
                    ?? candidates.first
                guard let best else { return }
                if let named = ControllerLink.shortname(fromService: best.endpoint) {
                    self.shortname = named
                }
                self.connect(to: best.endpoint)
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
        // Giving up, so the loops cannot hold a dead exchange open: a
        // code left untyped past the television's own takedown (its
        // ninety seconds; this stops just short so the keepalive
        // cannot resurrect a fresh code the person is not looking at),
        // and a proof the television never answers, its game most
        // likely quit mid-pair.
        if case .codeEntry = phase, Date().timeIntervalSince(phaseChangedAt) > 85 {
            end("The code expired. Try again for a fresh one.")
            return
        }
        if case .verifying = phase, Date().timeIntervalSince(phaseChangedAt) > 10 {
            end("The television stopped answering.")
            return
        }
        if case .cooldown(let until) = phase, Date() >= until {
            requester = nil
            pendingProof = nil
            phase = .joining
            send(.init(kind: .join), payload: ControllerPairing.deviceID + phoneNonce)
            return
        }
        // A join the television never answers means the connection is
        // glued to a stale advertisement (game relaunches leave them
        // behind for a while). Hang up, remember the corpse so the
        // next browse skips it, and let the failure path re-search.
        // Only while no pairing is mid-flight; pairing has its own
        // clocks.
        if case .joining = phase, requester == nil,
           Date().timeIntervalSince(phaseChangedAt) > 10 {
            if let currentEndpoint {
                avoidEndpoint = (String(describing: currentEndpoint), Date().addingTimeInterval(60))
            }
            connection?.cancel()
            return
        }
        switch phase {
        case .joining:
            if let requester {
                send(.init(kind: .pairRequest), payload: requester.requestPayload)
            } else {
                send(.init(kind: .join), payload: ControllerPairing.deviceID + phoneNonce)
            }
        case .verifying:
            if let pendingProof {
                send(.init(kind: .pairProof), payload: pendingProof)
            }
        case .codeEntry:
            // Still here, typing. The request doubles as the keepalive
            // because a stranger has no session key to tag a heartbeat
            // with; the television answers with the same challenge and
            // both loops hold still.
            if let requester {
                send(.init(kind: .pairRequest), payload: requester.requestPayload)
            }
        case .connected:
            // Still held. Tagged like all session traffic, so absence
            // cannot be faked any more than input can.
            send(.init(kind: .hello))
        case .searching, .ended, .cooldown:
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
        sessionKey = nil
        videoOffer = nil
        vmuLCD = nil
        playerIndex = nil
    }

    /// The foreground edge. If the link died while the app was away,
    /// begin again from the browse; if it is healthy, do nothing.
    func wake() {
        guard !connected, !stopping else { return }
        connection?.cancel(); connection = nil
        browser?.cancel(); browser = nil
        requester = nil
        pendingProof = nil
        sessionKey = nil
        videoOffer = nil
        vmuLCD = nil
        playerIndex = nil
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
            send(.init(kind: .join), payload: ControllerPairing.deviceID + phoneNonce)
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
        phoneNonce = ControllerPairing.randomBytes(16)
        sessionKey = nil
        videoOffer = nil
        vmuLCD = nil
        playerIndex = nil
        badHelloCount = 0
        currentEndpoint = endpoint
        let c = NWConnection(to: endpoint, using: ControllerLink.parameters())
        connection = c
        c.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    guard let self else { return }
                    self.phase = .joining
                    self.status = "Found the TV"
                    self.startTicker()
                    // UDP has no handshake, so the television does not
                    // know we exist until we say something. This is
                    // that, and the ticker repeats it until answered.
                    self.send(.init(kind: .join), payload: ControllerPairing.deviceID + self.phoneNonce)
                    // The browse has done its job. Leaving it running is
                    // what kept AWDL awake and produced the stalls the
                    // aim lab spent an evening chasing.
                    self.browser?.cancel()
                    self.browser = nil
                case .failed, .cancelled:
                    guard let self else { return }
                    self.ticker?.cancel(); self.ticker = nil
                    self.connected = false
                    self.status = "Disconnected"
                    self.requester = nil
                    self.pendingProof = nil
                    self.sessionKey = nil
                    self.videoOffer = nil
                    self.vmuLCD = nil
                    self.playerIndex = nil
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

    /// Arms the next read and nothing else. Deliberately nonisolated: the
    /// only state work in the closure is `handle`, which hops to the main
    /// actor by itself, and making the re-arm wait for a main actor turn
    /// would put a scheduling hop in the middle of the controller's input
    /// path in exchange for nothing.
    private nonisolated func receive(on connection: NWConnection) {
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
            // The television's half of the handshake. Nothing in it is
            // believed until its proof checks out against the stored
            // secret and OUR nonce, so neither a stranger nor a
            // recording of last night can dress up as the television.
            guard sessionKey == nil else { return }
            guard payload.count >= 8 + 16 + ControllerPairing.tagLength + 1 else { return }
            let tvID = Data(payload.prefix(8))
            let tvNonce = Data(payload.dropFirst(8).prefix(16))
            let tag = Data(payload.dropFirst(24).prefix(ControllerPairing.tagLength))
            let port = Data(payload.dropFirst(24 + ControllerPairing.tagLength).prefix(1))
            let nameBytes = Data(payload.dropFirst(24 + ControllerPairing.tagLength + 1))
            guard let secret = ControllerPairing.secret(forPeer: tvID) else {
                // The television remembers this phone; this phone does
                // not remember the television, a reinstall usually.
                // Pair again, which overwrites cleanly on both sides.
                guard requester == nil else { return }
                status = "This TV needs pairing"
                let fresh = ControllerPairing.Requester(phoneID: ControllerPairing.deviceID)
                requester = fresh
                send(.init(kind: .pairRequest), payload: fresh.requestPayload)
                return
            }
            let helloKey = ControllerPairing.helloKey(secret: secret, phoneNonce: phoneNonce)
            guard ControllerPairing.validTag(
                tag, key: helloKey, context: "t2p-hello", bytes: tvID + tvNonce + port + nameBytes)
            else {
                // A television that keeps answering wrongly holds a
                // secret that no longer matches ours. Re-pair rather
                // than sit in silence; the fresh secret overwrites
                // cleanly on both sides.
                badHelloCount += 1
                if badHelloCount >= 3, requester == nil {
                    status = "Pairing again"
                    let fresh = ControllerPairing.Requester(phoneID: ControllerPairing.deviceID)
                    requester = fresh
                    send(.init(kind: .pairRequest), payload: fresh.requestPayload)
                }
                return
            }
            badHelloCount = 0
            if let name = ControllerLink.validShortname(String(decoding: nameBytes, as: UTF8.self)) {
                shortname = name
                status = name
            }
            let announced = Int(port[port.startIndex])
            playerIndex = announced == ControllerLink.unseatedPort ? nil : announced
            sessionKey = ControllerPairing.sessionKey(
                secret: secret, phoneNonce: phoneNonce, tvNonce: tvNonce)
            requester = nil
            pendingProof = nil
            phase = .connected
            connected = true
            // The first proven packet: this is what flips presence on
            // the television, so it goes now rather than at the next
            // heartbeat.
            send(.init(kind: .hello))

        case .seat:
            // The seat this phone just earned by playing. Believed
            // only under the session key's proof, the same standard
            // the hello set.
            guard let key = sessionKey,
                  payload.count >= ControllerPairing.tagLength + 1 else { return }
            let tag = Data(payload.prefix(ControllerPairing.tagLength))
            let body = Data(payload.dropFirst(ControllerPairing.tagLength))
            guard ControllerPairing.validTag(tag, key: key, context: "t2p-seat", bytes: body)
            else { return }
            let seat = Int(body[body.startIndex])
            playerIndex = seat == ControllerLink.unseatedPort ? nil : seat

        case .rumble:
            // The game knocked this player's motor. Believed only under
            // the session key's proof, like every other packet the
            // television sends, so nothing on the network can buzz a
            // phone that is not playing with it.
            guard let key = sessionKey,
                  payload.count >= ControllerPairing.tagLength + 3 else { return }
            let tag = Data(payload.prefix(ControllerPairing.tagLength))
            let body = Data(payload.dropFirst(ControllerPairing.tagLength))
            guard ControllerPairing.validTag(tag, key: key, context: "t2p-rumble", bytes: body)
            else { return }
            let bytes = [UInt8](body)
            let strong = bytes[0] != 0
            let strength = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
            DispatchQueue.main.async { self.onRumble?(strong, strength) }

        case .vmuLCD:
            // Believed only under the session key's proof, like every
            // television-to-phone kind.
            guard let key = sessionKey,
                  payload.count >= ControllerPairing.tagLength + 192 else { return }
            let tag = Data(payload.prefix(ControllerPairing.tagLength))
            let body = Data(payload.dropFirst(ControllerPairing.tagLength).prefix(192))
            guard ControllerPairing.validTag(tag, key: key, context: "t2p-vmulcd", bytes: body)
            else { return }
            vmuLCD = body

        case .videoOffer:
            // Believed only under the session key's own proof, the same
            // standard the hello set: an unproven offer could point the
            // panel at a stranger's socket.
            guard let key = sessionKey,
                  payload.count >= ControllerPairing.tagLength + 2 + 16 else { return }
            let tag = Data(payload.prefix(ControllerPairing.tagLength))
            let body = Data(payload.dropFirst(ControllerPairing.tagLength))
            guard ControllerPairing.validTag(tag, key: key, context: "t2p-video", bytes: body)
            else { return }
            let port = Int(body[body.startIndex]) << 8 | Int(body[body.index(after: body.startIndex)])
            if port == 0 {
                videoOffer = nil
            } else {
                videoOffer = VideoOffer(port: port, token: Data(body.dropFirst(2).prefix(16)))
            }

        case .pairNeeded:
            guard case .joining = phase, requester == nil else { return }
            status = "This TV needs pairing"
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
                send(.init(kind: .join), payload: ControllerPairing.deviceID + phoneNonce)
            } catch {
                end("This phone could not store the pairing.")
            }

        case .pairFail:
            switch ControllerLink.Packet.FailReason(rawValue: packet.a) {
            case .wrongCode:
                pendingProof = nil
                phase = .codeEntry(triesLeft: max(1, Int(packet.b)))
            case .cancelled, .cooldown:
                // One extra second absorbs the packet's flight time,
                // so the automatic retry lands after the television's
                // own clock has released, never just before.
                let seconds = TimeInterval(max(1, packet.b)) + 1
                requester = nil
                pendingProof = nil
                phase = .cooldown(until: Date().addingTimeInterval(seconds))
            case .busy:
                end("The television is pairing another phone. Try again in a moment.")
            case .expired:
                end("The code expired. Try again for a fresh one.")
            case .storage:
                end("The television could not store the pairing.")
            case .full:
                end("Both player seats are taken.")
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
        var out = p.encoded()
        // Session traffic proves itself; the rendezvous kinds carry
        // their own crypto and predate the session key by definition.
        if let sessionKey {
            out += ControllerPairing.tag(key: sessionKey, context: "p2t", bytes: out)
        }
        out += payload
        connection.send(content: out, completion: .idempotent)
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

    func sighting(step: SightingStep) {
        send(.init(kind: .sighting, a: Int16(step.rawValue)))
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
