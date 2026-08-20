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
        // Deliberately the default three drawables. A two-drawable
        // low-latency configuration was tried and measured on the Apple
        // TV (2026-08-20, FrameTrace): both hardware-rendered cores
        // locked to every other vsync, N64's presented rate halving from
        // 50 to 30 with a 33ms median draw gap, so the "latency" saving
        // doubled real present latency. Software cores were unaffected.
        // Do not retry without measuring the readback path first.
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
    /// Decodes a raw RGB565 frame into `texture` on the GPU; see
    /// `unpackRGB565`.
    private var rgb565UnpackPipeline: MTLRenderPipelineState?
    /// Raw packed-pixel source for that path, r16Uint so no CPU-side
    /// interpretation happens before it reaches the shader.
    private var rgb565SourceTexture: MTLTexture?
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

    /// How many draw(in:) calls actually landed in the last second, updated
    /// once a second rather than every frame so reading it doesn't itself
    /// perturb timing. Diagnostic only, added to chase a real report of
    /// choppy audio and laggy video together on tvOS hardware: this number
    /// says whether the whole pipeline (core + render + audio) is actually
    /// keeping up with the display, not just whether the core alone can
    /// (the original go/no-go measured core throughput only, no video or
    /// audio overhead).
    @Published private(set) var measuredFPS: Double = 0
    private var fpsFrameCount = 0
    private var fpsWindowStart: CFTimeInterval = 0

    /// The single longest gap between consecutive draw(in:) calls in the
    /// last window, milliseconds. A 1-second average can read a clean 30fps
    /// while masking real stalls and bursts underneath; this catches the
    /// jitter the average hides, added after a real report of choppy
    /// gameplay that measured a stable-looking average anyway.
    @Published private(set) var worstFrameMS: Double = 0

    /// The display-oriented aspect ratio of the current picture, rotation
    /// already applied, 0 until the first frame has been fitted. This is
    /// the same value `aspectFitVertices` fits the picture with, published
    /// so a view layered over the Metal surface can reproduce the fitted
    /// rect in SwiftUI coordinates (tvOS's letterbox glow today; an iOS
    /// HDMI-out treatment would need exactly this too).
    @Published private(set) var displayAspect: Double = 0
    private var worstFrameDelta: CFTimeInterval = 0
    private var lastDrawTime: CFTimeInterval = 0

    /// Temporary instrumentation for issue #6: the time the Metal upload
    /// took on this draw, milliseconds. The other three stages are timed
    /// inside `LibretroFrontend` where they happen. See `FrameTrace`.
    private var uploadMS: Double = 0

    /// Held RetroPad ids, merged from the touch overlay and any connected
    /// game controller. Both already speak the same id space (see
    /// ControllerBindings.swift's RetroPad constants), so merging is just
    /// a union; FBNeo only needs "is this id down right now" each frame.
    private var heldButtons: [Set<Int>] = [[], []]

    func setButton(_ id: Int, down: Bool, port: Int) {
        guard heldButtons.indices.contains(port) else { return }
        // 0...13 is the standard joypad; 20...23 is the twin-stick second
        // joystick's four directions (see ArcadeLayout.secondStick and
        // GameControllerManager.stick2), which LibretroFrontend answers
        // through RETRO_DEVICE_ANALOG rather than the joypad bitmask, but
        // carries in the same mask this renderer builds either way.
        // RetroPad.overlay (-1) isn't a game input at all.
        guard (0...13).contains(id) || (20...23).contains(id) else { return }
        if down {
            heldButtons[port].insert(id)
        } else {
            heldButtons[port].remove(id)
        }
    }

    /// Dreamcast's real analog stick, the one input in this app that is
    /// a continuous value rather than a RetroPad button id. Forwarded
    /// straight through to `LibretroFrontend`, which is the only place
    /// that knows how to fold it into RETRO_DEVICE_ANALOG reads; nothing
    /// about it lives in `heldButtons`.
    func setStick(x: Double, y: Double, port: Int) {
        LibretroFrontend.shared.setAnalogStickX(Float(x), y: Float(y), port: port)
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

        // Built once alongside the shader pipelines: the RGB565 decode is
        // a fixed pass, unrelated to whichever display shader is picked.
        let unpackDescriptor = MTLRenderPipelineDescriptor()
        unpackDescriptor.vertexFunction = vertexFn
        unpackDescriptor.fragmentFunction = library?.makeFunction(name: "shader_rgb565_unpack_fragment")
        unpackDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        rgb565UnpackPipeline = try? device.makeRenderPipelineState(descriptor: unpackDescriptor)

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
    /// The Game Boy real-time clock region riding alongside
    /// `pendingSaveRAM`, seated the same frame. Gambatte keeps the clock
    /// in its own RETRO_MEMORY_RTC region, and a restored save without it
    /// resets the clock Pokemon Gold and Silver's day/night system runs
    /// on. Nil for every core without a clock region.
    var pendingRTC: Data?
    /// While true the draw loop presents but does not run the core: the
    /// memory card decision is still in flight, and a PS1 game must not
    /// boot past its own card check before the card is in the slot. EA's
    /// games check during the boot logos, which is exactly the race that
    /// made an adopted card invisible until the second launch. Set before
    /// the first frame for card platforms, cleared by the launch sync
    /// whichever way it resolves.
    var awaitingSaveRAM = false
    private var framesRun = 0
    /// Wall-clock pacing for the core, so it advances at its own declared
    /// frame rate rather than once per display refresh. See the draw loop.
    private var runAccumulator: CFTimeInterval = 0
    private var lastRunTimestamp: CFTimeInterval = 0
    /// The audio governor's schedule: how many audio frames the core
    /// should have produced by now, advanced by wall clock while the game
    /// runs. Compared against what the core actually produced; see the
    /// draw loop. `audioBaseFrames` anchors the count at this session's
    /// start, since the frontend's counter spans the whole process.
    private var audioTargetFrames: Double = 0
    private var audioBaseFrames: UInt64 = 0

    /// The core's current save RAM. Only call while `paused`, the same
    /// contract as serializeState and for the same reason.
    func snapshotSaveRAM() -> Data? {
        frontend.saveRAM()
    }

    /// The core's real-time clock region (RETRO_MEMORY_RTC, id 1), nil
    /// for cores without one. Same paused-only contract as
    /// `snapshotSaveRAM`.
    func snapshotRTC() -> Data? {
        frontend.memoryRegion(1)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        // Skipped while paused: nothing on tvOS displays these, and
        // publishing them here republishes `self` once a second even with
        // the core sitting idle, which re-renders the whole pause menu and
        // made the Shader/Glow dropdown flicker while it was open, found
        // on device 2026-08-15.
        if !paused {
            if fpsWindowStart == 0 { fpsWindowStart = now }
            fpsFrameCount += 1
            if lastDrawTime != 0 {
                worstFrameDelta = max(worstFrameDelta, now - lastDrawTime)
            }
            if now - fpsWindowStart >= 1.0 {
                measuredFPS = Double(fpsFrameCount) / (now - fpsWindowStart)
                worstFrameMS = worstFrameDelta * 1000
                fpsFrameCount = 0
                fpsWindowStart = now
                worstFrameDelta = 0
            }
        }
        // Captured before lastDrawTime moves on, since the trace below
        // wants the gap this draw actually followed.
        let drawGapMS = lastDrawTime == 0 ? 0 : (now - lastDrawTime) * 1000
        lastDrawTime = now

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
            if let clock = pendingRTC {
                pendingRTC = nil
                _ = frontend.loadMemoryRegion(clock, region: 1)
            }
            for (port, held) in heldButtons.enumerated() {
                let mask = held.reduce(into: UInt32(0)) { $0 |= (1 << $1) }
                frontend.setButtonMask(mask, port: port)
            }
            // Run the core at the rate the core asked for, not once per
            // draw. This used to be one retro_run per display refresh,
            // which silently ran every game at whatever rate the display
            // happened to tick: fine where that is 60 and the core wants
            // 59.94, badly wrong on an Apple TV whose display link runs
            // far higher. Instrumented 2026-08-16 on Dreamcast, where the
            // core was producing 65,000 to 85,000 audio frames a second
            // against 44,100 of realtime, roughly 1.5x too fast, with the
            // surplus discarded, which is what made music play back
            // sounding sped up.
            let interval = 1.0 / max(frontend.targetFPS(), 1)
            if lastRunTimestamp == 0 {
                lastRunTimestamp = now
                audioBaseFrames = frontend.debugAudioFramesTotal()
                audioTargetFrames = 0
            }
            let delta = now - lastRunTimestamp
            runAccumulator += delta
            lastRunTimestamp = now
            // Capped so a stall cannot bank a debt the core then tries to
            // repay all at once, which would stutter and flood the audio
            // buffer; anything beyond a couple of frames behind is time
            // that is simply gone.
            if runAccumulator > interval * 4 { runAccumulator = interval }

            // The audio governor, the brake wall-clock pacing alone cannot
            // be. Pacing assumes one retro_run advances one emulated
            // frame; Flycast's threaded mode breaks that assumption, its
            // emulation thread free-running as far ahead as its render
            // queue allows, measured on device at up to five times
            // realtime with the surplus audio discarded as static. In
            // RetroArch the brake is the audio callback blocking until
            // the buffer drains; this frontend's callback must never
            // block (it feeds a realtime ring from the main thread), so
            // the same backpressure is applied here instead: when the
            // core's own audio output is ahead of the wall clock, it is
            // not due, whatever the frame accumulator says. Skipped runs
            // leave the render queue unconsumed, which is what actually
            // stalls the emulation thread.
            //
            // Production against the wall clock, deliberately not against
            // the playback buffer: a gate on playback draining freezes
            // the game whenever the audio engine is not running, the
            // exact hazard issue #6 records against the first attempt at
            // this. The wall clock advances no matter what.
            // Flycast only. Every other core advances exactly one emulated
            // frame per retro_run, so the pacing above already holds it to
            // realtime and the governor could only ever take runs away:
            // applied to all cores it slowed N64 down, found on device the
            // same evening it landed.
            let audioRate = frontend.needsAudioGovernor() ? frontend.audioSampleRate() : 0
            var audioProduced = Double(frontend.debugAudioFramesTotal() &- audioBaseFrames)
            if audioRate > 0 {
                audioTargetFrames += delta * audioRate
                // A core running behind schedule keeps its full claim to
                // run (the governor only ever slows, never speeds), but
                // the debt it may repay at speed is capped, so a slow
                // stretch is followed by normal pace rather than an
                // audible fast-forward sprint.
                if audioTargetFrames - audioProduced > audioRate * 0.1 {
                    audioTargetFrames = audioProduced + audioRate * 0.1
                }
            }
            // One frame's worth of audio plus a little jitter room, and
            // no more. This was 0.05 (50ms) and that generosity was felt:
            // the governor lets the emulation run ahead of the wall clock
            // by up to the cushion, and the lead IS input latency, since
            // the frame on screen trails the emulated present by exactly
            // that much. Reported by Marcus 2026-08-18 as bad input lag on
            // Dreamcast only, which fits: the governor is Flycast-only,
            // and N64 felt fine. 0.02 keeps a full emulated frame of
            // slack (~17ms) against audio crackle; if crackle returns in
            // heavy scenes, this is the number to raise, knowing each
            // hundredth is 10ms of felt lag. Measured against 0.05 on the
            // Apple TV (2026-08-20, FrameTrace, Crazy Taxi): draw pacing
            // and audio hold were identical within run noise, so the
            // tighter value costs nothing measurable.
            let audioCushion = audioRate * 0.02
            var ranThisDraw = 0
            while runAccumulator >= interval && ranThisDraw < 2 {
                if audioRate > 0 && audioProduced - audioTargetFrames > audioCushion {
                    // Ahead of realtime: burn the banked time without
                    // running, otherwise the accumulator would force the
                    // skipped frame in on the next draw and the governor
                    // would never win.
                    runAccumulator -= interval
                    continue
                }
                frontend.runFrame()
                framesRun += 1
                ranThisDraw += 1
                runAccumulator -= interval
                audioProduced = Double(frontend.debugAudioFramesTotal() &- audioBaseFrames)
            }
            // A draw that ran no emulated frame still presents the last
            // one below, so the picture holds steady while the core is
            // simply not due yet.
            if ranThisDraw > 0, let state = pendingState, framesRun > 60 {
                pendingState = nil
                frontend.unserializeState(state)
            }

            if ranThisDraw > 0, let audioData = frontend.drainAudio() {
                audio.enqueue(audioData)
            }

            if ranThisDraw > 0 {
                let uploadStart = CACurrentMediaTime()
                if let frame = frontend.latestFrame() {
                    updateTexture(from: frame)
                    uploadMS = (CACurrentMediaTime() - uploadStart) * 1000
                }
            }

            // Temporary, for issue #6. Recorded only on draws that actually
            // advanced the core: a draw that was simply not due yet has no
            // frame to account for and would dilute the trace with zeroes.
            if ranThisDraw > 0 {
                FrameTrace.shared.record(
                    drawGap: drawGapMS,
                    framesRun: ranThisDraw,
                    run: frontend.debugCoreRunMS(),
                    readback: frontend.debugReadbackMS(),
                    swizzle: frontend.debugSwizzleMS(),
                    upload: uploadMS,
                    audioFrames: frontend.debugAudioFramesTotal(),
                    hwFrames: frontend.debugHWFramesTotal(),
                    runCalls: frontend.debugRunCallTotal(),
                    hwDupes: frontend.debugHWDupeTotal(),
                    targetFPS: frontend.targetFPS(),
                    // Added 2026-08-17: the readback's cost scales with
                    // pixel count, and N64 games switch resolution mid
                    // game, so a trace that does not record the size
                    // cannot tell a heavier scene from a bigger frame.
                    frameWidth: textureWidth,
                    frameHeight: textureHeight
                )
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
            rotation: Int(frontend.rotation()),
            flipped: textureIsFlipped
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

    /// Whether the frame currently in `texture` arrived upside down, which
    /// only ever happens on the hardware-render path (GL's framebuffer
    /// origin is bottom-left). Read by `draw` when it builds the quad, so
    /// the turn happens in texture coordinates instead of on the CPU.
    private var textureIsFlipped = false

    /// The Metal format `texture` was created with. Tracked because it is
    /// no longer always `.bgra8Unorm`: the hardware-render path stores its
    /// bytes as RGBA rather than paying a per-pixel swap to reorder them.
    private var texturePixelFormat: MTLPixelFormat = .bgra8Unorm

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
        // The one exception to "always bgra8Unorm" is the hardware-render
        // path. Those bytes come out of glReadPixels as RGBA, and a
        // sampler reads an rgba8Unorm texture to exactly the same colour
        // it reads a bgra8Unorm one to, because the format describes the
        // memory layout rather than the meaning. Storing them as they
        // already are is what lets the byte-swap loop go away entirely.
        let wantedFormat: MTLPixelFormat = frame.pixelFormat == .RGBA8888 ? .rgba8Unorm : .bgra8Unorm
        if texture == nil || textureWidth != width || textureHeight != height
            || texturePixelFormat != wantedFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: wantedFormat, width: width, height: height, mipmapped: false
            )
            // .renderTarget as well as .shaderRead: the RGB565 path below
            // decodes into this texture with a real render pass, and Metal
            // rejects a colour attachment whose texture was not created to
            // be one.
            descriptor.usage = [.shaderRead, .renderTarget]
            texture = device.makeTexture(descriptor: descriptor)
            textureWidth = width
            textureHeight = height
            texturePixelFormat = wantedFormat
        }
        textureIsFlipped = frame.flippedVertically

        let bytesPerRow = width * 4
        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            switch frame.pixelFormat {
            case .XRGB8888, .RGBA8888:
                // Both are a straight upload of 32-bit pixels; the only
                // difference is which Metal format the texture was made
                // with above, so neither needs any work here.
                texture?.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: Int(frame.bytesPerRow)
                )
            case .RGB565:
                // The GPU path. This used to be the same scalar per-pixel
                // CPU loop RGB1555 still uses below, running on the main
                // thread inside draw(in:), and it was the single biggest
                // cost in the frame: measured on real Apple TV hardware at
                // 30fps with 50ms stalls, versus a clean 60fps/17ms once
                // the decode moved to the shader. RGB565 is what most
                // cores here actually emit (FBNeo's arcade boards among
                // them), so this is the common case, not an edge one.
                unpackRGB565(
                    base: base, width: width, height: height, srcStride: Int(frame.bytesPerRow)
                )
            case .RGB1555:
                // Left on the CPU deliberately: nothing in this app has
                // been observed to emit RGB1555, so there is no measured
                // cost to move and no way to verify a GPU version renders
                // it correctly.
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

    /// Uploads a raw RGB565 frame untouched into an r16Uint source
    /// texture, then runs one GPU render pass that decodes it straight
    /// into `texture` (bgra8Unorm), replacing the old per-pixel CPU loop.
    ///
    /// Decoding into a bgra8Unorm texture, rather than sampling the packed
    /// r16Uint one directly in each display shader, is what keeps the
    /// shader list (sharp, CRT, LCD, Game Boy dot matrix) working
    /// unchanged: they all still sample an ordinary colour texture and
    /// never learn that some cores hand over 16-bit pixels.
    ///
    /// Falls back to leaving `texture` at its last contents if the
    /// pipeline failed to build, rather than crashing.
    private func unpackRGB565(base: UnsafeRawPointer, width: Int, height: Int, srcStride: Int) {
        guard let rgb565UnpackPipeline, let texture else { return }

        if rgb565SourceTexture == nil
            || rgb565SourceTexture?.width != width
            || rgb565SourceTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            rgb565SourceTexture = device.makeTexture(descriptor: descriptor)
        }
        rgb565SourceTexture?.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: base, bytesPerRow: srcStride
        )

        guard let rgb565SourceTexture,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .dontCare
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        let quad: [Vertex] = [
            Vertex(position: [-1, -1], texCoord: [0, 1]),
            Vertex(position: [1, -1], texCoord: [1, 1]),
            Vertex(position: [-1, 1], texCoord: [0, 0]),
            Vertex(position: [1, 1], texCoord: [1, 0]),
        ]
        encoder.setRenderPipelineState(rgb565UnpackPipeline)
        encoder.setVertexBytes(quad, length: MemoryLayout<Vertex>.stride * quad.count, index: 0)
        encoder.setFragmentTexture(rgb565SourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.commit()
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

        // Two layouts reach this point. Software-rendered cores are
        // converted to bgra8Unorm by updateTexture; the hardware-render
        // path stores its readback as rgba8Unorm instead, since swapping
        // those bytes cost more per frame than it was worth. Anything
        // else would be a texture this class did not create.
        let byteOrderInfo: UInt32
        switch texture.pixelFormat {
        case .bgra8Unorm:
            byteOrderInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        case .rgba8Unorm:
            byteOrderInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        default:
            return nil
        }
        texture.getBytes(&bgra, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        // A hardware-render frame is upside down in the texture, since the
        // display path turns it over in texture coordinates rather than in
        // memory. A PNG has no such trick available, so the rows are
        // reversed here. Once per saved state, not per frame.
        if textureIsFlipped {
            var row = [UInt8](repeating: 0, count: bytesPerRow)
            for y in 0..<(height / 2) {
                let top = y * bytesPerRow
                let bottom = (height - 1 - y) * bytesPerRow
                row.withUnsafeMutableBufferPointer { scratch in
                    bgra.withUnsafeMutableBufferPointer { buf in
                        scratch.baseAddress!.update(from: buf.baseAddress! + top, count: bytesPerRow)
                        (buf.baseAddress! + top).update(from: buf.baseAddress! + bottom, count: bytesPerRow)
                        (buf.baseAddress! + bottom).update(from: scratch.baseAddress!, count: bytesPerRow)
                    }
                }
            }
        }

        guard let context = CGContext(
            data: &bgra, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: byteOrderInfo
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

    /// `flipped` turns the picture over in texture coordinates, for frames
    /// that arrived bottom-row-first from a GL framebuffer. Defaults to
    /// false, so every software-rendered core builds exactly the quad it
    /// built before this existed.
    private func aspectFitVertices(
        textureSize: CGSize, viewSize: CGSize, rotation: Int, flipped: Bool = false
    ) -> [Vertex] {
        // Origin corners for the triangle strip, before any rotation:
        // bottom-left, bottom-right, top-left, top-right.
        let base: [SIMD2<Float>] = flipped
            ? [[0, 0], [1, 0], [0, 1], [1, 1]]
            : [[0, 1], [1, 1], [0, 0], [1, 0]]
        guard textureSize.width > 0, textureSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return [
                Vertex(position: [-1, -1], texCoord: base[0]),
                Vertex(position: [1, -1], texCoord: base[1]),
                Vertex(position: [-1, 1], texCoord: base[2]),
                Vertex(position: [1, 1], texCoord: base[3]),
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

        if displayAspect != textureAspect {
            displayAspect = textureAspect
        }

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
        // top-left, top-right. Starts from `base`, so a flipped frame is
        // turned over before it is rotated. The two never combine today,
        // rotation being an arcade (TATE) request and the only flipped
        // frames coming from the two GL cores, neither of which rotates.
        var coords = base
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
