import SwiftUI
import MetalKit
import AVFoundation

// MetalGameView and NativePlayerRenderer live in their own file, shared
// between iOS's real player (NativePlayerView) and tvOS's PS1PlayTestView,
// rather than duplicated for tvOS: nothing in this pipeline (Metal,
// AVFoundation, the UIKit types it touches) is iOS-only.

struct MetalGameView: UIViewRepresentable {
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
    private let frontend = LibretroFrontend.shared
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    /// One pipeline per shader, built once at attach so picking a shader in
    /// the pause menu is a dictionary lookup, not a recompile.
    private var pipelines: [NativeShader: MTLRenderPipelineState] = [:]
    private var samplerState: MTLSamplerState!
    private var texture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private let audio = NativePlayerAudio()

    /// The active shader, set by the pause menu's Shader row. The next
    /// `draw(in:)` picks it up immediately, which is what re-renders the
    /// frozen frame live behind the still-open menu. Published so the
    /// menu's checkmark tracks the pick without a separate state copy.
    @Published var shader: NativeShader = .sharp

    /// Held RetroPad ids, merged from the touch overlay and any connected
    /// game controller. Both already speak the same id space (see
    /// ControllerBindings.swift's RetroPad constants), so merging is just
    /// a union; FBNeo only needs "is this id down right now" each frame.
    private var heldButtons: Set<Int> = []

    func setButton(_ id: Int, down: Bool) {
        // 0...13 is the standard joypad; 20...23 is the twin-stick second
        // joystick's four directions (see ArcadeLayout.secondStick and
        // GameControllerManager.stick2), which LibretroFrontend answers
        // through RETRO_DEVICE_ANALOG rather than the joypad bitmask, but
        // carries in the same mask this renderer builds either way.
        // RetroPad.overlay (-1) isn't a game input at all.
        guard (0...13).contains(id) || (20...23).contains(id) else { return }
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
        let vertexFn = library?.makeFunction(name: "libretro_vertex")

        for candidate in NativeShader.allCases {
            guard let fragmentFn = library?.makeFunction(name: candidate.fragmentFunctionName) else { continue }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            if let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) {
                pipelines[candidate] = pipeline
            }
        }

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
    /// the run rather than immediately: cores need a beat after booting
    /// before a full machine state takes, the same settle delay the
    /// webview player learned the hard way.
    var pendingState: Data?
    /// A battery save (a PS1 memory card) waiting to be copied into the
    /// core's save RAM, set by the launch sync once it has decided which
    /// copy wins. Applied on this draw loop, not where it was fetched,
    /// because the core reads and writes the same buffer inside
    /// retro_run. No settle delay: unlike a machine state, save RAM is
    /// plain memory the core only consults when the game visits its own
    /// save screens, and applying late risks the game having already
    /// read an empty card.
    var pendingSaveRAM: Data?
    /// While true the draw loop presents but does not run the core: the
    /// memory card decision is still in flight, and a PS1 game must not
    /// boot past its own card check before the card is in the slot. EA's
    /// games check during the boot logos, which is exactly the race that
    /// made an adopted card invisible until the second launch. Set before
    /// the first frame for card platforms, cleared by the launch sync
    /// whichever way it resolves.
    var awaitingSaveRAM = false
    private var framesRun = 0

    /// The core's current save RAM. Only call while `paused`, the same
    /// contract as serializeState and for the same reason.
    func snapshotSaveRAM() -> Data? {
        frontend.saveRAM()
    }

    func draw(in view: MTKView) {
        if !paused && !awaitingSaveRAM {
            if let card = pendingSaveRAM {
                pendingSaveRAM = nil
                let loaded = frontend.loadSaveRAM(card)
                // MTKView drives this on the main thread, so recording
                // straight from here is safe. The apply's result was
                // silently discarded before, which made "the write never
                // landed" indistinguishable from "the game ignored it".
                DiagnosticsLog.record(
                    context: "Memory card",
                    message: loaded
                        ? "Card seated in the core (frame \(framesRun))."
                        : "Core refused the card bytes (frame \(framesRun)).",
                    romVersion: nil
                )
            }
            let mask = heldButtons.reduce(into: UInt32(0)) { $0 |= (1 << $1) }
            frontend.setButtonMask(mask)
            frontend.runFrame()
            framesRun += 1
            if let state = pendingState, framesRun > 60 {
                pendingState = nil
                frontend.unserializeState(state)
            }

            if let audioData = frontend.drainAudio() {
                audio.enqueue(audioData)
            }

            if let frame = frontend.latestFrame() {
                updateTexture(from: frame)
            }
        }

        guard let texture,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let pipelineState = pipelines[shader] ?? pipelines[.sharp]
        else { return }

        let vertices = aspectFitVertices(
            textureSize: CGSize(width: textureWidth, height: textureHeight),
            viewSize: view.drawableSize,
            rotation: Int(frontend.rotation())
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        var texelSize = SIMD2<Float>(1.0 / Float(max(textureWidth, 1)), 1.0 / Float(max(textureHeight, 1)))
        encoder.setFragmentBytes(&texelSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Scratch buffer for `.RGB1555`/`.RGB565` frames, reused across calls
    /// rather than allocated fresh every frame.
    private var conversionBuffer: [UInt8] = []

    private func updateTexture(from frame: LibretroFrame) {
        let width = Int(frame.width)
        let height = Int(frame.height)

        // Always bgra8Unorm, converting 16-bit formats ourselves, rather
        // than trusting Metal's native 16-bit packed texture formats
        // (.b5g6r5Unorm, .bgr5A1Unorm) to store libretro's bit layout the
        // way their names suggest. That native path was never actually
        // exercised until Genesis Plus GX, the first core in this app to
        // not request XRGB8888, and it rendered a real game as solid
        // black with no error: either Metal's undocumented packing
        // differs from libretro's, or the format itself silently failed
        // to create a texture at all, both real possibilities neither
        // worth staking correctness on. Converting here uses only
        // libretro's own documented bit layout (retro_pixel_format in
        // libretro.h), nothing assumed about Metal's internals.
        if texture == nil || textureWidth != width || textureHeight != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
            textureWidth = width
            textureHeight = height
        }

        let bytesPerRow = width * 4
        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            switch frame.pixelFormat {
            case .XRGB8888:
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: Int(frame.bytesPerRow)
                )
            case .RGB565, .RGB1555:
                if conversionBuffer.count != bytesPerRow * height {
                    conversionBuffer = [UInt8](repeating: 0, count: bytesPerRow * height)
                }
                let srcStride = Int(frame.bytesPerRow)
                let is565 = frame.pixelFormat == .RGB565
                conversionBuffer.withUnsafeMutableBytes { dst in
                    for y in 0..<height {
                        let srcRow = base.advanced(by: y * srcStride).assumingMemoryBound(to: UInt16.self)
                        let dstRow = dst.baseAddress!.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        for x in 0..<width {
                            let p = srcRow[x]
                            let r: UInt8, g: UInt8, b: UInt8
                            if is565 {
                                r = UInt8((p >> 11) & 0x1F) << 3
                                g = UInt8((p >> 5) & 0x3F) << 2
                                b = UInt8(p & 0x1F) << 3
                            } else {
                                r = UInt8((p >> 10) & 0x1F) << 3
                                g = UInt8((p >> 5) & 0x1F) << 3
                                b = UInt8(p & 0x1F) << 3
                            }
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

        // The texture is always bgra8Unorm now: updateTexture converts
        // every source pixel format itself rather than trusting Metal's
        // native 16-bit packed formats, so there is only ever one case
        // to read back here.
        guard texture.pixelFormat == .bgra8Unorm else { return nil }
        texture.getBytes(&bgra, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        guard let context = CGContext(
            data: &bgra, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let cgImage = context.makeImage() else { return nil }

        let rotation = Int(frontend.rotation()) % 4
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

    private func aspectFitVertices(textureSize: CGSize, viewSize: CGSize, rotation: Int) -> [Vertex] {
        guard textureSize.width > 0, textureSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return [
                Vertex(position: [-1, -1], texCoord: [0, 1]),
                Vertex(position: [1, -1], texCoord: [1, 1]),
                Vertex(position: [-1, 1], texCoord: [0, 0]),
                Vertex(position: [1, 1], texCoord: [1, 0]),
            ]
        }

        // The core's own aspect ratio wins when it reports one; raw pixel
        // dimensions are the fallback, which used to be the only source.
        // Arcade boards are square-pixel, where the two always agree;
        // Saturn commonly is not, and rendering its raw pixels stretched
        // the picture until this existed. Rotated (TATE) boards are the
        // exception: FBNeo reports their aspect display-oriented, already
        // accounting for the rotation this code applies itself below, so
        // trusting it here rotated the correction on top of the rotation
        // and stretched every vertical game. Saturn never rotates, so
        // deriving rotated boards from raw pixels costs the fix nothing.
        let pixelAspect = rotation % 2 == 1 ? 0 : frontend.aspectRatio()
        let unrotatedAspect = pixelAspect > 0 ? pixelAspect : Double(textureSize.width / textureSize.height)

        // Vertical (TATE) boards render sideways and request rotation in
        // 90-degree counter-clockwise steps; an odd rotation swaps which
        // way the picture is tall for aspect-fit purposes.
        let rotated = rotation % 2 == 1
        let textureAspect = rotated ? 1 / unrotatedAspect : unrotatedAspect
        let viewAspect = Double(viewSize.width / viewSize.height)

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
