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
    /// Whether a television is showing the picture. See ExternalDisplay.swift.
    @ObservedObject private var external = ExternalDisplay.shared
    @State private var previousControllerSend: ((Int, Int, Bool) -> Void)?
    @State private var previousControllerStick: ((Int, Float, Float) -> Void)?
    @State private var previousControllerMenu: (() -> Void)?
    @State private var previousControllerDisconnect: ((Int) -> Void)?
    @State private var menuVisible = false
    #if targetEnvironment(macCatalyst)
    @AppStorage(BiasGlowLevel.storageKey) private var macGlowStored = BiasGlowLevel.subtle.rawValue
    /// The phone-as-controller receiver, the Mac's half of the same
    /// feature the television has. Bounded by this view's lifetime, so
    /// the socket exists exactly while a game does.
    @AppStorage(ControllerPairing.allowKey) private var macAllowPhoneController = false
    @State private var macPhoneLink: ControllerLinkReceiver?
    /// The code a phone asking to join has to be told. Shown over the
    /// game the way the television shows it, because whoever is asking
    /// is holding the phone and cannot go and look in Settings.
    @State private var macPairingCode: String?
    /// Which row of the Mac pause panel a pad or a phone is pointing at.
    /// The panel is mouse-and-keyboard everywhere else; this is what
    /// makes it usable by whoever is actually holding the controller.
    @State private var macMenuSelection = 0
    /// Whether the panel is being driven by a pad or a phone rather than
    /// the pointer, which is what decides if a selection ring is drawn.
    @State private var macMenuUsingController = false
    /// The DS bottom screen served to a joined phone, exactly as the
    /// television serves it.
    @State private var macVideoServer: DSVideoServer?
    #endif
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
        // Tap-the-artwork games keep only Menu, synthesized here rather
        // than filtered from gw.json: that file's portrait items are
        // strip-normalised and this presentation is full screen, so the
        // pill needs coordinates in this space, one corner, small.
        if platform == .gameAndWatch {
            return [ControlLayout.Item(
                kind: .pill, label: "Menu", input: -1, inputs: nil,
                frame: ControlLayout.Rect(x: 0.03, y: 0.015, w: 0.14, h: 0.042),
                extended: ControlLayout.Rect(x: 0.01, y: 0.005, w: 0.18, h: 0.062),
                fourWay: nil, sensitivity: nil)]
        }
        return controlLayout.items(landscape: landscape)
    }

    /// The tap-the-artwork map for a Game & Watch game, when the
    /// extractor mapped this one. Nil means the game fell back to the
    /// small pad in gw.json, which stays the honest fallback.
    private var gwSpec: GWHotspots? {
        platform == .gameAndWatch ? GWHotspots.spec(for: rom.fsName) : nil
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
        // gw-libretro reads its pointer on port 2, stated in its own
        // controller_info; everything else that takes a pointer here
        // (melonDS's touchscreen, the arcade guns) reads port 0.
        let port = platform == .gameAndWatch ? 2 : 0
        LibretroFrontend.shared.setPointerX(Float(x), y: Float(y), down: down, port: port)
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
        // Say so on the television, which is still showing the frozen
        // frame. Harmless with no television attached.
        ExternalDisplay.shared.isPaused = true
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
        ExternalDisplay.shared.isPaused = false
    }

    /// Runs its content edge to edge on the Mac and unchanged elsewhere.
    @ViewBuilder
    private func macFullBleed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content().ignoresSafeArea()
        #else
        content()
        #endif
    }

    var body: some View {
        // The GeometryReader has to be told, not the chain below it.
        //
        // Catalyst reports a 52 point top safe area on the Mac even when
        // the window covers the whole screen and has no titlebar left,
        // measured rather than assumed. That inset sizes this reader, so
        // the picture is laid out 52 points down while the black
        // background behind it already ignores the inset, and the gap
        // between the two is the band across the top of a game. Ignoring
        // the safe area further down the chain is too late: by then this
        // reader has already been given the smaller height.
        macFullBleed {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            #if targetEnvironment(macCatalyst)
            // The Mac never draws the touch overlay: pads are the way
            // games are played here, the pointer serves DS, Game &
            // Watch and the tap games through their own views below,
            // and Escape opens the pause menu. Settled input model,
            // Marcus 2026-08-30.
            let showsControls = false
            #else
            let showsControls = !controllers.isConnected
            #endif
            // A gun cabinet aims at the picture, so its pad has to reach
            // the picture. In portrait the pad is normally a bottom strip
            // that cannot, which left gun games with no aim at all there.
            // They take the full-screen presentation in both orientations.
            let gunPanel = controlLayout.items.contains { $0.kind == .gun }

            ZStack {
                if isLandscape || !showsControls || gunPanel || platform == .gameAndWatch {
                    // Full screen canvas, pad in the gutters (or hidden with a
                    // controller connected), matching PlayerView's .overlay case.
                    ZStack {
                        // Exactly one MTKView may hold this renderer at a
                        // time. Two would run two draw loops and advance
                        // the core twice a frame, so when the television
                        // has the picture the phone draws none.
                        if !external.showsGameExternally {
                            MetalGameView(renderer: renderer)
                            #if targetEnvironment(macCatalyst)
                            // The TV's letterbox glow, kept on the Mac
                            // for the same reason it exists at all: a
                            // big panel's dead space around a 4:3
                            // picture. Same setting, same key, so the
                            // TV and the Mac agree.
                            TVBiasGlow(renderer: renderer, level: BiasGlowLevel.level(fromStored: macGlowStored))
                            #endif
                            if core == .melonDS {
                                DSTouchScreenView(sendPointer: handlePointer)
                            }
                            // The artwork's own buttons are the pad; see
                            // GWHotspots. Under the control pad so the
                            // Menu pill still wins its corner.
                            if let spec = gwSpec {
                                GWTapView(spec: spec, send: handleInput,
                                          displayAspect: { renderer.displayAspect })
                            } else if platform == .gameAndWatch {
                                // The Lua simulators read the pointer and
                                // match their own declared tap zones, so
                                // there is nothing to extract and nothing
                                // to maintain: hand the tap over and the
                                // game does the rest. Any Lua game added
                                // later works with no tool run.
                                GWPointerView(send: handlePointer,
                                              displayAspect: { renderer.displayAspect })
                            }
                        }
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
                        if !external.showsGameExternally {
                            ZStack {
                                MetalGameView(renderer: renderer)
                                if core == .melonDS {
                                    DSTouchScreenView(sendPointer: handlePointer)
                                }
                            }
                            .frame(height: max(geometry.size.height - controlStripHeight, 0))
                        }
                        // Moulded in portrait, where the controls sit on
                        // their own strip below the picture rather than
                        // over it, so an opaque control hides nothing.
                        // The visibility slider still works: it is the
                        // pad view's own alpha, so a moulded control
                        // fades as a whole and keeps its depth on the
                        // way down. Landscape deliberately stays flat,
                        // Marcus's call: there the controls flank a
                        // centred picture, and a wide game or a rotated
                        // arcade board shrinks those gutters until they
                        // really are sitting on it.
                        TouchControlPad(items: layoutItems(landscape: false), send: handleInput, sendStick: handleStick, sendRelative: handleRelative, sendPointer: handlePointer, sendOffscreen: handleOffscreen, pictureAspect: renderer.displayAspect, system: controlLayout.system, material: RaisedControls.isOn, opacity: controlOpacity)
                            .frame(height: padHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if menuVisible {
                    #if targetEnvironment(macCatalyst)
                    macPauseMenu
                    #else
                    pauseMenu
                    #endif
                }
                #if targetEnvironment(macCatalyst)
                if let macPairingCode {
                    macPairingOverlay(code: macPairingCode)
                }
                #endif
            }
            #if targetEnvironment(macCatalyst)
            // Escape is the Mac's pause affordance with no pad in
            // hand: app control, not game input, so it lives outside
            // the keyboard-never-plays rule.
            .onKeyPress(.escape) {
                if !menuVisible { openMenu() }
                return .handled
            }
            #endif
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
        .macGameCursor()
        .onAppear {
            #if targetEnvironment(macCatalyst)
            // The pointer gets out of the way once it stops moving, and
            // returns the moment it moves again. See MacWindow.
            MacWindow.setGameMode(true)
            startMacPhoneLink()
            #endif
            // The manager is started here, not assumed started: before this
            // call the only screens that started it were the webview player,
            // Settings and the remap screen, so a fresh launch straight into
            // a native game left every controller silent.
            GameControllerManager.shared.start()
            // N64 needs its own base bindings; see ControllerBindings.n64.
            GameControllerManager.shared.activePlatform = platform.rawValue
            // Offer this game to a television if one is attached. Harmless
            // when none is: the window that reads this does not exist, and
            // showsGameExternally stays false, so the phone draws as it
            // always has. See ExternalDisplay.swift.
            ExternalDisplay.shared.renderer = renderer
            // Same as the webview player: a running game is being watched
            // even when nothing touches the screen, and with a physical
            // controller nothing ever does. Without this the screen dims
            // and locks mid-game.
            UIApplication.shared.isIdleTimerDisabled = true
            // A Game & Watch plays in its artwork's own orientation,
            // Marcus's call: the tap surface needs the picture large,
            // and a wide unit held tall is neither. The lock releases
            // with the player, same as the webview's lockToCurrent.
            if let spec = gwSpec {
                if spec.isLandscape { OrientationLock.lockToLandscape() }
                else { OrientationLock.lockToPortrait() }
            }
            previousControllerSend = GameControllerManager.shared.send
            previousControllerStick = GameControllerManager.shared.sendStick
            previousControllerMenu = GameControllerManager.shared.onMenu
            previousControllerDisconnect = GameControllerManager.shared.onDisconnect
            GameControllerManager.shared.send = { [weak renderer] player, id, down in
                #if targetEnvironment(macCatalyst)
                // While the Mac's pause panel is up, the pad drives the
                // panel instead of the game. Presses only, so a button
                // still held from before the pause cannot fire a row on
                // its way up.
                if menuVisible {
                    if down { macMenuButton(id) }
                    return
                }
                #endif
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
            // Two screens with the hinge break, melonDS only; false
            // leaves every other core's draw path untouched. See
            // DSScreenLayout.swift.
            renderer.dsDualScreen = core == .melonDS
            NativeSessionMarker.recordGameRunning(romId: rom.id)
            // Temporary, for issue #6. One file per play session, so there
            // is never a question which run the numbers came from.
            FrameTrace.shared.begin(core: "\(core)")
        }
        .onDisappear {
            #if targetEnvironment(macCatalyst)
            MacWindow.setGameMode(false)
            stopMacPhoneLink()
            #endif
            FrameTrace.shared.end()
            UIApplication.shared.isIdleTimerDisabled = false
            // Release the artwork-orientation lock a Game & Watch took.
            if platform == .gameAndWatch { OrientationLock.unlock() }
            // Take the picture back off the television. Guarded the same
            // way the platform claim below is, so a second game's view
            // that has already claimed it keeps it.
            if ExternalDisplay.shared.renderer === renderer {
                ExternalDisplay.shared.renderer = nil
                ExternalDisplay.shared.isPaused = false
            }
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
    #if targetEnvironment(macCatalyst)
    /// The rows of the Mac pause panel, in the order they are drawn, so
    /// a pad walks them in the order they appear rather than in whatever
    /// order the view happens to build them.
    private var macMenuRows: [String] {
        platform.supportsSaveStates
            ? ["quit", "save", "load", "resume"]
            : ["quit", "resume"]
    }

    /// One row of the panel. Split out of the body because the style
    /// and tint vary per row, and expressing that inline defeated the
    /// type checker.
    @ViewBuilder
    private func macMenuRowButton(row: String, index: Int) -> some View {
        let selected = macMenuUsingController && index == macMenuSelection
        // The ring is drawn only once a pad or a phone has actually
        // moved the selection. With a mouse in hand it would be a second
        // cursor arguing with the real one.
        let ring = RoundedRectangle(cornerRadius: 7)
            .stroke(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            .padding(-2)
        let action = {
            macMenuSelection = index
            macActivateMenuRow()
        }
        if row == "resume" {
            Button(action: action) {
                Text(macMenuRowTitle(row)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .overlay(ring)
            // Return resumes, the way the default button of a Mac panel
            // does. Escape already closes it.
            .keyboardShortcut(.defaultAction)
        } else {
            Button(role: row == "quit" ? .destructive : nil, action: action) {
                Text(macMenuRowTitle(row)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .overlay(ring)
        }
    }

    private func macMenuRowTitle(_ row: String) -> String {
        switch row {
        case "quit": return "Quit"
        case "save": return "Save"
        case "load": return "Load"
        default: return "Resume"
        }
    }

    /// A pad or phone press while the panel is open.
    private func macMenuButton(_ id: Int) {
        macMenuUsingController = true
        switch id {
        case RetroPad.left, RetroPad.up:
            macMenuSelection = max(0, macMenuSelection - 1)
        case RetroPad.right, RetroPad.down:
            macMenuSelection = min(macMenuRows.count - 1, macMenuSelection + 1)
        case RetroPad.a, RetroPad.start:
            macActivateMenuRow()
        case RetroPad.b:
            // The way out, matching every other cancel in the app.
            closeMenu()
        default:
            break
        }
    }

    private func macActivateMenuRow() {
        guard macMenuSelection < macMenuRows.count else { return }
        switch macMenuRows[macMenuSelection] {
        case "quit": dismiss()
        case "save": saveState()
        case "load": loadLatestState()
        default: closeMenu()
        }
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// The pairing code, over the game, in the corner.
    ///
    /// Same shape and reasoning as the television's: large enough to
    /// read at a glance and monospaced, on a card small enough to read
    /// as an offer rather than a dialog demanding attention. No caption
    /// telling you to type it on the phone, since the person reading it
    /// is holding the phone that just asked.
    private func macPairingOverlay(code: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Phone controller")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(ControllerPairing.displayCode(code))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .transition(.opacity)
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// Starts the phone receiver for this game.
    ///
    /// The verbs are wired to the same places the television wires
    /// them, because they are the same functions: buttons and sticks
    /// into the renderer, pointer and mouse deltas into the frontend,
    /// and pause, save and load into this view's own menu actions, so a
    /// state saved from the phone lands in the same slot with the same
    /// upload path as one saved here.
    ///
    /// The advertised name follows the television's rule exactly, since
    /// the phone matches on it to pick its control layout: an arcade
    /// game advertises its rom's filename, everything else its layout
    /// and rom id.
    private func startMacPhoneLink() {
        guard macAllowPhoneController, macPhoneLink == nil else { return }
        let layoutName = ControlLayout.forPlatform(slug: canonicalSlug)?.system ?? "default"
        let advertised = platform == .arcade
            ? rom.fsNameNoExt.lowercased()
            : "\(layoutName).\(rom.id)"
        let link = ControllerLinkReceiver(
            shortname: advertised,
            assignPort: { phoneID in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        GameControllerManager.shared.claimPhoneSlot(for: phoneID)
                    }
                }
            },
            releasePort: { phoneID in
                Task { @MainActor in
                    GameControllerManager.shared.releasePhoneSlot(for: phoneID)
                }
            },
            onButton: { [weak renderer] port, id, down in
                // The same rule the physical pad follows: while the
                // panel is up, presses drive the panel rather than the
                // game. This callback is the phone's own path into the
                // renderer and does not pass through
                // GameControllerManager, so the check has to be repeated
                // here or a phone could never work the panel a pad can.
                Task { @MainActor in
                    if menuVisible {
                        if down { macMenuButton(id) }
                        return
                    }
                    renderer?.setButton(id, down: down, port: port)
                }
            },
            onStick: { [weak renderer] port, x, y in
                renderer?.setStick(x: x, y: y, port: port)
            },
            onRelative: { port, dx, dy in
                LibretroFrontend.shared.addMouseDeltaX(dx, y: dy, port: port)
            },
            onPointer: { port, x, y, down in
                // melonDS reads the touchscreen on port 0 only, the same
                // exception the television makes: pad on the buttons and
                // phone as the stylus is a real two-hands setup.
                let target = platform == .nds ? 0 : port
                LibretroFrontend.shared.setPointerX(Float(x), y: Float(y), down: down, port: target)
            },
            onOffscreen: { port, off in
                LibretroFrontend.shared.setLightgunOffscreen(off, port: port)
            },
            // The Mac diverges from the television here, deliberately.
            // A Mac has no remote, and the phone's own menu has no Quit
            // by design, so the phone's menu button raises this screen's
            // panel: Quit, the shader and the glow, all on the screen
            // the game is on.
            //
            // The phone still shows its own dialog at the same time, and
            // that dialog is modal, so it covers the d-pad that would
            // otherwise drive this panel. Marcus's call, 2026-08-30: the
            // mouse is fine for pressing it, and having the menu appear
            // on screen at all is the part that matters. Making the
            // phone defer to this panel instead would mean the host
            // telling the phone what kind of machine it is, which is a
            // wire-format change shipping on both apps at once.
            //
            // Nothing on the phone or on tvOS changes; this is the Mac
            // host's own reaction to a pause it already receives.
            onPause: { paused in
                Task { @MainActor in
                    if paused {
                        macMenuSelection = 0
                        openMenu()
                    } else {
                        closeMenu()
                    }
                }
            },
            onSave: { Task { @MainActor in saveState() } },
            onLoad: { Task { @MainActor in loadLatestState() } },
            onPhone: { joined in
                Task { @MainActor in
                    if platform == .nds {
                        // The tvOS forced option keeps melonDS in
                        // Joystick mode; a phone IS a touchscreen, so
                        // its presence flips the core to Touch mid-game
                        // and its leaving flips back.
                        var opts = NativeCoreOptionsStore.dictionary(for: .nds)
                        if joined { opts["melonds_touch_mode"] = "Touch" }
                        LibretroFrontend.shared.updateCoreOptions(opts)
                        // The shareplay split: a joined phone gets the
                        // bottom screen as video and this window gives
                        // everything to the top one. Leaving reverts
                        // both. Identical to the television, because a
                        // phone should not behave differently depending
                        // on which of your machines it joined.
                        if joined {
                            if macVideoServer == nil, let server = DSVideoServer() {
                                macVideoServer = server
                                renderer.dsBottomFrameTap = { [weak server] pixels, stride in
                                    server?.submit(bottomHalf: pixels, bytesPerRow: stride)
                                }
                                macPhoneLink?.offerVideo(port: server.port, token: server.token)
                            }
                            renderer.dsTopOnly = true
                        } else {
                            macPhoneLink?.revokeVideo()
                            renderer.dsTopOnly = false
                            renderer.dsBottomFrameTap = nil
                            macVideoServer?.stop()
                            macVideoServer = nil
                        }
                    }
                }
            },
            onPairingCode: { code in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.25)) { macPairingCode = code }
                }
            },
            onDrop: {}
        )
        link.start()
        macPhoneLink = link
        // A phone holding a seat is that player's controller, so the
        // game's rumble has to reach it over the wire. A Mac has no
        // Taptic Engine of its own either.
        GameControllerManager.companionRumble = { [weak link] port, strong, strength in
            link?.sendRumble(port: port, strong: strong, strength: strength)
        }
        // Dreamcast alone: mirror player one's VMU LCD to the phone's
        // controller screen, the display half of the phone-as-VMU
        // design.
        if platform == .dreamcast {
            VMULCDRelay.shared.install { [weak link] packed in
                link?.sendVMULCD(packed)
            }
        }
        // The pairing screen may still be alive underneath this cover
        // with its own listener up; one advertisement at a time.
        NotificationCenter.default.post(name: .cabinetGameLinkStarted, object: nil)
    }

    /// Everything the link owns, released together, mirroring the
    /// television's own teardown.
    private func stopMacPhoneLink() {
        if macPhoneLink != nil {
            NotificationCenter.default.post(name: .cabinetGameLinkEnded, object: nil)
        }
        renderer.dsBottomFrameTap = nil
        renderer.dsTopOnly = false
        macVideoServer?.stop()
        macVideoServer = nil
        VMULCDRelay.shared.uninstall()
        GameControllerManager.companionRumble = nil
        macPhoneLink?.stop()
        macPhoneLink = nil
    }
    #endif

    #if targetEnvironment(macCatalyst)
    /// The Mac's pause panel.
    ///
    /// The shared menu is a phone card: 280pt wide, every control a
    /// full-width bordered button stacked in a column, which on a desk
    /// reads as a phone screenshot dropped into a window. A Mac panel is
    /// wider, states the game once at a real size, and puts a setting's
    /// current value on the row that changes it instead of hiding it
    /// behind a press.
    ///
    /// Letterbox glow lives here as well as in Settings. It is the one
    /// setting whose effect is only visible while a game is on screen,
    /// so changing it anywhere else means guessing, and quitting to
    /// Settings to judge a picture you can no longer see is the wrong
    /// shape for it.
    private var macPauseMenu: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rom.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    Text(menuStatus ?? "Paused")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)

                VStack(spacing: 8) {
                    macSettingRow("Shader", systemImage: "camera.filters", value: renderer.shader.label) {
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
                    }
                    macSettingRow("Letterbox glow", systemImage: "light.max",
                                  value: BiasGlowLevel.level(fromStored: macGlowStored).label) {
                        ForEach(BiasGlowLevel.allCases) { level in
                            Button {
                                macGlowStored = level.rawValue
                            } label: {
                                if level.rawValue == macGlowStored {
                                    Label(level.label, systemImage: "checkmark")
                                } else {
                                    Text(level.label)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)

                // Built from the same list a pad walks, so the ring
                // showing what is selected can never point at a
                // different row than the one a press would activate.
                HStack(spacing: 10) {
                    ForEach(Array(macMenuRows.enumerated()), id: \.offset) { index, row in
                        macMenuRowButton(row: row, index: index)
                    }
                }
            }
            .frame(width: 460, alignment: .leading)
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .disabled(menuBusy)
        }
    }

    /// A label, its current value, and a menu to change it: the shape a
    /// Mac uses for a setting, rather than a button that says only what
    /// it would open.
    private func macSettingRow<Content: View>(
        _ title: String,
        systemImage: String,
        value: String,
        @ViewBuilder menu: () -> Content
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Menu {
                menu()
            } label: {
                HStack(spacing: 4) {
                    Text(value).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 8))
    }
    #endif

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
                    // Game & Watch has no save states (the core cannot
                    // serialize), so the slots hide rather than fail.
                    if platform.supportsSaveStates {
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
                    }
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

/// The DS bottom screen as a touch surface, layered over the Metal view
/// when melonDS runs. Occupies exactly DSScreenLayout's bottom-screen
/// rect, so a finger on the picture is a stylus on the touchscreen and
/// a finger anywhere else falls through to the control pad beneath.
/// Drags that wander off the screen's edge clamp to it (see
/// DSScreenLayout.pointer) until the finger lifts, the way a stylus
/// pressed against the bezel would keep contact.
private struct DSTouchScreenView: View {
    let sendPointer: (_ x: Double, _ y: Double, _ down: Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let rect = DSScreenLayout.bottomScreenRect(in: geo.size)
            if rect.width > 0, rect.height > 0 {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("dsPlayerSurface"))
                            .onChanged { g in
                                let p = DSScreenLayout.pointer(for: g.location, in: geo.size)
                                sendPointer(Double(p.x), Double(p.y), true)
                            }
                            .onEnded { g in
                                let p = DSScreenLayout.pointer(for: g.location, in: geo.size)
                                sendPointer(Double(p.x), Double(p.y), false)
                            }
                    )
            }
        }
        .coordinateSpace(name: "dsPlayerSurface")
    }
}
