import SwiftUI
import MetalKit
import AVFoundation
import QuartzCore

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
    @State private var previousControllerSend: ((Int, Int, Bool) -> Void)?
    @State private var previousControllerStick: ((Int, Float, Float) -> Void)?
    @State private var previousControllerMenu: (() -> Void)?
    @State private var previousControllerDisconnect: ((Int) -> Void)?
    @State private var menuVisible = false
    @State private var menuStatus: String?
    @State private var menuBusy = false
    /// The same visibility slider the webview player honors.
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: Date?
    /// The battery-save engine, shared with tvOS's player: it owns the
    /// launch decision, the change detection and the uploads, this view
    /// only tells it when (pause, background, quit). Created in onAppear
    /// once the environment session exists.
    @State private var cardSync: MemoryCardSync?

    /// The cabinet's controls, read against the generation of MAME data
    /// that matches the core about to run them. On MAME 2003-Plus that
    /// means the driver's own listxml fills what the modern map never
    /// knew and trims buttons the driver cannot see; every other core,
    /// FBNeo included, resolves through the modern map exactly as before.
    private var profile: ArcadeProfile {
        ArcadeProfileStore.shared.resolve(
            romId: rom.id, shortname: rom.fsNameNoExt,
            using: core == .mame2003Plus ? .mame2003Plus : .modern
        )
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
    /// What the game's own driver says it wants in your hands, passed to
    /// the arcade layout builder only when the running core's mouse
    /// channel is wired (MAME 2003-Plus today). Nil keeps every other
    /// core's layouts byte-identical.
    private var analogControls: AnalogControls? {
        guard core == .mame2003Plus else { return nil }
        return AnalogControls.controls(forShortname: rom.fsNameNoExt)
    }

    private var controlLayout: ControlLayout {
        if rom.isArcade {
            return ArcadeLayout.build(for: profile, analog: analogControls)
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

    private func handleRelative(_ dx: Int, _ dy: Int) {
        LibretroFrontend.shared.addMouseDeltaX(dx, y: dy, port: 0)
    }

    private func handleOffscreen(_ offscreen: Bool) {
        LibretroFrontend.shared.setLightgunOffscreen(offscreen, port: 0)
    }

    private func handlePointer(_ x: Double, _ y: Double, _ down: Bool) {
        LibretroFrontend.shared.setPointerX(Float(x), y: Float(y), down: down, port: 0)
    }

    private func handleInput(_ id: Int, down: Bool) {
        if id == RetroPad.overlay {
            if down { openMenu() }
            return
        }
        // Touch is always player 1: there is deliberately no second-player
        // touch layout, so port 0 is the only port the overlay ever drives.
        renderer.setButton(id, down: down, port: 0)
    }

    /// `ids` is unused here on purpose: it exists for the webview player's
    /// per-slot EmulatorJS wiring (see ControlLayout.Item's own doc
    /// comment), but this app has exactly one native stick, Dreamcast's,
    /// and LibretroFrontend already knows which analog index it is.
    private func handleStick(_ ids: [Int], x: Double, y: Double) {
        renderer.setStick(x: x, y: y, port: 0)
    }

    private func openMenu() {
        renderer.paused = true
        menuStatus = nil
        menuVisible = true
        syncEngine().capturePauseSnapshot()
    }

    /// Whether boot must hold for the launch card decision: every
    /// platform whose saves ride RETRO_MEMORY_SAVE_RAM, the list (and
    /// each exclusion's reason) living on the platform itself. The save
    /// logic itself lives in MemoryCardSync, shared with tvOS.
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

    private func closeMenu() {
        menuVisible = false
        renderer.paused = false
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let showsControls = !controllers.isConnected
            // A gun cabinet aims at the picture, so its pad has to reach
            // the picture. In portrait the pad is normally a bottom strip
            // that cannot, which left gun games with no aim at all there.
            // They take the full-screen presentation in both orientations.
            let gunPanel = controlLayout.items.contains { $0.kind == .gun }

            ZStack {
                if isLandscape || !showsControls || gunPanel {
                    // Full screen canvas, pad in the gutters (or hidden with a
                    // controller connected), matching PlayerView's .overlay case.
                    ZStack {
                        MetalGameView(renderer: renderer)
                        if showsControls {
                            TouchControlPad(items: layoutItems(landscape: isLandscape), send: handleInput, sendStick: handleStick, sendRelative: handleRelative, sendPointer: handlePointer, sendOffscreen: handleOffscreen, pictureAspect: renderer.displayAspect, system: controlLayout.system, opacity: controlOpacity)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black)
                } else {
                    // Portrait: the pad's items are normalised against a
                    // bottom strip, not the full screen, so the canvas keeps
                    // exactly the height it always has, matching PlayerView's
                    // .bottomStrip case exactly, same strip height. The
                    // canvas stays below the top safe area so the island
                    // never eats the picture.
                    //
                    // The pad itself can be taller than the strip it is
                    // normalised against: `headroom` (zero for every layout
                    // that does not ask for it, so this reproduces the old
                    // plain split pixel for pixel) grows the pad upward from
                    // the bottom edge to overlap the canvas's own last bit,
                    // for a pad too crowded to fit the strip alone. Opacity
                    // keeps the overlap legible, the same deal landscape
                    // already makes everywhere.
                    let padHeight = controlStripHeight * (1 + (controlLayout.headroom ?? 0))
                    ZStack(alignment: .top) {
                        MetalGameView(renderer: renderer)
                            .frame(height: max(geometry.size.height - controlStripHeight, 0))
                        TouchControlPad(items: layoutItems(landscape: false), send: handleInput, sendStick: handleStick, sendRelative: handleRelative, sendPointer: handlePointer, sendOffscreen: handleOffscreen, pictureAspect: renderer.displayAspect, system: controlLayout.system, opacity: controlOpacity)
                            .frame(height: padHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
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
            await syncEngine().syncIn()
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
            // N64 needs its own base bindings; see ControllerBindings.n64.
            GameControllerManager.shared.activePlatform = platform.rawValue
            // Same as the webview player: a running game is being watched
            // even when nothing touches the screen, and with a physical
            // controller nothing ever does. Without this the screen dims
            // and locks mid-game.
            UIApplication.shared.isIdleTimerDisabled = true
            previousControllerSend = GameControllerManager.shared.send
            previousControllerStick = GameControllerManager.shared.sendStick
            previousControllerMenu = GameControllerManager.shared.onMenu
            previousControllerDisconnect = GameControllerManager.shared.onDisconnect
            GameControllerManager.shared.send = { [weak renderer] player, id, down in
                renderer?.setButton(id, down: down, port: player)
            }
            // The continuous form, alongside the digitized d-pad bits
            // .send already carries: N64 and Dreamcast read this. FBNeo
            // also asks for it (a "fake analog" fallback in its own input
            // code) and is deliberately refused in LibretroFrontend's
            // inputState; see the comment there and cabinet#3.
            GameControllerManager.shared.sendStick = { [weak renderer] player, x, y in
                renderer?.setStick(x: Double(x), y: Double(y), port: player)
            }
            GameControllerManager.shared.onMenu = { openMenu() }
            // Nobody is holding anything after a disconnect, so pause into
            // the menu rather than letting the game run on unattended. Same
            // reasoning as the webview player's pauseGame on disconnect.
            // Player 1 losing their pad stops the game, since the person
            // who can drive the menu is now holding nothing. Player 2
            // dropping leaves player 1 playing: pausing on them would
            // interrupt a game the remaining player can still control.
            GameControllerManager.shared.onDisconnect = { player in
                if player == 0 { openMenu() }
            }
            renderer.pendingState = initialState
            // Held before the first frame ever runs, so a PS1 game cannot
            // boot past its own card check while the card decision is
            // still in flight; syncMemoryCardIn releases it.
            renderer.awaitingSaveRAM = hasMemoryCard
            renderer.shader = NativeShader.current(for: platform)
            // The game's own translucent screen sheet, Vectrex only;
            // nil (no sheet, toggle off, or any other platform) draws
            // nothing and costs nothing. See VectrexOverlays.swift.
            if platform == .vectrex {
                renderer.overlayImage = VectrexOverlays.image(md5: rom.md5Hash, name: rom.fsNameNoExt)
            }
            NativeSessionMarker.recordGameRunning(romId: rom.id)
            // Temporary, for issue #6. One file per play session, so there
            // is never a question which run the numbers came from.
            FrameTrace.shared.begin(core: "\(core)")
        }
        .onDisappear {
            FrameTrace.shared.end()
            UIApplication.shared.isIdleTimerDisabled = false
            // Guarded: if another game's view already claimed the
            // platform (lifecycle interleave), its claim stands.
            if GameControllerManager.shared.activePlatform == platform.rawValue {
                GameControllerManager.shared.activePlatform = nil
            }
            GameControllerManager.shared.send = previousControllerSend
            GameControllerManager.shared.sendStick = previousControllerStick
            GameControllerManager.shared.onMenu = previousControllerMenu
            GameControllerManager.shared.onDisconnect = previousControllerDisconnect
            // The session POST is what stamps last played; the heartbeat
            // alone is not history. Handed to Session as a trackable task
            // so Home's refresh can wait for it instead of racing it.
            if let startedAt {
                session.reportPlaySessionEnded(romId: rom.id, start: startedAt, end: Date())
            }
            // The core gets a real shutdown at quit, the way RetroArch
            // closes content, instead of lingering loaded until the next
            // launch's lazy teardown: retro_unload_game is the one moment
            // file-writing cores flush their saves (Sega CD's bram_save,
            // Neo Geo Pocket's flash_commit, FBNeo's NVRAM and high
            // scores), and the lazy unload used to fire after the
            // directory those flushes wrote into was already deleted.
            // Runs after the pause capture above has already snapshotted
            // memory-API save RAM, mirroring RetroArch's own close order
            // (SRAM save, then core_unload_game). Safe against the draw
            // loop: runFrame and the snapshot methods all guard on the
            // loaded flag this clears.
            LibretroFrontend.shared.unloadGame()
            syncEngine().captureAfterShutdown()
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
                syncEngine().capturePauseSnapshot()
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

// MetalGameView and NativePlayerRenderer now live in their own file,
// Native/NativePlayerRenderer.swift, shared with tvOS's PS1PlayTestView
// rather than duplicated for it.

// NativePlayerAudio now lives in its own file, Native/NativePlayerAudio.swift,
// shared with tvOS's PS1PlayTestView rather than duplicated for it.

