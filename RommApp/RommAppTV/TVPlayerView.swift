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
    @State private var menuStatus: String?
    @State private var menuBusy = false
    @State private var startedAt: Date?
    /// The card bytes as of the last sync or upload, so snapshots only
    /// travel when an in-game save actually changed them.
    @State private var lastCardData: Data?

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

    /// PS1 and N64 both export a RETRO_MEMORY_SAVE_RAM battery save
    /// through the core directly. Dreamcast's VMU save is a real battery
    /// save too, just reached a completely different way; see
    /// `captureVMUSave()`, gated on `platform == .dreamcast` separately
    /// rather than folded in here. Identical to `NativePlayerView`'s own
    /// property, same reasoning.
    private var hasMemoryCard: Bool {
        platform == .psx || platform == .n64
    }

    /// Whether a card image holds any actual saves. See
    /// `NativePlayerView.cardHasSaves` for the full reasoning; identical
    /// logic here since the card formats do not differ by platform.
    private func cardHasSaves(_ card: Data) -> Bool {
        if platform == .psx {
            guard card.count == 128 * 1024 else { return false }
            return (1...15).contains { block in
                [0x51, 0x52, 0x53].contains(Int(card[128 * block]))
            }
        }
        return !card.isEmpty && card.contains { $0 != 0 }
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
    /// changed, writes it to disk first and then tries the upload. Runs
    /// on every pause, quit and background, identical to
    /// `NativePlayerView.captureMemoryCard`.
    private func captureMemoryCard() {
        guard hasMemoryCard, renderer.paused, let data = renderer.snapshotSaveRAM() else { return }
        guard data != lastCardData else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        Task { await uploadMemoryCard(data) }
    }

    /// Dreamcast only. See `NativePlayerView.captureVMUSave` for the full
    /// reasoning behind scanning for Flycast's own VMU file rather than
    /// naming it; identical here.
    private func captureVMUSave() {
        guard platform == .dreamcast, renderer.paused else { return }
        guard let systemDir = LibretroFrontend.shared.systemDirectory() else { return }
        let scanDir = URL(fileURLWithPath: systemDir).appendingPathComponent("dc", isDirectory: true).path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: scanDir) else { return }
        guard let vmuName = entries.first(where: { $0.hasSuffix("vmu_save_A1.bin") }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: scanDir).appendingPathComponent(vmuName))
        else { return }
        guard data != lastCardData else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        DiagnosticsLog.record(
            context: "VMU save", message: "Found \(vmuName), \(data.count) bytes, uploading.",
            romVersion: session.serverVersion
        )
        Task { await uploadMemoryCard(data) }
    }

    private func uploadMemoryCard(_ data: Data) async {
        do {
            try await session.uploadSave(
                romId: rom.id, emulator: core.emulatorTag,
                fileName: "\(rom.fsNameNoExt) (Cabinet).srm", saveData: data
            )
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

    private func openMenu() {
        renderer.paused = true
        menuStatus = nil
        menuVisible = true
        captureMemoryCard()
        captureVMUSave()
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
            if menuVisible {
                pauseMenu
            }
        }
        .task {
            if startedAt == nil { startedAt = Date() }
            await syncMemoryCardIn()
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
            NativeSessionMarker.recordGameRunning(romId: rom.id)
        }
        .onDisappear {
            controllers.capturesMenuButton = false
            controllers.send = previousSend
            controllers.sendStick = previousStick
            controllers.onMenu = previousMenu
            controllers.onDisconnect = previousDisconnect
            if let startedAt {
                session.reportPlaySessionEnded(romId: rom.id, start: startedAt, end: Date())
            }
            NativeSessionMarker.recordCleanExit()
            NativeLauncher.cleanUpTempDirectories()
        }
        .onChange(of: scenePhase) { _, phase in
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
