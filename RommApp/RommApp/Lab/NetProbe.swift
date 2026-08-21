import Foundation
import Network

/// The phone-as-controller transport probe, the gating test for the idea in
/// docs/ideas/cabinet-phone-as-controller-idea.md. Before any control
/// profile, core device type, or pairing design is worth building, one
/// question decides everything: can an iPhone deliver input to the Apple TV
/// with a latency tail that feels like a wired control, sustained for a
/// whole session, under realistic load? This measures exactly that and
/// nothing else.
///
/// DEBUG only, launch-argument gated, no session, no server, no pairing.
/// The phone streams sequence-numbered, timestamped packets at 100Hz over
/// one of three transports while doing what a controller screen would
/// really be doing (display animating at 60fps, CoreMotion sampling at
/// 100Hz, idle timer off). The TV listens on all three at once and logs
/// every arrival. The verdict lives in the percentiles of the arrival gaps,
/// computed offline by tools/lab/bench/summarize_netprobe.py, never in how
/// ten seconds felt.
///
/// Transports:
///   udp   plain UDP over whatever network both boxes are on
///   p2p   the same UDP with includePeerToPeer, Apple's AWDL direct link
///   ble   a custom GATT link, phone advertising as peripheral
///
/// Launch:
///   TV:    -cabinetNetProbe receiver
///   phone: -cabinetNetProbe udp|p2p|ble  [-cabinetNetProbeMinutes 30]
///
/// Traces land in Caches and are pulled with the usual devicectl copy
/// (bundle com.mmagtech.CabinetDev, .tv suffixed on the TV):
///   TV:    net-probe-<transport>.csv       seq, arrival time, gap
///   phone: net-probe-<transport>-send.csv  seq, send time, timer lag
///          net-probe-<transport>-rtt.csv   seq, round trip
///
/// A run is finished when the trace ends with a "# done" line, which is
/// what a scripted pull should check before believing the file, the same
/// stale-pull trap the bench harness already documented.
enum NetProbe {
    enum Transport: UInt8, CaseIterable {
        case udp = 0, p2p = 1, ble = 2

        var label: String {
            switch self {
            case .udp: return "udp"
            case .p2p: return "p2p"
            case .ble: return "ble"
            }
        }

        static func parse(_ raw: String) -> Transport? {
            allCases.first { $0.label == raw }
        }
    }

    enum Role {
        case sender(Transport)
        case receiver
    }

    static let bonjourType = "_cabinet-probe._udp"
    static let sendHz = 100.0
    /// Every Nth data packet is echoed back for a round trip sample. All
    /// of them would double the BLE channel's load and distort the thing
    /// being measured.
    static let echoEvery: UInt32 = 10

    /// Parsed once from the launch arguments. Nil means the probe is not
    /// requested and the app boots normally; this is the only line the
    /// ordinary launch path ever evaluates.
    static let launchRole: Role? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-cabinetNetProbe"), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        if value == "receiver" { return .receiver }
        if let transport = Transport.parse(value) { return .sender(transport) }
        return nil
    }()

    /// Receiver side peer-to-peer, off unless explicitly asked for with
    /// `-cabinetNetProbe receiver p2p`. See the note in startUDP.
    static let receiverAllowsPeerToPeer: Bool =
        ProcessInfo.processInfo.arguments.contains("p2p")

    static let minutes: Double = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-cabinetNetProbeMinutes"), i + 1 < args.count,
              let value = Double(args[i + 1]), value > 0 else { return 30 }
        return value
    }()

    /// Monotonic milliseconds. Wall clock time can step; this cannot, and
    /// every number in the traces derives from it.
    static func nowMS() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }
}

/// One probe packet, 16 bytes, fixed little endian layout:
/// magic u8, kind u8 (0 data, 1 echo), transport u8, pad u8,
/// seq u32, sendTimeNS u64.
struct ProbePacket {
    static let size = 16
    static let magic: UInt8 = 0xCB

    var kind: UInt8
    var transport: NetProbe.Transport
    var seq: UInt32
    var sendTimeNS: UInt64

    func encoded() -> Data {
        var data = Data(capacity: Self.size)
        data.append(Self.magic)
        data.append(kind)
        data.append(transport.rawValue)
        data.append(0)
        withUnsafeBytes(of: seq.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: sendTimeNS.littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    init(kind: UInt8, transport: NetProbe.Transport, seq: UInt32, sendTimeNS: UInt64) {
        self.kind = kind
        self.transport = transport
        self.seq = seq
        self.sendTimeNS = sendTimeNS
    }

    init?(_ data: Data) {
        guard data.count >= Self.size, data[data.startIndex] == Self.magic,
              let transport = NetProbe.Transport(rawValue: data[data.startIndex + 2])
        else { return nil }
        kind = data[data.startIndex + 1]
        self.transport = transport
        seq = data.subdata(in: data.startIndex + 4..<data.startIndex + 8)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        sendTimeNS = data.subdata(in: data.startIndex + 8..<data.startIndex + 16)
            .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
}

/// CSV trace writer, the FrameTrace pattern: rows batch in memory and a
/// background queue owns the file handle, so nothing on the send or
/// receive path touches the filesystem.
final class ProbeTrace {
    private let queue = DispatchQueue(label: "cabinet.netprobe.trace", qos: .utility)
    private var pending: [String] = []
    private var handle: FileHandle?
    let url: URL

    init(name: String, header: String, meta: String) {
        url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name)
        let fileURL = url
        queue.async {
            try? FileManager.default.removeItem(at: fileURL)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: fileURL)
            self.handle?.write(Data(("# \(meta)\n" + header + "\n").utf8))
        }
    }

    func row(_ text: String) {
        queue.async {
            self.pending.append(text)
            if self.pending.count >= 200 {
                self.flushLocked()
            }
        }
    }

    private func flushLocked() {
        guard !pending.isEmpty else { return }
        handle?.write(Data((pending.joined(separator: "\n") + "\n").utf8))
        pending.removeAll(keepingCapacity: true)
    }

    /// Writes the trailer a scripted pull checks for. A trace without it
    /// is a run that died or is still going, not a result.
    func finish() {
        queue.async {
            self.flushLocked()
            self.handle?.write(Data("# done\n".utf8))
            try? self.handle?.close()
            self.handle = nil
        }
    }
}

/// Rolling counters both engines publish for the on-screen readout. The
/// screen exists so a human can see the run is alive and roughly healthy;
/// judgement happens offline on the full trace.
struct ProbeCounters {
    var packets: UInt64 = 0
    var maxGapMS: Double = 0
    var gapsOver25 = 0
    var gapsOver100 = 0
    var lastRTTMS: Double = 0
    var sendDrops = 0

    mutating func recordGap(_ gap: Double) {
        maxGapMS = max(maxGapMS, gap)
        if gap > 25 { gapsOver25 += 1 }
        if gap > 100 { gapsOver100 += 1 }
    }
}

// MARK: - Sender, the phone side

final class ProbeSenderEngine: ObservableObject {
    @Published var status = "starting"
    @Published var counters = ProbeCounters()
    @Published var done = false

    let transport: NetProbe.Transport
    private let timerQueue = DispatchQueue(label: "cabinet.netprobe.send", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var seq: UInt32 = 0
    private var startMS: Double = 0
    private var scheduledMS: Double = 0
    private var sendTrace: ProbeTrace?
    private var rttTrace: ProbeTrace?
    private var connection: NWConnection?
    private var browser: NWBrowser?
    #if os(iOS)
    private var ble: BLEPeripheralSender?
    #endif

    init(transport: NetProbe.Transport) {
        self.transport = transport
    }

    func start() {
        let label = transport.label
        let meta = "netprobe sender transport=\(label) hz=\(Int(NetProbe.sendHz)) started=\(Date())"
        sendTrace = ProbeTrace(
            name: "net-probe-\(label)-send.csv",
            header: "seq,t_send_ms,timer_lag_ms", meta: meta)
        rttTrace = ProbeTrace(
            name: "net-probe-\(label)-rtt.csv",
            header: "seq,rtt_ms", meta: meta)

        if transport == .ble {
            #if os(iOS)
            let sender = BLEPeripheralSender(
                onState: { [weak self] text in self?.setStatus(text) },
                onEcho: { [weak self] data in self?.handleEcho(data) })
            ble = sender
            sender.start()
            #else
            setStatus("ble sender is iOS only")
            return
            #endif
        } else {
            startBonjour()
        }
        startTimer()
        scheduleFinish()
    }

    private func startBonjour() {
        let params = udpParameters()
        let browser = NWBrowser(
            for: .bonjour(type: NetProbe.bonjourType, domain: nil), using: params)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let first = results.first else { return }
            self.connect(to: first.endpoint)
            // Cancelled the moment a peer is found. A browse left running
            // holds AWDL open for the whole session, and AWDL hops the
            // radio off-channel for 50-100ms about once a second, which
            // is exactly the stall-then-burst the first runs recorded.
            self.browser?.cancel()
            self.browser = nil
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.setStatus("browse failed: \(error)") }
        }
        setStatus("browsing for receiver")
        browser.start(queue: timerQueue)
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: udpParameters())
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.setStatus("connected \(self?.transport.label ?? "")")
            case .failed(let error): self?.setStatus("connection failed: \(error)")
            default: break
            }
        }
        receiveEchoes(on: connection)
        connection.start(queue: timerQueue)
    }

    private func receiveEchoes(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data { self.handleEcho(data) }
            if error == nil { self.receiveEchoes(on: connection) }
        }
    }

    private func udpParameters() -> NWParameters {
        let params = NWParameters.udp
        params.includePeerToPeer = (transport == .p2p)
        // The first pass sent these as ordinary best-effort traffic and
        // measured a 97ms p99 with stalls four times a second on both the
        // routed and the direct path, identical on each, which pointed at
        // the phone's own radio rather than the network. Voice class is
        // the reason a FaceTime call over the same radio in the same room
        // does not do that: it rides a priority queue and holds the radio
        // out of its power-saving nap. A controller stream is the same
        // shape of traffic as a voice stream, small packets at a fixed
        // rate where lateness is worse than loss, so this is what the
        // real feature would ask for too, not a benchmark trick.
        params.serviceClass = .interactiveVoice
        return params
    }

    private func startTimer() {
        let interval = 1.0 / NetProbe.sendHz
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        self.timer = timer
        startMS = NetProbe.nowMS()
        scheduledMS = startMS
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    private func tick() {
        let now = NetProbe.nowMS()
        scheduledMS += 1000.0 / NetProbe.sendHz
        // How late the timer itself fired. Radio jitter in the receiver's
        // trace can only be judged against how steady the sender really
        // was, so the sender's own lag is recorded per packet.
        let lag = now - scheduledMS
        seq &+= 1
        let packet = ProbePacket(
            kind: 0, transport: transport, seq: seq,
            sendTimeNS: DispatchTime.now().uptimeNanoseconds)
        let data = packet.encoded()

        var dropped = false
        if transport == .ble {
            #if os(iOS)
            dropped = !(ble?.send(data) ?? false)
            #endif
        } else if let connection, connection.state == .ready {
            connection.send(content: data, completion: .idempotent)
        } else {
            dropped = true
        }

        sendTrace?.row(String(format: "%u,%.3f,%.3f", seq, now - startMS, lag))
        DispatchQueue.main.async {
            self.counters.packets += 1
            if dropped { self.counters.sendDrops += 1 }
        }
    }

    private func handleEcho(_ data: Data) {
        guard let packet = ProbePacket(data), packet.kind == 1 else { return }
        let rtt = Double(DispatchTime.now().uptimeNanoseconds &- packet.sendTimeNS) / 1_000_000
        rttTrace?.row(String(format: "%u,%.3f", packet.seq, rtt))
        DispatchQueue.main.async { self.counters.lastRTTMS = rtt }
    }

    private func scheduleFinish() {
        timerQueue.asyncAfter(deadline: .now() + NetProbe.minutes * 60) { [weak self] in
            self?.finish()
        }
    }

    func finish() {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        browser?.cancel()
        #if os(iOS)
        ble?.stop()
        #endif
        sendTrace?.finish()
        rttTrace?.finish()
        NSLog("[netprobe] sender done, %u packets over %.1f min", seq, NetProbe.minutes)
        DispatchQueue.main.async {
            self.done = true
            self.status = "done, \(self.seq) packets"
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}

// MARK: - Receiver, the TV side

/// Listens on every transport at once, so one receiver launch serves a
/// whole session of phone-side runs. Each transport keeps its own trace
/// and its own gap state; the packet itself says which transport carried
/// it, so a LAN run and a peer-to-peer run cannot contaminate each other's
/// file even though one UDP listener serves both.
final class ProbeReceiverEngine: ObservableObject {
    @Published var status: [String] = []
    @Published var counters: [NetProbe.Transport: ProbeCounters] = [:]

    private let queue = DispatchQueue(label: "cabinet.netprobe.recv", qos: .userInteractive)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var traces: [NetProbe.Transport: ProbeTrace] = [:]
    private var firstMS: [NetProbe.Transport: Double] = [:]
    private var prevMS: [NetProbe.Transport: Double] = [:]
    private var ble: BLECentralReceiver?

    func start() {
        startUDP()
        ble = BLECentralReceiver(
            onState: { [weak self] text in self?.pushStatus("ble: \(text)") },
            onPacket: { [weak self] data, reply in self?.handle(data, reply: reply) })
        ble?.start()
        pushStatus("listening")
    }

    private func startUDP() {
        // One listener with peer to peer enabled serves both the LAN and
        // the AWDL path; the phone side's own parameters decide which
        // route a given run takes.
        let params = NWParameters.udp
        // NOT unconditionally true, which is what invalidated the first
        // night of runs: with peer to peer on, AWDL was active during the
        // plain-LAN test too, so both transports measured the same
        // AWDL-disrupted path and their identical numbers read as
        // confirmation rather than as the tell they were.
        params.includePeerToPeer = NetProbe.receiverAllowsPeerToPeer
        // Matches the sender's class, so the echoes this side sends back
        // for the round trip samples are marked the same way the real
        // data is. See the sender's own note for why voice class.
        params.serviceClass = .interactiveVoice
        guard let listener = try? NWListener(using: params) else {
            pushStatus("udp listener failed to open")
            return
        }
        self.listener = listener
        listener.service = NWListener.Service(name: "CabinetProbe", type: NetProbe.bonjourType)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            self.receive(on: connection)
            connection.start(queue: self.queue)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.pushStatus("udp failed: \(error)") }
        }
        listener.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                self.handle(data) { reply in
                    connection.send(content: reply, completion: .idempotent)
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func handle(_ data: Data, reply: @escaping (Data) -> Void) {
        guard var packet = ProbePacket(data), packet.kind == 0 else { return }
        let now = NetProbe.nowMS()
        let transport = packet.transport

        let trace: ProbeTrace
        if let existing = traces[transport] {
            trace = existing
        } else {
            trace = ProbeTrace(
                name: "net-probe-\(transport.label).csv",
                header: "seq,t_arrive_ms,gap_ms",
                meta: "netprobe receiver transport=\(transport.label) hz=\(Int(NetProbe.sendHz)) started=\(Date())")
            traces[transport] = trace
            firstMS[transport] = now
            pushStatus("\(transport.label): first packet")
        }

        let gap = prevMS[transport].map { now - $0 } ?? 0
        prevMS[transport] = now
        trace.row(String(format: "%u,%.3f,%.3f", packet.seq, now - (firstMS[transport] ?? now), gap))

        if packet.seq % NetProbe.echoEvery == 0 {
            packet.kind = 1
            reply(packet.encoded())
        }

        let seq = packet.seq
        DispatchQueue.main.async {
            var c = self.counters[transport] ?? ProbeCounters()
            c.packets += 1
            if seq > 1 { c.recordGap(gap) }
            self.counters[transport] = c
        }
    }

    /// Flushes every open trace with its done trailer. The receiver has no
    /// natural end, so this is driven from the screen when a session of
    /// runs is over, and starting fresh means relaunching.
    func finish() {
        for trace in traces.values { trace.finish() }
        pushStatus("traces closed")
    }

    private func pushStatus(_ text: String) {
        DispatchQueue.main.async {
            self.status.append(text)
            if self.status.count > 8 { self.status.removeFirst() }
        }
    }
}
