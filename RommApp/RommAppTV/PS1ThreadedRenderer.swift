#if os(tvOS)
import SwiftUI
import MetalKit

/// Mirrors the shared renderer's private Vertex struct: duplicated rather
/// than reused since that one is private to NativePlayerRenderer.swift,
/// and this whole file is a throwaway prototype anyway. A real struct, not
/// a tuple, on purpose: Swift tuples have no guaranteed C-compatible
/// memory layout, and this needs to match exactly what the shared vertex
/// shader expects.
private struct ThreadedVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

/// Experimental prototype, tvOS-only on purpose: runs the core on its own
/// dedicated thread, decoupled from the display's draw callback, the same
/// separation RetroArch's own "Threaded Video" option describes. The
/// existing shared NativePlayerRenderer (used by iOS today) runs
/// everything, core tick, audio drain, texture upload, GPU encode, inside
/// one MTKView draw(in:) call on the main thread: if the core's own
/// computation for a busy scene occasionally exceeds one frame's budget,
/// the whole callback stalls, and audio and video both hitch at the same
/// moment. That matches a real report of choppy audio and laggy video
/// together on tvOS hardware playing Crash Bandicoot 2.
///
/// Deliberately not touching the shared file for this: this logic is
/// unproven and threading bugs are exactly the kind of thing that can
/// look fine in testing and surface later, and iOS's real player already
/// works today. Prove this actually fixes the problem here first; only
/// then does folding it into the shared renderer become its own separate,
/// deliberately-tested decision.
final class PS1ThreadedRenderer: NSObject, ObservableObject, MTKViewDelegate {
    private let frontend = LibretroFrontend.shared
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    /// Direct BGRA8888 upload, unchanged from before, used for XRGB8888
    /// frames which never needed CPU conversion in the first place.
    private var directPipeline: MTLRenderPipelineState!
    /// RGB565 frames upload as a raw r16Uint texture with zero CPU-side
    /// unpacking; this pipeline's fragment shader does the unpacking on
    /// the GPU instead, see PS1ThreadedShaders.metal.
    private var rgb565Pipeline: MTLRenderPipelineState!
    private var samplerState: MTLSamplerState!
    private let audio = NativePlayerAudio()

    private var texture: MTLTexture?
    private var texturePixelFormat: LibretroPixelFormat?
    private var textureWidth = 0
    private var textureHeight = 0
    /// Only used for the RGB1555 fallback, the one format left on the old
    /// CPU-conversion path since it's not actually exercised by anything
    /// tested so far and wasn't worth the same GPU-unpack treatment yet.
    private var conversionBuffer: [UInt8] = []
    private let textureLock = NSLock()

    private let buttonLock = NSLock()
    private var heldButtons: Set<Int> = []

    private var coreThread: Thread?
    private var running = false

    // Same diagnostic shape as NativePlayerRenderer's, duplicated rather
    // than shared since this whole class is a throwaway experiment: two
    // separate counters, one for how often the render side actually
    // presents, one for the core thread's own tick rate, since with real
    // threading these can now legitimately differ.
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var worstFrameMS: Double = 0
    @Published private(set) var coreHz: Double = 0
    private var fpsFrameCount = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var worstFrameDelta: CFTimeInterval = 0
    private var lastDrawTime: CFTimeInterval = 0
    private var coreTickCount = 0
    private var coreWindowStart: CFTimeInterval = 0

    func setButton(_ id: Int, down: Bool) {
        guard (0...13).contains(id) || (20...23).contains(id) else { return }
        buttonLock.lock()
        if down { heldButtons.insert(id) } else { heldButtons.remove(id) }
        buttonLock.unlock()
    }

    func attach(to view: MTKView) {
        guard let device = view.device else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()

        let library = try? device.makeDefaultLibrary(bundle: .main)

        let directDescriptor = MTLRenderPipelineDescriptor()
        directDescriptor.vertexFunction = library?.makeFunction(name: "libretro_vertex")
        directDescriptor.fragmentFunction = library?.makeFunction(name: NativeShader.sharp.fragmentFunctionName)
        directDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        directPipeline = try? device.makeRenderPipelineState(descriptor: directDescriptor)

        let rgb565Descriptor = MTLRenderPipelineDescriptor()
        rgb565Descriptor.vertexFunction = library?.makeFunction(name: "ps1_threaded_vertex")
        rgb565Descriptor.fragmentFunction = library?.makeFunction(name: "ps1_threaded_rgb565_unpack")
        rgb565Descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        rgb565Pipeline = try? device.makeRenderPipelineState(descriptor: rgb565Descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerState = device.makeSamplerState(descriptor: samplerDescriptor)

        audio.start()
        startCoreThread()
    }

    private func startCoreThread() {
        guard !running else { return }
        running = true
        let thread = Thread { [weak self] in self?.coreLoop() }
        thread.name = "ps1-core"
        thread.qualityOfService = .userInteractive
        coreThread = thread
        thread.start()
    }

    /// Ticks the core at its own pace, independent of the display's draw
    /// callback. A plain sleep-paced loop, not a display link: the point is
    /// specifically to NOT be tied to the render side's timing.
    private func coreLoop() {
        var nextTick = CACurrentMediaTime()
        while running {
            buttonLock.lock()
            let mask = heldButtons.reduce(into: UInt32(0)) { $0 |= (1 << $1) }
            buttonLock.unlock()

            frontend.setButtonMask(mask)
            frontend.runFrame()

            if let audioData = frontend.drainAudio() {
                audio.enqueue(audioData)
            }
            if let frame = frontend.latestFrame() {
                updateTexture(from: frame)
            }

            let now = CACurrentMediaTime()
            coreTickCount += 1
            if coreWindowStart == 0 { coreWindowStart = now }
            if now - coreWindowStart >= 1.0 {
                let hz = Double(coreTickCount) / (now - coreWindowStart)
                DispatchQueue.main.async { [weak self] in self?.coreHz = hz }
                coreTickCount = 0
                coreWindowStart = now
            }

            nextTick += 1.0 / 60.0
            let sleepFor = nextTick - CACurrentMediaTime()
            if sleepFor > 0 {
                Thread.sleep(forTimeInterval: sleepFor)
            } else {
                // Behind schedule: don't try to catch up by bursting frames,
                // just resync to now so one slow tick doesn't cascade into a
                // string of zero-sleep ticks running flat out.
                nextTick = CACurrentMediaTime()
            }
        }
    }

    private func updateTexture(from frame: LibretroFrame) {
        let width = Int(frame.width)
        let height = Int(frame.height)
        guard let device else { return }

        textureLock.lock()
        defer { textureLock.unlock() }

        let needsNewTexture = texture == nil || textureWidth != width || textureHeight != height
            || texturePixelFormat != frame.pixelFormat
        if needsNewTexture {
            let metalFormat: MTLPixelFormat = frame.pixelFormat == .RGB565 ? .r16Uint : .bgra8Unorm
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: metalFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
            textureWidth = width
            textureHeight = height
            texturePixelFormat = frame.pixelFormat
        }

        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            switch frame.pixelFormat {
            case .XRGB8888:
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: Int(frame.bytesPerRow)
                )
            case .RGB565:
                // No CPU unpacking at all: the raw 16-bit values go straight
                // to the GPU, and ps1_threaded_rgb565_unpack does the real
                // work in the fragment shader, per-pixel, in parallel,
                // instead of a scalar Swift loop on one CPU core. This is
                // the actual fix being tested, not the threading alone.
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: Int(frame.bytesPerRow)
                )
            case .RGB1555:
                // Not exercised by anything tested so far, left on the old
                // CPU-conversion path rather than guessing at a GPU version
                // of a format nothing has actually hit yet.
                let bytesPerRow = width * 4
                if conversionBuffer.count != bytesPerRow * height {
                    conversionBuffer = [UInt8](repeating: 0, count: bytesPerRow * height)
                }
                let srcStride = Int(frame.bytesPerRow)
                conversionBuffer.withUnsafeMutableBytes { dst in
                    for y in 0..<height {
                        let srcRow = base.advanced(by: y * srcStride).assumingMemoryBound(to: UInt16.self)
                        let dstRow = dst.baseAddress!.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<width {
                            let p = srcRow[x]
                            let r = UInt8((p >> 10) & 0x1F) << 3
                            let g = UInt8((p >> 5) & 0x1F) << 3
                            let b = UInt8(p & 0x1F) << 3
                            dstRow[x * 4] = b
                            dstRow[x * 4 + 1] = g
                            dstRow[x * 4 + 2] = r
                            dstRow[x * 4 + 3] = 255
                        }
                    }
                }
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: conversionBuffer, bytesPerRow: bytesPerRow
                )
            @unknown default:
                break
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Purely presentational: no core work happens here at all, just
    /// upload-free reuse of whatever texture the core thread most recently
    /// finished writing, and present it. If the core thread stalls, this
    /// simply keeps presenting the last good frame rather than stalling
    /// itself, audio and video no longer share a single point of failure.
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        if fpsWindowStart == 0 { fpsWindowStart = now }
        fpsFrameCount += 1
        if lastDrawTime != 0 {
            worstFrameDelta = max(worstFrameDelta, now - lastDrawTime)
        }
        lastDrawTime = now
        if now - fpsWindowStart >= 1.0 {
            measuredFPS = Double(fpsFrameCount) / (now - fpsWindowStart)
            worstFrameMS = worstFrameDelta * 1000
            fpsFrameCount = 0
            fpsWindowStart = now
            worstFrameDelta = 0
        }

        textureLock.lock()
        let currentTexture = texture
        let width = textureWidth
        let height = textureHeight
        let format = texturePixelFormat
        textureLock.unlock()

        guard let currentTexture,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let pipeline = (format == .RGB565 ? rgb565Pipeline : directPipeline)
        else { return }

        let vertices = Self.aspectFitVertices(
            textureSize: CGSize(width: width, height: height),
            viewSize: view.drawableSize
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(vertices, length: MemoryLayout<ThreadedVertex>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        var texelSize = SIMD2<Float>(1.0 / Float(max(width, 1)), 1.0 / Float(max(height, 1)))
        encoder.setFragmentBytes(&texelSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static func aspectFitVertices(textureSize: CGSize, viewSize: CGSize) -> [ThreadedVertex] {
        guard textureSize.width > 0, textureSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return [
                ThreadedVertex(position: [-1, -1], texCoord: [0, 1]),
                ThreadedVertex(position: [1, -1], texCoord: [1, 1]),
                ThreadedVertex(position: [-1, 1], texCoord: [0, 0]),
                ThreadedVertex(position: [1, 1], texCoord: [1, 0]),
            ]
        }
        let textureAspect = Double(textureSize.width / textureSize.height)
        let viewAspect = Double(viewSize.width / viewSize.height)
        var scaleX: Float = 1, scaleY: Float = 1
        if textureAspect > viewAspect {
            scaleY = Float(viewAspect / textureAspect)
        } else {
            scaleX = Float(textureAspect / viewAspect)
        }
        return [
            ThreadedVertex(position: [-scaleX, -scaleY], texCoord: [0, 1]),
            ThreadedVertex(position: [scaleX, -scaleY], texCoord: [1, 1]),
            ThreadedVertex(position: [-scaleX, scaleY], texCoord: [0, 0]),
            ThreadedVertex(position: [scaleX, scaleY], texCoord: [1, 0]),
        ]
    }
}

struct ThreadedMetalGameView: UIViewRepresentable {
    let renderer: PS1ThreadedRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = renderer
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif
