import SwiftUI
import MetalKit
import AVFoundation

/// Fullscreen native-player screen for the FBNeo spike. Drives retro_run
/// off MTKView's own display-link-backed draw loop, uploads each frame
/// into a Metal texture aspect-fit with no shaders/filters, and feeds
/// FBNeo's audio batches into an AVAudioEngine source node.
///
/// Spike-only: one file owning video, audio, and (eventually) input for
/// exactly one core. See docs/scope-native-player-spike.md and
/// [[native-player-frontend-architecture]] in memory, don't grow this into
/// a general frontend without splitting it up first.
struct NativePlayerView: View {
    let rom: Rom

    @StateObject private var renderer = NativePlayerRenderer()
    @State private var previousControllerSend: ((Int, Bool) -> Void)?

    private var layoutItems: [ControlLayout.Item] {
        let profile = ArcadeProfileStore.shared.resolve(romId: rom.id, shortname: rom.fsNameNoExt)
        return ArcadeLayout.build(for: profile).items(landscape: true)
    }

    var body: some View {
        ZStack {
            MetalGameView(renderer: renderer)
            TouchControlPad(items: layoutItems, send: { id, down in
                renderer.setButton(id, down: down)
            })
        }
        .ignoresSafeArea()
        .onAppear {
            previousControllerSend = GameControllerManager.shared.send
            GameControllerManager.shared.send = { [weak renderer] id, down in
                renderer?.setButton(id, down: down)
            }
        }
        .onDisappear {
            GameControllerManager.shared.send = previousControllerSend
        }
    }
}

private struct MetalGameView: UIViewRepresentable {
    let renderer: NativePlayerRenderer

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

private struct Vertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

final class NativePlayerRenderer: NSObject, ObservableObject, MTKViewDelegate {
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var samplerState: MTLSamplerState!
    private var texture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private let audio = NativePlayerAudio()

    /// Held RetroPad ids, merged from the touch overlay and any connected
    /// game controller. Both already speak the same id space (see
    /// ControllerBindings.swift's RetroPad constants), so merging is just
    /// a union; FBNeo only needs "is this id down right now" each frame.
    private var heldButtons: Set<Int> = []

    func setButton(_ id: Int, down: Bool) {
        guard id >= 0 && id <= 13 else { return } // RetroPad.overlay (-1) and analog axes aren't joypad buttons
        if down {
            heldButtons.insert(id)
        } else {
            heldButtons.remove(id)
        }
    }

    func attach(to view: MTKView) {
        guard let device = view.device else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()

        let library = try? device.makeDefaultLibrary(bundle: .main)
        let vertexFn = library?.makeFunction(name: "fbneo_vertex")
        let fragmentFn = library?.makeFunction(name: "fbneo_fragment")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerState = device.makeSamplerState(descriptor: samplerDescriptor)

        audio.start()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let mask = heldButtons.reduce(into: UInt32(0)) { $0 |= (1 << $1) }
        FBNeoBridge.setButtonMask(mask)
        FBNeoBridge.runFrame()

        if let audioData = FBNeoBridge.drainAudio() {
            audio.enqueue(audioData)
        }

        if let frame = FBNeoBridge.latestFrame() {
            updateTexture(from: frame)
        }

        guard let texture,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let pipelineState
        else { return }

        let vertices = aspectFitVertices(
            textureSize: CGSize(width: textureWidth, height: textureHeight),
            viewSize: view.drawableSize
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateTexture(from frame: FBNeoFrame) {
        let width = Int(frame.width)
        let height = Int(frame.height)
        let pixelFormat = metalPixelFormat(for: frame.pixelFormat)

        if texture == nil || textureWidth != width || textureHeight != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
            textureWidth = width
            textureHeight = height
        }

        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture?.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: Int(frame.bytesPerRow)
            )
        }
    }

    private func metalPixelFormat(for format: FBNeoPixelFormat) -> MTLPixelFormat {
        switch format {
        case .XRGB8888: return .bgra8Unorm
        case .RGB565: return .b5g6r5Unorm
        case .RGB1555: return .bgr5A1Unorm
        @unknown default: return .bgra8Unorm
        }
    }

    private func aspectFitVertices(textureSize: CGSize, viewSize: CGSize) -> [Vertex] {
        guard textureSize.width > 0, textureSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return [
                Vertex(position: [-1, -1], texCoord: [0, 1]),
                Vertex(position: [1, -1], texCoord: [1, 1]),
                Vertex(position: [-1, 1], texCoord: [0, 0]),
                Vertex(position: [1, 1], texCoord: [1, 0]),
            ]
        }

        let textureAspect = textureSize.width / textureSize.height
        let viewAspect = viewSize.width / viewSize.height

        var scaleX: Float = 1
        var scaleY: Float = 1
        if textureAspect > viewAspect {
            scaleY = Float(viewAspect / textureAspect)
        } else {
            scaleX = Float(textureAspect / viewAspect)
        }

        return [
            Vertex(position: [-scaleX, -scaleY], texCoord: [0, 1]),
            Vertex(position: [scaleX, -scaleY], texCoord: [1, 1]),
            Vertex(position: [-scaleX, scaleY], texCoord: [0, 0]),
            Vertex(position: [scaleX, scaleY], texCoord: [1, 0]),
        ]
    }
}

/// Feeds FBNeo's audio batches into CoreAudio through a small ring buffer,
/// decoupling the core's variable per-frame sample count from the fixed
/// render callback AVAudioEngine expects.
private final class NativePlayerAudio {
    private let engine = AVAudioEngine()
    private var ringBuffer: [Int16] = []
    private let lock = NSLock()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let sampleRate = FBNeoBridge.audioSampleRate()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let framesNeeded = Int(frameCount)

            self.lock.lock()
            let available = min(framesNeeded, self.ringBuffer.count / 2)
            let samples = Array(self.ringBuffer.prefix(available * 2))
            if available > 0 {
                self.ringBuffer.removeFirst(available * 2)
            }
            self.lock.unlock()

            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                for frame in 0..<framesNeeded {
                    if frame < available {
                        data[frame] = Float32(samples[frame * 2]) / Float32(Int16.max)
                    } else {
                        data[frame] = 0
                    }
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func enqueue(_ data: Data) {
        let samples = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        lock.lock()
        ringBuffer.append(contentsOf: samples)
        // Cap the buffer so a stalled render loop can't grow this forever.
        let maxSamples = 44100 * 2 // ~1 second, stereo
        if ringBuffer.count > maxSamples {
            ringBuffer.removeFirst(ringBuffer.count - maxSamples)
        }
        lock.unlock()
    }
}
