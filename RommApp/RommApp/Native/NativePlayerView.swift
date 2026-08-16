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
    /// The card bytes as of the last sync or upload, so snapshots only
    /// travel when an in-game save actually changed them.
    @State private var lastCardData: Data?
    /// Same idea for the Game Boy clock region. Tracked separately so a
    /// clock tick alone never counts as a card change.
    @State private var lastRTCData: Data?

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
        captureMemoryCard()
        captureVMUSave()
    }

    /// Whether this session has a RETRO_MEMORY_SAVE_RAM battery save to
    /// look after through the core directly. Started as PS1 and N64
    /// only; issue #5 wired the same one memory call into every
    /// cartridge core, so this now covers every platform whose saves
    /// ride that call, the list (and the reasons for each exclusion)
    /// living on the platform itself. Dreamcast's VMU save is a real
    /// battery save too, just reached a completely different way; see
    /// `captureVMUSave()`, gated on `platform == .dreamcast` separately
    /// rather than folded in here.
    private var hasMemoryCard: Bool {
        platform.savesOverSaveRAM
    }

    /// The launch-time decision of which card goes into the slot: a local
    /// copy still waiting to upload always wins (it is strictly newer than
    /// anything the server has), otherwise the server's card wins whenever
    /// its stamp moved since the last sync, covering saves made on another
    /// device. Offline, or with nothing on the server, whatever is on disk
    /// plays. A game with no card anywhere just starts with the core's
    /// own freshly formatted one.
    /// Whether a card image holds any actual saves. PS1's 128KB memory
    /// card has a real directory format worth checking: frames 1-15
    /// carry 0x51/0x52/0x53 in their first byte for in-use blocks, 0xA0
    /// for free ones (the PS1 memory card spec's block allocation
    /// states). A freshly formatted card that no game ever wrote must
    /// never outrank a real card from the server, which is exactly what
    /// happened when a quick native boot left an empty local card behind
    /// and blocked the adoption path below.
    ///
    /// The format knowledge itself lives on MemoryCardStore, shared with
    /// keep-time prefetch so the two can never judge the same bytes
    /// differently. This wrapper only binds the current platform.
    private func cardHasSaves(_ card: Data) -> Bool {
        MemoryCardStore.cardHasSaves(card, platform: platform)
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
            await syncRTCIn(serverRows: nil)
            return
        }

        if let saves = try? await session.saves(romId: rom.id) {
            // The clock and cart regions travel as their own rows; they
            // are never cards and never adoption candidates, so they stay
            // out of every decision below.
            let sorted = saves
                .filter { MemoryCardStore.region(ofFileName: $0.fileName) == .saveRAM }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
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
                    await syncRTCIn(serverRows: saves)
                    return
                }
                DiagnosticsLog.record(
                    context: "Memory card",
                    message: "Found \(newest.fileName) on the server but its content did not verify as a card with saves.",
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
            await syncRTCIn(serverRows: saves)
            return
        }

        DiagnosticsLog.record(
            context: "Memory card",
            message: "Could not list saves from the server; using what is on this phone.",
            romVersion: session.serverVersion
        )

        if let local {
            renderer.pendingSaveRAM = local
            lastCardData = local
            DiagnosticsLog.record(
                context: "Memory card",
                message: localUseful ? "Using the local card." : "Using the local card; it holds no saves yet.",
                romVersion: session.serverVersion
            )
        }
        await syncRTCIn(serverRows: nil)
    }

    /// The Game Boy clock region's own, much simpler launch decision:
    /// only ever Cabinet's own row (a clock from another emulator's save
    /// means nothing to this core's format), local-pending wins, else a
    /// server copy newer than the last sync, else whatever is on disk.
    /// `serverRows` reuses the list the card sync already fetched; nil
    /// means the server was unreachable and only the local copy plays.
    private func syncRTCIn(serverRows: [GameSave]?) async {
        let store = MemoryCardStore.shared
        let local = store.localCard(romId: rom.id, region: .rtc)

        if store.pendingUpload(romId: rom.id, region: .rtc), let local {
            renderer.pendingRTC = local
            lastRTCData = local
            await uploadMemoryCard(local, region: .rtc)
            return
        }

        if let own = serverRows?
            .filter({ $0.emulator == core.emulatorTag && $0.fileName.hasSuffix(".rtc") })
            .sorted(by: { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") })
            .first,
           own.updatedAt != store.serverStamp(romId: rom.id, region: .rtc) || local == nil,
           let bytes = try? await session.saveContent(own), !bytes.isEmpty {
            store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: own.updatedAt, region: .rtc)
            renderer.pendingRTC = bytes
            lastRTCData = bytes
            return
        }

        if let local {
            renderer.pendingRTC = local
            lastRTCData = local
        }
    }

    /// Snapshots the card while the core is paused and, when it actually
    /// changed, writes it to disk first and then tries the upload. Runs on
    /// every pause, quit and background: cards are small and in-game saves
    /// are the one thing a player never expects to lose.
    ///
    /// A card that never held a save does not travel: a session that
    /// started with nothing (no local card, no server card) and whose
    /// bytes still read as a factory erase pattern is just the core's own
    /// freshly initialized region, and uploading it would put a junk row
    /// on the server for every save-less game ever paused. The moment a
    /// card holds anything real, or a real card existed before this
    /// session, every change travels, erasing a save included.
    private func captureMemoryCard() {
        guard hasMemoryCard, renderer.paused, let data = renderer.snapshotSaveRAM() else { return }
        guard data != lastCardData else { return }
        guard cardHasSaves(data) || lastCardData != nil else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        Task { await uploadMemoryCard(data) }
        captureRTC()
    }

    /// The clock region rides along only when the card itself just
    /// traveled: the region ticks on every real-world second, so change
    /// alone means nothing, but a clock captured next to a fresh save is
    /// exactly what keeps Pokemon Gold and Silver's day/night right when
    /// the save comes back on this or another device.
    private func captureRTC() {
        guard let rtc = renderer.snapshotRTC(), rtc != lastRTCData else { return }
        lastRTCData = rtc
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: rtc, region: .rtc)
        Task { await uploadMemoryCard(rtc, region: .rtc) }
    }

    /// Dreamcast only, and structurally different from
    /// `captureMemoryCard()`: Flycast never exposes its VMU save through
    /// RETRO_MEMORY_SAVE_RAM at all (confirmed against its own
    /// retro_get_memory_data, which only ever answers
    /// RETRO_MEMORY_SYSTEM_RAM), it writes a real file straight into the
    /// system directory instead. This is the capture half; the restore
    /// half is `NativeLauncher.restoreVMUSaveIfNeeded`, which writes the
    /// card back as `dc/vmu_save_A1.bin` before the core boots. That is
    /// Flycast's fallback filename, so if the core ever resolves the
    /// disc's own game id and looks for the per-game name instead, the
    /// restore is silently ignored; not yet seen on hardware.
    private func captureVMUSave() {
        guard platform == .dreamcast, renderer.paused else { return }
        guard let systemDir = LibretroFrontend.shared.systemDirectory() else {
            print("[vmu] no systemDirectory")
            return
        }
        // Same "dc/" subdirectory the BIOS needed (see stageFirmware's
        // own comment): confirmed 2026-08-11 by pulling the app's real
        // data container over `devicectl device copy from` and finding
        // the actual file at workDir/dc/vmu_save_A1.bin after a real
        // in-game save, not at the system directory's own root the way
        // this scan first assumed.
        let scanDir = URL(fileURLWithPath: systemDir).appendingPathComponent("dc", isDirectory: true).path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: scanDir) else {
            print("[vmu] could not list \(scanDir)")
            return
        }
        print("[vmu] scanning \(scanDir): \(entries)")
        // No leading underscore: PerGameVmu names the file
        // "<gameId>_vmu_save_A1.bin", but Flycast falls back to the
        // bare "vmu_save_A1.bin" (no separator at all) whenever the
        // disc's own game id isn't available yet at the moment it
        // names the file.
        guard let vmuName = entries.first(where: { $0.hasSuffix("vmu_save_A1.bin") }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: scanDir).appendingPathComponent(vmuName))
        else {
            print("[vmu] no *vmu_save_A1.bin match")
            return
        }
        guard data != lastCardData else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        DiagnosticsLog.record(
            context: "VMU save", message: "Found \(vmuName), \(data.count) bytes, uploading.",
            romVersion: session.serverVersion
        )
        Task { await uploadMemoryCard(data) }
    }

    /// Sega CD and Neo Geo Pocket, after `unloadGame` has made the core
    /// flush: reads the save file the core just wrote into its
    /// persistent save directory and syncs it through the same store and
    /// upload the memory-API platforms use. Quit is the only capture
    /// point these two have; a session ended by iOS killing the app
    /// loses its in-game saves since launch, the same accepted
    /// limitation FBNeo's NVRAM always had, and the same one RetroArch
    /// lives with for these cores. Compared against the store's own copy
    /// rather than `lastCardData`, which the launch sync never sets for
    /// these platforms; the same junk guard applies so a session that
    /// never saved uploads nothing.
    private func captureCoreFileSaves() {
        let suffix: String
        switch platform {
        case .segaCD: suffix = ".brm"
        case .ngpc: suffix = ".flash"
        default: return
        }
        let dir = NativeLauncher.coreSaveDirectory(romId: rom.id)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }

        func capture(_ file: URL, region: MemoryCardStore.Region) {
            guard let data = try? Data(contentsOf: file) else { return }
            let previous = MemoryCardStore.shared.localCard(romId: rom.id, region: region)
            guard data != previous else { return }
            guard MemoryCardStore.cardHasSaves(data, platform: platform) || previous != nil else { return }
            MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data, region: region)
            DiagnosticsLog.record(
                context: "In-game save",
                message: "Captured \(file.lastPathComponent), \(data.count) bytes, after core shutdown.",
                romVersion: session.serverVersion
            )
            Task { await uploadMemoryCard(data, region: region) }
        }

        // The internal backup RAM (or NGP's flash); the cart file is its
        // own region below, never this one.
        if let file = entries.first(where: {
            $0.lastPathComponent.hasSuffix(suffix) && !$0.lastPathComponent.hasSuffix("cart.brm")
        }) {
            capture(file, region: .saveRAM)
        }

        // Sega CD's external RAM cartridge, the location games prefer
        // when one is present (Lunar routed its save here on the first
        // real device test). Same store, same upload, its own row.
        if platform == .segaCD,
           let cart = entries.first(where: { $0.lastPathComponent.hasSuffix("cart.brm") }) {
            capture(cart, region: .cart)
        }
    }

    private func uploadMemoryCard(_ data: Data, region: MemoryCardStore.Region = .saveRAM) async {
        do {
            // The Cabinet marker keeps this row's filename distinct from
            // anything the web player made: RomM's overwrite matches rows
            // by filename alone, emulator tag not included (confirmed in
            // its saves endpoint source), so a bare "<name>.srm" upload
            // would silently take over and rewrite an existing EmulatorJS
            // card of the same name.
            try await session.uploadSave(
                romId: rom.id, emulator: core.emulatorTag,
                fileName: "\(rom.fsNameNoExt) (Cabinet).\(region.rawValue)", saveData: data
            )
            // Re-list to learn the stamp the server just minted, so the
            // next launch recognises its own upload instead of pulling
            // it back down.
            let saves = (try? await session.saves(romId: rom.id)) ?? []
            let stamp = saves
                .filter { $0.emulator == core.emulatorTag && MemoryCardStore.region(ofFileName: $0.fileName) == region }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                .first?.updatedAt
            MemoryCardStore.shared.markUploaded(romId: rom.id, serverStamp: stamp, region: region)
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
                            TouchControlPad(items: layoutItems(landscape: true), send: handleInput, sendStick: handleStick, system: controlLayout.system, opacity: controlOpacity)
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
                        TouchControlPad(items: layoutItems(landscape: false), send: handleInput, sendStick: handleStick, system: controlLayout.system, opacity: controlOpacity)
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
            NativeSessionMarker.recordGameRunning(romId: rom.id)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
            captureCoreFileSaves()
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
                captureVMUSave()
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
