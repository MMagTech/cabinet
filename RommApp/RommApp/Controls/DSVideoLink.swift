import Foundation
import Network
import VideoToolbox
import CoreMedia
import AVFoundation

/// The bottom screen's trip to the phone: a TCP stream of hardware
/// encoded H.264, television to phone, alongside the datagram wire that
/// carries input the other way. TCP on purpose: a lost packet here
/// should stall a frame, not corrupt one, and on the LAN the stall is
/// rare and short. The stream carries the game's own picture, which is
/// not a secret, so like the input wire it is authenticated but not
/// encrypted: the connect token (announced through the tagged
/// videoOffer packet) is what keeps a stranger's socket from dialing
/// in, and a wrong token is simply hung up on.
///
/// Framing, both directions length-prefixed: the phone opens with its
/// 16-byte token, then the television sends messages of
/// [4-byte big-endian length][1-byte type][body]. Type 0 is codec
/// config, an SPS and PPS each with a 2-byte length prefix; type 1 is
/// one video frame, a 1-byte keyframe flag followed by AVCC data
/// exactly as the encoder produced it. Config precedes the first frame
/// and rides again before every keyframe, so a phone that joins or
/// hiccups mid-stream recovers at the next keyframe on its own.
enum DSVideoWire {
    static let configType: UInt8 = 0
    static let frameType: UInt8 = 1
    /// The bottom screen's own size; the one thing both ends agree on
    /// before a byte moves.
    static let width = 256
    static let height = 192
}

// MARK: - Television side

// The server half is the machine hosting the game: the Apple TV, and
// now the Mac, which hands a joined phone the DS bottom screen exactly
// the same way. The client half below stays iOS: the phone is the only
// thing that ever receives it.
#if os(tvOS) || targetEnvironment(macCatalyst)
/// Encodes bottom-screen frames and serves them to the one phone that
/// presents the right token. Lives exactly as long as the DS game and
/// the phone connection that wants it; TVPlayerView owns that.
final class DSVideoServer {
    private let queue = DispatchQueue(label: "cabinet.dsvideo.serve", qos: .userInteractive)
    private var listener: NWListener?
    private var client: NWConnection?
    private var clientAuthed = false
    private var session: VTCompressionSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameIndex: Int64 = 0
    /// Sent before the first frame and refreshed at every keyframe.
    private var configMessage: Data?

    let token: Data
    private(set) var port: UInt16 = 0

    init?() {
        token = ControllerPairing.randomBytes(16)
        guard let l = try? NWListener(using: .tcp) else { return nil }
        listener = l
        l.newConnectionHandler = { [weak self] connection in
            self?.queue.async { self?.accept(connection) }
        }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.port = l.port?.rawValue ?? 0
                ready.signal()
            }
            if case .failed = state { ready.signal() }
        }
        l.start(queue: queue)
        // The port must be known before the offer can name it. The
        // listener readies in microseconds; a second means it never
        // will.
        _ = ready.wait(timeout: .now() + 1)
        guard port != 0 else { stop(); return nil }
        buildEncoder()
        guard session != nil else { stop(); return nil }
    }

    /// One phone at a time: a new valid caller replaces the old, which
    /// mirrors how the game itself treats the stylus seat.
    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveToken(on: connection)
    }

    private func receiveToken(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == 16,
                  constantTimeEqual(data, self.token) else {
                connection.cancel()
                return
            }
            self.client?.cancel()
            self.client = connection
            self.clientAuthed = true
            // A joiner starts from config and the next keyframe.
            if let config = self.configMessage {
                self.send(config, on: connection)
            }
            self.forceKeyframe = true
        }
    }

    private var forceKeyframe = false

    private func buildEncoder() {
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(DSVideoWire.width), height: Int32(DSVideoWire.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let s else { return }
        // Realtime, no frame reordering: a B-frame is borrowed latency,
        // and the whole point of this stream is a finger trusting what
        // it sees.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 120 as CFNumber)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        // 256x192 pixel art wants very little; two megabits is generous
        // and keeps a Wi-Fi stumble short.
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_000_000 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s

        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: DSVideoWire.width,
            kCVPixelBufferHeightKey: DSVideoWire.height,
        ]
        CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pixelBufferPool)
    }

    /// One bottom-screen frame, BGRA rows as the core rendered them.
    /// Called from the render loop; the copy happens here and the
    /// encode on this server's own queue, so the game never waits.
    func submit(bottomHalf pixels: Data, bytesPerRow: Int) {
        queue.async { [weak self] in
            guard let self, self.clientAuthed, let session = self.session,
                  let pool = self.pixelBufferPool else { return }
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == noErr, let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                let rowBytes = DSVideoWire.width * 4
                pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    guard let srcBase = src.baseAddress else { return }
                    for row in 0..<DSVideoWire.height {
                        memcpy(base + row * dstStride, srcBase + row * bytesPerRow, rowBytes)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])

            let pts = CMTime(value: self.frameIndex, timescale: 60)
            self.frameIndex += 1
            var props: CFDictionary?
            if self.forceKeyframe {
                self.forceKeyframe = false
                props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            }
            VTCompressionSessionEncodeFrame(
                session, imageBuffer: pb, presentationTimeStamp: pts,
                duration: CMTime(value: 1, timescale: 60),
                frameProperties: props, infoFlagsOut: nil
            ) { [weak self] status, _, sampleBuffer in
                guard let self, status == noErr, let sampleBuffer else { return }
                self.queue.async { self.ship(sampleBuffer) }
            }
        }
    }

    private func ship(_ sample: CMSampleBuffer) {
        guard let client, clientAuthed else { return }
        let keyframe = !sampleIsDependent(sample)
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample),
           let config = configData(from: format) {
            configMessage = config
            send(config, on: client)
        }
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
            let pointer else { return }
        var body = Data(capacity: length + 1)
        body.append(keyframe ? 1 : 0)
        body.append(UnsafeBufferPointer(start: UnsafeRawPointer(pointer)
            .assumingMemoryBound(to: UInt8.self), count: length))
        send(message(type: DSVideoWire.frameType, body: body), on: client)
    }

    private func sampleIsDependent(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first else { return false }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
    }

    private func configData(from format: CMFormatDescription) -> Data? {
        var spsPointer: UnsafePointer<UInt8>?
        var spsLength = 0
        var ppsPointer: UnsafePointer<UInt8>?
        var ppsLength = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: &spsPointer,
            parameterSetSizeOut: &spsLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 1, parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsLength, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
            let spsPointer, let ppsPointer else { return nil }
        var body = Data()
        body.append(UInt8(spsLength >> 8)); body.append(UInt8(spsLength & 0xff))
        body.append(UnsafeBufferPointer(start: spsPointer, count: spsLength))
        body.append(UInt8(ppsLength >> 8)); body.append(UInt8(ppsLength & 0xff))
        body.append(UnsafeBufferPointer(start: ppsPointer, count: ppsLength))
        return message(type: DSVideoWire.configType, body: body)
    }

    private func message(type: UInt8, body: Data) -> Data {
        var out = Data(capacity: 5 + body.count)
        let length = UInt32(body.count + 1)
        out.append(UInt8(length >> 24)); out.append(UInt8((length >> 16) & 0xff))
        out.append(UInt8((length >> 8) & 0xff)); out.append(UInt8(length & 0xff))
        out.append(type)
        out.append(body)
        return out
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .idempotent)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            if let session = self.session {
                VTCompressionSessionInvalidate(session)
                self.session = nil
            }
            self.client?.cancel(); self.client = nil
            self.clientAuthed = false
            self.listener?.cancel(); self.listener = nil
        }
    }
}
#endif

// MARK: - Phone side

#if os(iOS)
/// Dials the offered port, presents the token, and turns the stream
/// back into pictures. The display layer does the decoding itself:
/// H.264 sample buffers go straight in, hardware does the rest.
/// Not an actor on purpose: every mutable field below is confined to
/// `queue`, where the network callbacks already live; only the
/// published flag hops to the main thread, and the display layer
/// accepts sample buffers from any thread by contract.
final class DSVideoClient: ObservableObject {
    /// True from the first displayed frame, which is what swaps the
    /// panel's quiet plate for the live bottom screen.
    @Published private(set) var receiving = false

    let displayLayer = AVSampleBufferDisplayLayer()
    private let queue = DispatchQueue(label: "cabinet.dsvideo.dial", qos: .userInteractive)
    private var connection: NWConnection?
    private var buffer = Data()
    private var format: CMVideoFormatDescription?
    private var seenFirstFrame = false

    func connect(host: NWEndpoint.Host, port: Int, token: Data) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        displayLayer.videoGravity = .resizeAspect
        queue.async { [weak self] in
            guard let self else { return }
            self.teardown()
            let c = NWConnection(host: host, port: nwPort, using: .tcp)
            self.connection = c
            c.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    c.send(content: token, completion: .idempotent)
                    self.receive(on: c)
                case .failed, .cancelled:
                    self.queue.async { self.streamEnded() }
                default:
                    break
                }
            }
            c.start(queue: self.queue)
        }
    }

    func disconnect() {
        queue.async { [weak self] in self?.teardown() }
    }

    /// Queue-confined.
    private func teardown() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        format = nil
        seenFirstFrame = false
        DispatchQueue.main.async { [weak self] in
            self?.receiving = false
            self?.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    /// Queue-confined.
    private func streamEnded() {
        guard connection != nil else { return }
        teardown()
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.drainMessages()
            if error == nil && !done {
                self.receive(on: connection)
            } else {
                self.streamEnded()
            }
        }
    }

    private func drainMessages() {
        while buffer.count >= 5 {
            let length = Int(buffer[buffer.startIndex]) << 24
                | Int(buffer[buffer.index(buffer.startIndex, offsetBy: 1)]) << 16
                | Int(buffer[buffer.index(buffer.startIndex, offsetBy: 2)]) << 8
                | Int(buffer[buffer.index(buffer.startIndex, offsetBy: 3)])
            guard length >= 1, length <= 4_000_000 else {
                streamEnded()
                return
            }
            guard buffer.count >= 4 + length else { return }
            let type = buffer[buffer.index(buffer.startIndex, offsetBy: 4)]
            let body = Data(buffer.dropFirst(5).prefix(length - 1))
            buffer.removeFirst(4 + length)
            switch type {
            case DSVideoWire.configType: applyConfig(body)
            case DSVideoWire.frameType: enqueueFrame(body)
            default: break
            }
        }
    }

    private func applyConfig(_ body: Data) {
        guard body.count >= 4 else { return }
        let spsLength = Int(body[body.startIndex]) << 8 | Int(body[body.index(after: body.startIndex)])
        guard body.count >= 2 + spsLength + 2 else { return }
        let sps = Data(body.dropFirst(2).prefix(spsLength))
        let afterSPS = body.dropFirst(2 + spsLength)
        let ppsLength = Int(afterSPS[afterSPS.startIndex]) << 8
            | Int(afterSPS[afterSPS.index(after: afterSPS.startIndex)])
        guard afterSPS.count >= 2 + ppsLength else { return }
        let pps = Data(afterSPS.dropFirst(2).prefix(ppsLength))

        sps.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
            pps.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                guard let sBase = s.baseAddress, let pBase = p.baseAddress else { return }
                let pointers = [
                    sBase.assumingMemoryBound(to: UInt8.self),
                    pBase.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes = [sps.count, pps.count]
                var fmt: CMVideoFormatDescription?
                if CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt) == noErr {
                    self.format = fmt
                }
            }
        }
    }

    private func enqueueFrame(_ body: Data) {
        guard body.count > 1, let format else { return }
        let avcc = Data(body.dropFirst())
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == noErr,
            let block else { return }
        _ = avcc.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            CMBlockBufferReplaceDataBytes(
                with: src.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sample: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample) == noErr, let sample else { return }
        // Show it the moment it decodes: the stream's clock is the
        // game, not a timeline.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [CFMutableDictionary], let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        displayLayer.sampleBufferRenderer.enqueue(sample)
        if !seenFirstFrame {
            seenFirstFrame = true
            DispatchQueue.main.async { [weak self] in self?.receiving = true }
        }
    }
}
#endif

/// Timing-safe comparison for the connect token; a byte-early exit
/// would leak which prefix guessed right.
func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count {
        diff |= a[a.index(a.startIndex, offsetBy: i)] ^ b[b.index(b.startIndex, offsetBy: i)]
    }
    return diff == 0
}
