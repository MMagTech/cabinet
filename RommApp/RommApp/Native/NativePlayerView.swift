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
    /// A state picked on the launch screen, restored shortly after boot.
    var initialState: Data?

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var renderer = NativePlayerRenderer()
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var previousControllerSend: ((Int, Bool) -> Void)?
    @State private var previousControllerMenu: (() -> Void)?
    @State private var menuVisible = false
    @State private var menuStatus: String?
    @State private var menuBusy = false
    /// The same visibility slider the webview player honors.
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7

    /// The emulator tag uploaded states carry. Tested 2026-08-06 and the
    /// answer is no: the webview's WASM FBNeo (the build frozen inside
    /// EmulatorJS 4.2.3) cannot restore states written by this native
    /// FBNeo build, it fails silently and boots fresh. libretro state
    /// formats are core-build-specific, so the two players' states are
    /// distinct on purpose: a separate tag keeps each player's launch UI
    /// from offering states it cannot actually restore.
    static let emulatorTag = "fbneo-native"

    private var profile: ArcadeProfile {
        ArcadeProfileStore.shared.resolve(romId: rom.id, shortname: rom.fsNameNoExt)
    }

    private var controlLayout: ControlLayout {
        ArcadeLayout.build(for: profile)
    }

    private func layoutItems(landscape: Bool) -> [ControlLayout.Item] {
        controlLayout.items(landscape: landscape)
    }

    /// Matches PlayerView.controlStripHeight: vertical games trade some
    /// control height for canvas, since every point matters for a taller
    /// picture and their genres need fewer, simpler inputs.
    private var controlStripHeight: CGFloat {
        profile.vertical ? 280 : 330
    }

    private func handleInput(_ id: Int, down: Bool) {
        if id == RetroPad.overlay {
            if down { openMenu() }
            return
        }
        renderer.setButton(id, down: down)
    }

    private func openMenu() {
        renderer.paused = true
        menuStatus = nil
        menuVisible = true
    }

    private func closeMenu() {
        menuVisible = false
        renderer.paused = false
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let showsControls = !controllers.isConnected

            ZStack {
                if isLandscape || !showsControls {
                    // Full screen canvas, pad in the gutters (or hidden with a
                    // controller connected), matching PlayerView's .overlay case.
                    ZStack {
                        MetalGameView(renderer: renderer)
                        if showsControls {
                            TouchControlPad(items: layoutItems(landscape: true), send: handleInput, system: controlLayout.system)
                                .opacity(controlOpacity)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black)
                } else {
                    // Portrait: the pad's items are normalised against a bottom
                    // strip, not the full screen, so the canvas and pad split
                    // the screen rather than overlap. Matches PlayerView's
                    // .bottomStrip case exactly, same strip height. The canvas
                    // stays below the top safe area so the island never eats
                    // the picture; only the strip runs to the screen's edge.
                    VStack(spacing: 0) {
                        MetalGameView(renderer: renderer)
                            .frame(height: max(geometry.size.height - controlStripHeight, 0))
                        TouchControlPad(items: layoutItems(landscape: false), send: handleInput, system: controlLayout.system)
                            .opacity(controlOpacity)
                            .frame(height: controlStripHeight)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if menuVisible {
                    pauseMenu
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            previousControllerSend = GameControllerManager.shared.send
            previousControllerMenu = GameControllerManager.shared.onMenu
            GameControllerManager.shared.send = { [weak renderer] id, down in
                renderer?.setButton(id, down: down)
            }
            GameControllerManager.shared.onMenu = { openMenu() }
            renderer.pendingState = initialState
        }
        .onDisappear {
            GameControllerManager.shared.send = previousControllerSend
            GameControllerManager.shared.onMenu = previousControllerMenu
        }
    }

    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(rom.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let menuStatus {
                    Text(menuStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Resume") { closeMenu() }
                    .buttonStyle(.borderedProminent)
                Button("Save state") { saveState() }
                    .buttonStyle(.bordered)
                Button("Load latest state") { loadLatestState() }
                    .buttonStyle(.bordered)
                Button("Exit game", role: .destructive) { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .disabled(menuBusy)
        }
    }

    /// Mirrors the webview player's naming exactly (RomM 5.1.0's own
    /// buildStateName): the rom's short name plus an ISO timestamp with
    /// colons and dots flattened to dashes, T to a space, Z dropped.
    private func stateFileStem() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
        return "\(rom.fsNameNoExt) [\(stamp)]"
    }

    private func saveState() {
        guard let state = FBNeoBridge.serializeState() else {
            menuStatus = "The core produced no state to save."
            return
        }
        // Captured before the upload starts, while the pause menu still
        // holds the exact frame being saved. The webview player does the
        // same one frame before its pause for the same reason.
        let screenshot = renderer.screenshotPNG()
        menuBusy = true
        menuStatus = "Uploading\u{2026}"
        let stem = stateFileStem()
        Task {
            do {
                try await session.uploadState(
                    romId: rom.id,
                    emulator: Self.emulatorTag,
                    fileName: "\(stem).state",
                    stateData: state,
                    screenshotName: screenshot != nil ? "\(stem).png" : nil,
                    screenshotData: screenshot
                )
                menuStatus = "Saved to RomM."
            } catch {
                menuStatus = error.localizedDescription
            }
            menuBusy = false
        }
    }

    private func loadLatestState() {
        menuBusy = true
        menuStatus = "Fetching\u{2026}"
        Task {
            do {
                let states = try await session.states(romId: rom.id)
                    .filter { $0.emulator == Self.emulatorTag }
                    .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                guard let latest = states.first else {
                    menuStatus = "No states for this core on the server."
                    menuBusy = false
                    return
                }
                let bytes = try await session.stateContent(latest)
                if FBNeoBridge.unserializeState(bytes) {
                    menuStatus = nil
                    menuBusy = false
                    closeMenu()
                } else {
                    menuStatus = "The core rejected that state. It was likely written by a different core build."
                    menuBusy = false
                }
            } catch {
                menuStatus = error.localizedDescription
                menuBusy = false
            }
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

    /// While true the draw loop keeps presenting the last frame but stops
    /// advancing the core, so the pause menu freezes the game rather than
    /// letting it run silently behind the overlay. Serialize/unserialize
    /// are only safe while this is set: they must never race a retro_run
    /// in progress, and both happen on the main thread this loop runs on.
    var paused = false

    /// A launch-screen state waiting to be restored. Applied a second into
    /// the run rather than immediately: FBNeo needs a beat after booting
    /// before a full machine state takes, the same settle delay the
    /// webview player learned the hard way.
    var pendingState: Data?
    private var framesRun = 0

    func draw(in view: MTKView) {
        if !paused {
            let mask = heldButtons.reduce(into: UInt32(0)) { $0 |= (1 << $1) }
            FBNeoBridge.setButtonMask(mask)
            FBNeoBridge.runFrame()
            framesRun += 1
            if let state = pendingState, framesRun > 60 {
                pendingState = nil
                FBNeoBridge.unserializeState(state)
            }

            if let audioData = FBNeoBridge.drainAudio() {
                audio.enqueue(audioData)
            }

            if let frame = FBNeoBridge.latestFrame() {
                updateTexture(from: frame)
            }
        }

        guard let texture,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let pipelineState
        else { return }

        let vertices = aspectFitVertices(
            textureSize: CGSize(width: textureWidth, height: textureHeight),
            viewSize: view.drawableSize,
            rotation: Int(FBNeoBridge.rotation())
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

    /// The current frame as a PNG for the state list's thumbnail, read
    /// back from the game texture rather than the drawable so it carries
    /// no letterboxing. TATE rotation gets baked into the pixels here:
    /// PNG has no orientation metadata, so a merely-tagged rotation would
    /// arrive sideways on every other client that shows it.
    func screenshotPNG() -> Data? {
        guard let texture else { return nil }
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)

        switch texture.pixelFormat {
        case .bgra8Unorm:
            texture.getBytes(&bgra, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        case .b5g6r5Unorm, .bgr5A1Unorm:
            var raw = [UInt16](repeating: 0, count: width * height)
            texture.getBytes(&raw, bytesPerRow: width * 2, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let is565 = texture.pixelFormat == .b5g6r5Unorm
            for i in 0..<(width * height) {
                let p = raw[i]
                let r, g, b: UInt8
                if is565 {
                    r = UInt8((p >> 11) & 0x1F) << 3
                    g = UInt8((p >> 5) & 0x3F) << 2
                    b = UInt8(p & 0x1F) << 3
                } else {
                    r = UInt8((p >> 10) & 0x1F) << 3
                    g = UInt8((p >> 5) & 0x1F) << 3
                    b = UInt8(p & 0x1F) << 3
                }
                bgra[i * 4] = b
                bgra[i * 4 + 1] = g
                bgra[i * 4 + 2] = r
                bgra[i * 4 + 3] = 255
            }
        default:
            return nil
        }

        guard let context = CGContext(
            data: &bgra, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else { return nil }

        let rotation = Int(FBNeoBridge.rotation()) % 4
        let orientation: UIImage.Orientation = [.up, .left, .down, .right][rotation]
        let oriented = UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
        let outputSize = rotation % 2 == 1
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: outputSize, format: format).pngData { _ in
            oriented.draw(in: CGRect(origin: .zero, size: outputSize))
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

    private func aspectFitVertices(textureSize: CGSize, viewSize: CGSize, rotation: Int) -> [Vertex] {
        // Vertical (TATE) boards render sideways and request rotation in
        // 90-degree counter-clockwise steps; an odd rotation swaps which
        // way the picture is tall for aspect-fit purposes.
        let rotated = rotation % 2 == 1
        let effectiveSize = rotated
            ? CGSize(width: textureSize.height, height: textureSize.width)
            : textureSize

        guard effectiveSize.width > 0, effectiveSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return [
                Vertex(position: [-1, -1], texCoord: [0, 1]),
                Vertex(position: [1, -1], texCoord: [1, 1]),
                Vertex(position: [-1, 1], texCoord: [0, 0]),
                Vertex(position: [1, 1], texCoord: [1, 0]),
            ]
        }

        let textureAspect = effectiveSize.width / effectiveSize.height
        let viewAspect = viewSize.width / viewSize.height

        var scaleX: Float = 1
        var scaleY: Float = 1
        if textureAspect > viewAspect {
            scaleY = Float(viewAspect / textureAspect)
        } else {
            scaleX = Float(textureAspect / viewAspect)
        }

        // Screen corners stay put; the texture coordinates walk around the
        // quad corner by corner, one step per 90 degrees of rotation.
        // Order matches the triangle strip: bottom-left, bottom-right,
        // top-left, top-right.
        var coords: [SIMD2<Float>] = [[0, 1], [1, 1], [0, 0], [1, 0]]
        for _ in 0..<(rotation % 4) {
            coords = coords.map { SIMD2<Float>(1 - $0.y, $0.x) }
        }

        return [
            Vertex(position: [-scaleX, -scaleY], texCoord: coords[0]),
            Vertex(position: [scaleX, -scaleY], texCoord: coords[1]),
            Vertex(position: [-scaleX, scaleY], texCoord: coords[2]),
            Vertex(position: [scaleX, scaleY], texCoord: coords[3]),
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
