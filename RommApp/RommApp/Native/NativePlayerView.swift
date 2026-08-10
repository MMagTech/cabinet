import SwiftUI
import MetalKit
import AVFoundation

/// Fullscreen native-player screen, core-agnostic. Drives retro_run off
/// MTKView's own display-link-backed draw loop through LibretroFrontend,
/// uploads each frame into a Metal texture aspect-fit with no
/// shaders/filters, and feeds the core's audio batches into an
/// AVAudioEngine source node. The caller (NativeLauncher) has already
/// activated the right core and loaded the game before this appears.
struct NativePlayerView: View {
    let rom: Rom
    let core: NativeCore
    /// A state picked on the launch screen, restored shortly after boot.
    var initialState: Data?

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var renderer = NativePlayerRenderer()
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var previousControllerSend: ((Int, Bool) -> Void)?
    @State private var previousControllerMenu: (() -> Void)?
    @State private var previousControllerDisconnect: (() -> Void)?
    @State private var menuVisible = false
    @State private var menuStatus: String?
    @State private var menuBusy = false
    /// The same visibility slider the webview player honors.
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: Date?
    /// The card bytes as of the last sync or upload, so snapshots only
    /// travel when an in-game save actually changed them.
    @State private var lastCardData: Data?

    private var profile: ArcadeProfile {
        ArcadeProfileStore.shared.resolve(romId: rom.id, shortname: rom.fsNameNoExt)
    }

    private var canonicalSlug: String {
        rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
    }

    /// The platform this rom actually runs as, for shader storage/
    /// availability. Falls back to arcade's platform when resolution
    /// somehow fails (it never should have gotten this far otherwise,
    /// `NativeLauncher.prepare` already required a resolved platform to
    /// reach this screen at all), matching `core`'s own required-not-
    /// optional treatment upstream.
    private var platform: NativePlatform {
        NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) ?? .arcade
    }

    /// Matches PlayerView.controlLayout exactly: arcade resolves per game
    /// through the MAME profile map, everything else through the bundled
    /// per-platform file. This used to be arcade-only unconditionally,
    /// which was correct while FBNeo was the only native core, and wrong
    /// the moment Saturn joined it: every Saturn game got FBNeo's fallback
    /// arcade pad, Coin button included, since nothing here ever branched.
    private var controlLayout: ControlLayout {
        if rom.isArcade {
            return ArcadeLayout.build(for: profile)
        }
        // The six-button Genesis pad follows the Controller core setting,
        // the same lever that already tells the core which pad port 0
        // presents: with the setting on, the touch overlay finally grows
        // the X/Y/Z row and Mode that only physical controllers had.
        if NativeCoreOptionsStore.padDevice(for: platform) == NativePadDevice.sixButton,
           let sixButton = ControlLayout.named("genesis6") {
            return sixButton
        }
        // Same idea for PCE's Avenue Pad 6, but through a genuine core
        // variable rather than a controller-port device change, since
        // that is what pce_fast_default_joypad_type_p1 actually is.
        if (platform == .tg16 || platform == .tgCD),
           NativeCoreOptionsStore.value(NativeCoreOptions.pceJoypad, for: platform) == "6 Buttons",
           let sixButton = ControlLayout.named("pce6") {
            return sixButton
        }
        return ControlLayout.forPlatform(slug: canonicalSlug) ?? ArcadeLayout.build(for: .fallback)
    }

    private func layoutItems(landscape: Bool) -> [ControlLayout.Item] {
        controlLayout.items(landscape: landscape)
    }

    /// Matches PlayerView.controlStripHeight exactly: only arcade's vertical
    /// boards trade control height for canvas, everything else gets the
    /// flat height.
    private var controlStripHeight: CGFloat {
        rom.isArcade && profile.vertical ? 280 : 330
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
        captureMemoryCard()
    }

    /// Whether this session has a battery save to look after. Gated on the
    /// platform rather than probing the core: PCSX ReARMed is the only
    /// core whose wiring exports the memory API, and the pause path runs
    /// often enough that a cheap check matters.
    private var hasMemoryCard: Bool {
        platform == .psx
    }

    /// The launch-time decision of which card goes into the slot: a local
    /// copy still waiting to upload always wins (it is strictly newer than
    /// anything the server has), otherwise the server's card wins whenever
    /// its stamp moved since the last sync, covering saves made on another
    /// device. Offline, or with nothing on the server, whatever is on disk
    /// plays. A game with no card anywhere just starts with the core's
    /// own freshly formatted one.
    /// Whether a card image holds any actual saves: directory frames 1-15
    /// carry 0x51/0x52/0x53 in their first byte for in-use blocks, 0xA0
    /// for free ones (the PS1 memory card spec's block allocation states).
    /// A freshly formatted card that no game ever wrote must never outrank
    /// a real card from the server, which is exactly what happened when a
    /// quick native boot left an empty local card behind and blocked the
    /// adoption path below.
    private func cardHasSaves(_ card: Data) -> Bool {
        guard card.count == 128 * 1024 else { return false }
        return (1...15).contains { block in
            [0x51, 0x52, 0x53].contains(Int(card[128 * block]))
        }
    }

    private func syncMemoryCardIn() async {
        guard hasMemoryCard else { return }
        defer { renderer.awaitingSaveRAM = false }
        let store = MemoryCardStore.shared
        let local = store.localCard(romId: rom.id)
        let localUseful = local.map(cardHasSaves) ?? false

        if store.pendingUpload(romId: rom.id), let local, localUseful {
            renderer.pendingSaveRAM = local
            lastCardData = local
            DiagnosticsLog.record(
                context: "Memory card",
                message: "Using the local card; its upload is still pending.",
                romVersion: session.serverVersion
            )
            await uploadMemoryCard(local)
            return
        }

        if let saves = try? await session.saves(romId: rom.id) {
            let sorted = saves.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            let own = sorted.first { $0.emulator == core.emulatorTag }
            // A game with no Cabinet card worth keeping adopts the newest
            // card from anywhere else: a save uploaded through RomM's web
            // UI, a card brought over from another emulator. Only ever as
            // a seed when there is no local card holding real saves, and
            // only if the bytes verify as an actual card image with saves
            // on it. In-game saves after this fork into Cabinet's own row;
            // the original upload is never touched.
            let newest = own ?? (localUseful ? nil : sorted.first)
            if let newest, newest.updatedAt != store.serverStamp(romId: rom.id) || !localUseful {
                if let bytes = try? await session.saveContent(newest),
                   cardHasSaves(bytes) {
                    store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: newest.updatedAt)
                    renderer.pendingSaveRAM = bytes
                    lastCardData = bytes
                    DiagnosticsLog.record(
                        context: "Memory card",
                        message: "Loaded \(newest.fileName) from the server into the card slot.",
                        romVersion: session.serverVersion
                    )
                    return
                }
                DiagnosticsLog.record(
                    context: "Memory card",
                    message: "Found \(newest.fileName) on the server but its content did not verify as a card with saves.",
                    romVersion: session.serverVersion
                )
            }
        } else {
            DiagnosticsLog.record(
                context: "Memory card",
                message: "Could not list saves from the server; using what is on this phone.",
                romVersion: session.serverVersion
            )
        }

        if let local {
            renderer.pendingSaveRAM = local
            lastCardData = local
            DiagnosticsLog.record(
                context: "Memory card",
                message: localUseful ? "Using the local card." : "Using the local card; it holds no saves yet.",
                romVersion: session.serverVersion
            )
        }
    }

    /// Snapshots the card while the core is paused and, when it actually
    /// changed, writes it to disk first and then tries the upload. Runs on
    /// every pause, quit and background: cards are small and in-game saves
    /// are the one thing a player never expects to lose.
    private func captureMemoryCard() {
        guard hasMemoryCard, renderer.paused, let data = renderer.snapshotSaveRAM() else { return }
        guard data != lastCardData else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        Task { await uploadMemoryCard(data) }
    }

    private func uploadMemoryCard(_ data: Data) async {
        do {
            // The Cabinet marker keeps this row's filename distinct from
            // anything the web player made: RomM's overwrite matches rows
            // by filename alone, emulator tag not included (confirmed in
            // its saves endpoint source), so a bare "<name>.srm" upload
            // would silently take over and rewrite an existing EmulatorJS
            // card of the same name.
            try await session.uploadSave(
                romId: rom.id, emulator: core.emulatorTag,
                fileName: "\(rom.fsNameNoExt) (Cabinet).srm", saveData: data
            )
            // Re-list to learn the stamp the server just minted, so the
            // next launch recognises its own upload instead of pulling
            // it back down.
            let saves = (try? await session.saves(romId: rom.id)) ?? []
            let stamp = saves
                .filter { $0.emulator == core.emulatorTag }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                .first?.updatedAt
            MemoryCardStore.shared.markUploaded(romId: rom.id, serverStamp: stamp)
        } catch {
            // The disk copy and its pending flag survive; the next launch
            // retries. Same soft failure as the state queue.
        }
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
                            TouchControlPad(items: layoutItems(landscape: true), send: handleInput, system: controlLayout.system, opacity: controlOpacity)
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
                        TouchControlPad(items: layoutItems(landscape: false), send: handleInput, system: controlLayout.system, opacity: controlOpacity)
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
        // Tell the server this game is being played, exactly as the webview
        // player does: the heartbeat is presence, repeated as a liveness
        // signal. Without it a natively played game never reached Home's
        // resume list or RomM's own, since nothing else on the native path
        // ever tells the server a session happened. Unlike the webview
        // there is no gameStarted gate: by the time this screen exists the
        // game is loaded and running.
        .task {
            if startedAt == nil { startedAt = Date() }
            await syncMemoryCardIn()
            while !Task.isCancelled {
                await session.reportPlaying(romId: rom.id)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onAppear {
            // The manager is started here, not assumed started: before this
            // call the only screens that started it were the webview player,
            // Settings and the remap screen, so a fresh launch straight into
            // a native game left every controller silent.
            GameControllerManager.shared.start()
            // Same as the webview player: a running game is being watched
            // even when nothing touches the screen, and with a physical
            // controller nothing ever does. Without this the screen dims
            // and locks mid-game.
            UIApplication.shared.isIdleTimerDisabled = true
            previousControllerSend = GameControllerManager.shared.send
            previousControllerMenu = GameControllerManager.shared.onMenu
            previousControllerDisconnect = GameControllerManager.shared.onDisconnect
            GameControllerManager.shared.send = { [weak renderer] id, down in
                renderer?.setButton(id, down: down)
            }
            GameControllerManager.shared.onMenu = { openMenu() }
            // Nobody is holding anything after a disconnect, so pause into
            // the menu rather than letting the game run on unattended. Same
            // reasoning as the webview player's pauseGame on disconnect.
            GameControllerManager.shared.onDisconnect = { openMenu() }
            renderer.pendingState = initialState
            // Held before the first frame ever runs, so a PS1 game cannot
            // boot past its own card check while the card decision is
            // still in flight; syncMemoryCardIn releases it.
            renderer.awaitingSaveRAM = hasMemoryCard
            renderer.shader = NativeShader.current(for: platform)
            NativeSessionMarker.recordGameRunning(romId: rom.id)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            GameControllerManager.shared.send = previousControllerSend
            GameControllerManager.shared.onMenu = previousControllerMenu
            GameControllerManager.shared.onDisconnect = previousControllerDisconnect
            // The session POST is what stamps last played; the heartbeat
            // alone is not history. Handed to Session as a trackable task
            // so Home's refresh can wait for it instead of racing it.
            if let startedAt {
                session.reportPlaySessionEnded(romId: rom.id, start: startedAt, end: Date())
            }
            NativeSessionMarker.recordCleanExit()
            // An un-kept game's downloaded files have no life after the
            // session; a kept game's live elsewhere and survive this.
            NativeLauncher.cleanUpTempDirectories()
        }
        .onChange(of: scenePhase) { _, phase in
            // Eviction while backgrounded is iOS housekeeping, not a core
            // crash; the marker notes the difference so launch-time
            // settling only counts foreground deaths against the game.
            if phase == .background {
                NativeSessionMarker.recordBackgrounded()
                renderer.paused = true
                captureMemoryCard()
            } else if phase == .active && !menuVisible {
                renderer.paused = false
            }
        }
    }

    /// Matches PlayerView's pause menu exactly: same card (regularMaterial,
    /// 280pt wide, the same padding), same "Paused" subtitle, same icons,
    /// and the same order for the reason given there. Quit leads, in the
    /// spot a stray tap is cheapest; Resume trails, in the spot a reaching
    /// thumb naturally lands. The two players used to disagree on both the
    /// look and the order, which read as two different apps mid-session.
    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(rom.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let menuStatus {
                    Text(menuStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        Label("Quit", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Menu {
                        ForEach(NativeShader.available(for: platform)) { candidate in
                            Button {
                                renderer.shader = candidate
                                NativeShader.setCurrent(candidate, for: platform)
                            } label: {
                                if candidate == renderer.shader {
                                    Label(candidate.label, systemImage: "checkmark")
                                } else {
                                    Text(candidate.label)
                                }
                            }
                        }
                    } label: {
                        Label("Shader", systemImage: "camera.filters")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        saveState()
                    } label: {
                        Label("Save state", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        loadLatestState()
                    } label: {
                        Label("Load latest state", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        closeMenu()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: 280)
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .padding(40)
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

    /// A kept game writes locally before anything else, the one
    /// guarantee that matters: losing signal mid-save must never mean
    /// losing the save. A game played natively without being kept has
    /// no local directory to write into and never needed one, since
    /// native play without a connection was never possible for it in
    /// the first place, so it keeps the plain direct upload.
    private func saveState() {
        guard let state = LibretroFrontend.shared.serializeState() else {
            menuStatus = "The core produced no state to save."
            return
        }
        // Captured before the upload starts, while the pause menu still
        // holds the exact frame being saved. The webview player does the
        // same one frame before its pause for the same reason.
        let screenshot = renderer.screenshotPNG()
        let stem = stateFileStem()

        guard KeptGameStore.shared.kept(romId: rom.id) != nil else {
            menuBusy = true
            menuStatus = "Uploading\u{2026}"
            Task {
                do {
                    try await session.uploadState(
                        romId: rom.id, emulator: core.emulatorTag, fileName: "\(stem).state",
                        stateData: state, screenshotName: screenshot != nil ? "\(stem).png" : nil,
                        screenshotData: screenshot
                    )
                    menuStatus = "Saved to RomM."
                } catch {
                    menuStatus = error.localizedDescription
                }
                menuBusy = false
            }
            return
        }

        KeptGameStore.shared.queuePendingState(romId: rom.id, stem: stem, stateData: state, screenshotData: screenshot)
        menuBusy = true
        menuStatus = "Uploading\u{2026}"
        Task {
            await KeptGameStore.shared.syncPendingStates(session: session)
            // Queued means this exact save is still sitting locally,
            // whether this attempt never had a connection or the
            // upload itself failed; either way "waiting" is the honest
            // word, offline already explains itself.
            let stillQueued = KeptGameStore.shared.pendingStates(for: rom.id).contains { $0.stem == stem }
            menuStatus = stillQueued ? "Waiting for signal to upload." : "Saved to RomM."
            menuBusy = false
        }
    }

    /// Offline, or simply not reachable right now, falls back to
    /// whichever save is genuinely newest on the phone, the downloaded
    /// resume state or a still-queued local one. Online, the server
    /// stays the source of truth, since another device may have saved
    /// something Cabinet has not seen yet.
    private func loadLatestState() {
        guard KeptGameStore.shared.kept(romId: rom.id) != nil, NetworkMonitor.shared.isOffline else {
            menuBusy = true
            menuStatus = "Fetching\u{2026}"
            Task {
                do {
                    let states = try await session.states(romId: rom.id)
                        .filter { $0.emulator == core.emulatorTag }
                        .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                    guard let latest = states.first else {
                        menuStatus = "No states for this core on the server."
                        menuBusy = false
                        return
                    }
                    let bytes = try await session.stateContent(latest)
                    if LibretroFrontend.shared.unserializeState(bytes) {
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
            return
        }

        guard let bytes = KeptGameStore.shared.newestLocalState(for: rom.id) else {
            menuStatus = "No local state for this game yet."
            return
        }
        if LibretroFrontend.shared.unserializeState(bytes) {
            menuStatus = nil
            closeMenu()
        } else {
            menuStatus = "The core rejected that state. It was likely written by a different core build."
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
    private let frontend = LibretroFrontend.shared
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    /// One pipeline per shader, built once at attach so picking a shader in
    /// the pause menu is a dictionary lookup, not a recompile.
    private var pipelines: [NativeShader: MTLRenderPipelineState] = [:]
    /// Blits a raw RGB565 frame into `texture` on the GPU; see updateTexture.
    private var rgb565UnpackPipeline: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState!
    private var texture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    /// Raw packed-pixel source for the RGB565 GPU unpack path, r16Uint so
    /// no CPU-side interpretation happens before it reaches the shader.
    private var rgb565SourceTexture: MTLTexture?
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
            case .RGB565:
                unpackRGB565(base: base, width: width, height: height, srcStride: Int(frame.bytesPerRow))
            case .RGB1555:
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

    /// Uploads a raw RGB565 frame untouched into an r16Uint source texture,
    /// then runs one GPU render pass that decodes it straight into
    /// `texture` (bgra8Unorm), replacing the old per-pixel CPU loop. Falls
    /// back to leaving `texture` at its last contents if the pipeline
    /// failed to build, rather than crashing.
    private func unpackRGB565(base: UnsafeRawPointer, width: Int, height: Int, srcStride: Int) {
        guard let rgb565UnpackPipeline, let texture else { return }

        if rgb565SourceTexture == nil || rgb565SourceTexture?.width != width || rgb565SourceTexture?.height != height {
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

/// Feeds the core's audio batches into CoreAudio through a small ring
/// buffer, decoupling the core's variable per-frame sample count from the
/// fixed render callback AVAudioEngine expects.
private final class NativePlayerAudio {
    private let engine = AVAudioEngine()
    private var ringBuffer: [Int16] = []
    private let lock = NSLock()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let sampleRate = LibretroFrontend.shared.audioSampleRate()
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
