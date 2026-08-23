#if os(tvOS)
import SwiftUI
import MetalKit
import GameController

/// tvOS's real play screen, the sibling of iOS's `NativePlayerView`.
///
/// Same feature set as iOS: save state, load latest state, shader picker,
/// memory card (PS1/N64) and VMU (Dreamcast) capture and sync, all reusing
/// the exact same underlying calls (`LibretroFrontend`, `MemoryCardStore`,
/// `KeptGameStore`, `session.uploadState`/`uploadSave`) iOS's pause menu
/// already drives. Only the surface is different: a remote-navigable glass
/// menu sized for a TV instead of a touch-friendly sheet, and no touch
/// overlay at all, since there is nothing to touch on a TV and a controller
/// is required to reach this screen in the first place.
///
/// `NativeLauncher.prepare` has already activated the core and loaded the
/// game before this appears, same contract as iOS's screen. Reuses
/// `NativePlayerRenderer` exactly as-is, the shared render pipeline both
/// platforms have carried since the tvOS PS1 go/no-go spike.
struct TVPlayerView: View {
    let rom: Rom
    let core: NativeCore
    var initialState: Data?

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var renderer = NativePlayerRenderer()
    @ObservedObject private var controllers = GameControllerManager.shared

    @State private var previousSend: ((Int, Int, Bool) -> Void)?
    @State private var previousStick: ((Int, Float, Float) -> Void)?
    @State private var previousMenu: (() -> Void)?
    @State private var previousDisconnect: ((Int) -> Void)?

    @State private var menuVisible = false
    @AppStorage(BiasGlowLevel.storageKey) private var glowStored = BiasGlowLevel.subtle.rawValue
    @State private var menuStatus: String?
    @State private var menuBusy = false
    @State private var startedAt: Date?
    /// The battery-save engine shared with iOS's player
    /// (MemoryCardSync): it owns the launch decision, change detection,
    /// region handling and uploads; this view only tells it when
    /// (pause, background, quit). Replaces this file's own stale copy of
    /// that logic, which had silently fallen behind iOS at PS1/N64-only
    /// while iOS grew every platform (issue #5).
    @State private var cardSync: MemoryCardSync?
    /// The phone as a controller: while an arcade game runs and the
    /// Settings switch allows it, a paired phone can drive this game
    /// through the exact calls the local controller path makes below.
    /// Pairing, per-packet proof and the rest of the design live in
    /// ControllerLink.swift and ControllerPairing.swift; this view
    /// only wires verbs to the renderer and shows the pairing code.
    @State private var phoneLink: ControllerLinkReceiver?
    @State private var phoneConnected = false
    /// Paused from the phone's own menu, tracked so the idle rule below
    /// can tell a live phone game from one sitting in a pause screen.
    @State private var phonePaused = false
    /// The Settings switch. Read at launch: while it is off, no listener
    /// is created and no socket exists, which is the design's step one.
    /// Flipping it mid-game takes effect at the next launch, and the
    /// switch cannot be reached mid-game anyway.
    @AppStorage(ControllerPairing.allowKey) private var allowPhoneController = false
    /// The pairing code an unknown phone is being shown, or nil. An
    /// overlay in a corner, deliberately not a pause: someone standing
    /// in the room wanting to join is not a reason to stop somebody
    /// else's run.
    @State private var pairingCode: String?

    private var canonicalSlug: String {
        rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
    }

    /// The platform this rom actually runs as, for shader storage/
    /// availability. Falls back to arcade's platform when resolution
    /// somehow fails, matching `core`'s own required-not-optional
    /// treatment upstream, same as `NativePlayerView`.
    private var platform: NativePlatform {
        NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) ?? .arcade
    }

    private var glowLevel: BiasGlowLevel {
        BiasGlowLevel.level(fromStored: glowStored)
    }

    /// Whether boot must hold for the launch card decision: every
    /// platform whose saves ride RETRO_MEMORY_SAVE_RAM, matching iOS
    /// exactly now that both players share MemoryCardSync.
    private var hasMemoryCard: Bool {
        platform.savesOverSaveRAM
    }

    /// The engine, created on first use rather than in a specific
    /// lifecycle callback: .task and .onAppear have no guaranteed order,
    /// and whichever asks first should not find nil.
    private func syncEngine() -> MemoryCardSync {
        if let cardSync { return cardSync }
        let engine = MemoryCardSync(
            rom: rom, core: core, platform: platform, session: session, renderer: renderer
        )
        cardSync = engine
        return engine
    }

    private func updatePhoneIdleRule() {
        UIApplication.shared.isIdleTimerDisabled =
            phoneConnected && !phonePaused && !menuVisible
    }

    /// The corner card an unknown phone earns: the code, big enough to
    /// read from a couch, in the same monospaced style PairingView
    /// gives the RomM device code, because to the person in the room it
    /// is the same gesture. The game keeps running underneath. Liquid
    /// Glass on tvOS 26 with the flat material fallback, the same
    /// pattern as the pause menu and every other card in the app.
    private func pairingOverlay(code: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Phone controller")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(spacedPairingCode(code))
                .font(.system(size: 64, weight: .bold, design: .monospaced))
            Text("Enter this code on the phone")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .background {
            if #available(tvOS 26.0, *) {
                RoundedRectangle(cornerRadius: 32)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
            } else {
                RoundedRectangle(cornerRadius: 32).fill(.regularMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(60)
        .transition(.opacity)
    }

    /// "417209" reads better as "417 209".
    private func spacedPairingCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    private func openMenu() {
        renderer.paused = true
        menuStatus = nil
        menuVisible = true
        syncEngine().capturePauseSnapshot()
    }

    private func closeMenu() {
        menuVisible = false
        renderer.paused = false
    }

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

    /// Identical to `NativePlayerView.saveState`: a kept game writes
    /// locally first, an un-kept one uploads directly.
    private func saveState() {
        guard let state = LibretroFrontend.shared.serializeState() else {
            menuStatus = "The core produced no state to save."
            return
        }
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
            let stillQueued = KeptGameStore.shared.pendingStates(for: rom.id).contains { $0.stem == stem }
            menuStatus = stillQueued ? "Waiting for signal to upload." : "Saved to RomM."
            menuBusy = false
        }
    }

    /// Identical to `NativePlayerView.loadLatestState`: offline falls
    /// back to the newest local state, online the server stays the
    /// source of truth.
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

    var body: some View {
        ZStack {
            TVGameSurface(renderer: renderer, menuVisible: menuVisible)
                .ignoresSafeArea()
            TVBiasGlow(renderer: renderer, level: glowLevel)
            if let pairingCode {
                pairingOverlay(code: pairingCode)
            }
            if menuVisible {
                pauseMenu
            }
        }
        // Without this, tvOS's system exit gesture (the remote's Menu
        // swipe, and by the focus engine's own convention a physical
        // controller's B button) falls through to its default action on
        // any view that doesn't claim it: dismissing this whole screen.
        // That bypassed the entire pause menu, Quit confirmation
        // included, on a single accidental B press while paused, found
        // on device 2026-08-13. Claiming it here makes exit do nothing at
        // all, in or out of the pause menu: Resume is the only way to
        // close the menu, found on device 2026-08-15 to also fire from
        // inside the Shader/Glow dropdowns and resume the game
        // unconfirmed, the same shape of accident the first fix closed
        // for the top level.
        .onExitCommand {}
        .task {
            if startedAt == nil { startedAt = Date() }
            await syncEngine().syncIn()
            while !Task.isCancelled {
                await session.reportPlaying(romId: rom.id)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onAppear {
            // Without this nothing is ever discovered and no handlers
            // are installed, so the pad reaches the core not at all,
            // while still driving menus perfectly (that is the focus
            // engine, which needs no app code). Exactly the shape of
            // "works in the menus, dead in game" seen on real hardware
            // 2026-08-11. Idempotent, guarded by its own `started` flag,
            // so calling it on every launch is free.
            controllers.start()
            // Claim Menu for the duration of the game only. Outside a
            // game the system needs it for back navigation; see
            // GameControllerManager.capturesMenuButton.
            controllers.capturesMenuButton = true
            // N64 needs its own base bindings; see ControllerBindings.n64.
            controllers.activePlatform = platform.rawValue
            previousSend = controllers.send
            previousStick = controllers.sendStick
            previousMenu = controllers.onMenu
            previousDisconnect = controllers.onDisconnect
            controllers.send = { [weak renderer] player, id, down in
                renderer?.setButton(id, down: down, port: player)
            }
            controllers.sendStick = { [weak renderer] player, x, y in
                renderer?.setStick(x: Double(x), y: Double(y), port: player)
            }
            // Menu opens the pause menu now, not the player itself: Quit
            // is its own explicit button inside the menu. Before this,
            // Menu was wired straight to dismiss(), so pressing it always
            // exited the game outright with no way to save, load, or
            // change shaders first.
            controllers.onMenu = { openMenu() }
            // Same reasoning as iOS: nobody is holding anything after a
            // disconnect, so pause into the menu rather than letting the
            // game run on unattended.
            controllers.onDisconnect = { player in
                if player == 0 { openMenu() }
            }
            renderer.pendingState = initialState
            renderer.awaitingSaveRAM = hasMemoryCard
            renderer.shader = NativeShader.current(for: platform)
            // The game's own translucent screen sheet, Vectrex only,
            // same line the iOS player runs: the store and renderer
            // layer are shared, only this assignment is per platform.
            if platform == .vectrex {
                renderer.overlayImage = VectrexOverlays.image(md5: rom.md5Hash, name: rom.fsNameNoExt)
            }
            NativeSessionMarker.recordGameRunning(romId: rom.id)
            // Temporary, for issue #6, the same two calls the iOS player
            // makes: one trace file per play session, pulled off the
            // device afterwards. The recording itself lives in the shared
            // renderer, so without these the trace simply never starts.
            FrameTrace.shared.begin(core: "\(core)")
            if platform == .arcade, allowPhoneController {
                let link = ControllerLinkReceiver(
                    shortname: rom.fsNameNoExt.lowercased(),
                    onButton: { [weak renderer] id, down in
                        renderer?.setButton(id, down: down, port: 0)
                    },
                    onStick: { [weak renderer] x, y in
                        renderer?.setStick(x: x, y: y, port: 0)
                    },
                    onRelative: { dx, dy in
                        LibretroFrontend.shared.addMouseDeltaX(dx, y: dy, port: 0)
                    },
                    onPointer: { x, y, down in
                        LibretroFrontend.shared.setPointerX(Float(x), y: Float(y), down: down, port: 0)
                    },
                    onOffscreen: { off in
                        LibretroFrontend.shared.setLightgunOffscreen(off, port: 0)
                    },
                    // The phone's own pause menu, deliberately smaller
                    // than this screen's: pause, save, load, put away.
                    // Save and load are the SAME functions this view's
                    // menu runs, so the states land in the same slots
                    // with the same upload path, and pause captures the
                    // battery-save snapshot exactly like openMenu does.
                    onPause: { paused in
                        Task { @MainActor in
                            renderer.paused = paused
                            phonePaused = paused
                            if paused { syncEngine().capturePauseSnapshot() }
                        }
                    },
                    onSave: {
                        Task { @MainActor in saveState() }
                    },
                    onLoad: {
                        Task { @MainActor in loadLatestState() }
                    },
                    onPhone: { joined in
                        Task { @MainActor in phoneConnected = joined }
                    },
                    onPairingCode: { code in
                        Task { @MainActor in
                            withAnimation(.easeInOut(duration: 0.25)) { pairingCode = code }
                        }
                    },
                    // A dropped phone is a disconnected controller:
                    // nobody is holding anything, so pause into the
                    // menu, the same reaction the Bluetooth path has
                    // always had. A goodbye never lands here.
                    onDrop: {
                        Task { @MainActor in
                            phonePaused = false
                            openMenu()
                        }
                    }
                )
                link.start()
                phoneLink = link
            }
        }
        // The screensaver rule for a phone-driven game. A physical
        // controller keeps tvOS awake through its own button presses;
        // the phone's input is network packets the system cannot see,
        // so the aerial rolled over a live game of Off Road. Awake only
        // while a phone is connected AND the game is actually running:
        // a pause screen is deliberately allowed to idle into the
        // screensaver, because a frozen frame that sits for hours is
        // how OLEDs get burned and Marcus would rather the aerial than
        // the complaint.
        .onChange(of: phoneConnected) { _, _ in updatePhoneIdleRule() }
        .onChange(of: phonePaused) { _, _ in updatePhoneIdleRule() }
        .onChange(of: menuVisible) { _, _ in updatePhoneIdleRule() }
        .onDisappear {
            phoneLink?.stop()
            phoneLink = nil
            UIApplication.shared.isIdleTimerDisabled = false
            FrameTrace.shared.end()
            controllers.capturesMenuButton = false
            // Guarded: if another game's view already claimed the
            // platform (lifecycle interleave), its claim stands.
            if controllers.activePlatform == platform.rawValue {
                controllers.activePlatform = nil
            }
            controllers.send = previousSend
            controllers.sendStick = previousStick
            controllers.onMenu = previousMenu
            controllers.onDisconnect = previousDisconnect
            if let startedAt {
                session.reportPlaySessionEnded(romId: rom.id, start: startedAt, end: Date())
            }
            // The same quit-time core shutdown iOS does, for the same
            // reason: retro_unload_game is the one moment the
            // file-writing cores (Sega CD, Neo Geo Pocket) flush their
            // saves, and the pause capture above has already snapshotted
            // memory-API save RAM, matching RetroArch's own close order.
            LibretroFrontend.shared.unloadGame()
            syncEngine().captureAfterShutdown()
            NativeSessionMarker.recordCleanExit()
            NativeLauncher.cleanUpTempDirectories()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                NativeSessionMarker.recordBackgrounded()
                renderer.paused = true
                syncEngine().capturePauseSnapshot()
            } else if phase == .active && !menuVisible {
                renderer.paused = false
            }
        }
    }

    /// Same content and order as iOS's pause menu (Quit, Shader, Save
    /// state, Load latest state, Resume, in that order for the same
    /// reason given there), sized and styled for a TV: bigger targets,
    /// real Liquid Glass instead of `.bordered`/`.regularMaterial`, and
    /// remote-navigable, since `TVGameSurface` hands focus back to the
    /// system while this is showing.
    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text(rom.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text("Paused")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let menuStatus {
                    Text(menuStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 16) {
                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        Label("Quit", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TVPauseMenuButtonStyle())

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
                    }
                    .buttonStyle(TVPauseMenuButtonStyle())

                    // Landed on Off/Subtle/Strong after live-tuning with
                    // a slider on device 2026-08-13; the slider found
                    // the real numbers, a plain picker is all that's
                    // needed to ship them.
                    Menu {
                        ForEach(BiasGlowLevel.allCases) { candidate in
                            Button {
                                glowStored = candidate.rawValue
                            } label: {
                                if candidate == glowLevel {
                                    Label(candidate.label, systemImage: "checkmark")
                                } else {
                                    Text(candidate.label)
                                }
                            }
                        }
                    } label: {
                        Label("Glow", systemImage: "rays")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TVPauseMenuButtonStyle())

                    Button {
                        saveState()
                    } label: {
                        Label("Save state", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TVPauseMenuButtonStyle())

                    Button {
                        loadLatestState()
                    } label: {
                        Label("Load latest state", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TVPauseMenuButtonStyle())

                    Button {
                        closeMenu()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TVPauseMenuButtonStyle(prominent: true))
                }
            }
            .frame(maxWidth: 560)
            .padding(40)
            .background {
                if #available(tvOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(.clear)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
                } else {
                    RoundedRectangle(cornerRadius: 32).fill(.regularMaterial)
                }
            }
            .disabled(menuBusy)
        }
    }
}

/// A full-width, TV-sized button for the pause menu's own buttons, glass
/// on tvOS 26 the same way the library switcher and save-state picker
/// are, distinguishing "Resume" (prominent, filled) from everything else
/// the same way iOS's `.borderedProminent` vs `.bordered` did.
private struct TVPauseMenuButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration, prominent: prominent)
    }

    private struct FocusBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(.title3.weight(.semibold))
                .padding(.vertical, 16)
                .padding(.horizontal, 24)
                .background {
                    if #available(tvOS 26.0, *) {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(.clear)
                            .glassEffect(
                                prominent
                                    ? .regular.tint(.accentColor.opacity(isFocused ? 0.85 : 0.55))
                                    : (isFocused ? .regular.tint(.white.opacity(0.25)) : .regular),
                                in: RoundedRectangle(cornerRadius: 18)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.white.opacity(isFocused ? 0.18 : 0.1)))
                    }
                }
                .scaleEffect(isFocused ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// The Metal surface, hosted inside a `GCEventViewController` rather than a
/// plain `UIViewRepresentable`, which is the entire point of this type.
///
/// tvOS routes controller input through the UIKit focus engine by default,
/// and this app opts into that at the Info.plist level
/// (GCSupportsControllerUserInteraction) because it is exactly what Home
/// and the library want: a real pad drives focus and selection with no
/// per-screen code. In a running game it is precisely wrong. The focus
/// engine keeps consuming presses for navigation, so B reads as "go back"
/// and dismisses the player instead of reaching the core as a face button
/// (reported on real hardware 2026-08-11: "controllers work on the
/// homescreen but in game b exits the game").
///
/// `controllerUserInteractionEnabled = false` is the documented way for a
/// game to take the pad exclusively for as long as this controller is on
/// screen. `menuVisible` flips that back on for as long as the pause menu
/// is showing, since Save/Load/Shader/Quit/Resume need the same focus-
/// engine navigation Home and Library already get, not raw button
/// presses reaching a core that is paused anyway.
private struct TVGameSurface: UIViewControllerRepresentable {
    let renderer: NativePlayerRenderer
    let menuVisible: Bool

    func makeUIViewController(context: Context) -> GCEventViewController {
        let controller = GCEventViewController()
        controller.controllerUserInteractionEnabled = menuVisible

        let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        metalView.delegate = renderer
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        // Deliberately the default three drawables. Two was tried for
        // latency and measured on this very device (2026-08-20,
        // FrameTrace): the hardware-rendered cores locked to every other
        // vsync, N64 presenting at 30 instead of 50. See the matching
        // comment in NativePlayerRenderer.swift for the numbers.
        metalView.translatesAutoresizingMaskIntoConstraints = false

        controller.view.backgroundColor = .black
        controller.view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])

        renderer.attach(to: metalView)
        return controller
    }

    func updateUIViewController(_ controller: GCEventViewController, context: Context) {
        controller.controllerUserInteractionEnabled = menuVisible
    }
}
#endif
