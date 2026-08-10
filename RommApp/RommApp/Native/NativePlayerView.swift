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

// MetalGameView and NativePlayerRenderer now live in their own file,
// Native/NativePlayerRenderer.swift, shared with tvOS's PS1PlayTestView
// rather than duplicated for it.

// NativePlayerAudio now lives in its own file, Native/NativePlayerAudio.swift,
// shared with tvOS's PS1PlayTestView rather than duplicated for it.
