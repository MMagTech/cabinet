import SwiftUI

/// The screen between picking a game and playing it, built natively.
///
/// RomM's own player page already does this job, and the game itself still
/// runs there. What this replaces is only the presentation: the choices are
/// gathered here in a screen that follows iOS conventions and lays out for
/// the shape of the display, then handed to RomM through the same
/// localStorage keys its page reads on load.
///
/// That is the whole coupling. Nothing here reimplements core selection, ROM
/// streaming, save handling or emulation. If a future RomM renames a key, the
/// value is ignored and its page falls back to its own defaults, which is
/// exactly the behaviour before this screen existed.
struct GameLaunchView: View {
    @ObservedObject private var compatibility = Compatibility.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }
    let rom: Rom

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var cores: [String] = []
    @State private var selectedCore: String?
    @State private var selectedBackend: LaunchChoices.PlayerBackend = .webview
    @State private var playingNative = false
    @State private var nativeInitialState: Data?
    @State private var firmware: [Firmware] = []
    /// Firmware the server knows about but cannot actually serve: the entry
    /// exists, the file behind it is gone. Silently hiding these looked
    /// like the platform needed no BIOS at all, and the first sign of
    /// trouble was a game booting to black.
    @State private var missingFirmware: [Firmware] = []
    @State private var selectedFirmware: Firmware?
    @State private var saves: [GameSave] = []
    @State private var states: [GameState] = []
    @State private var selectedSave: GameSave?
    @State private var selectedState: GameState?
    /// Only the three most recent states show without asking, since a
    /// filename told nobody anything and a long list of them was the
    /// actual reason this card needed thumbnails and dates at all.
    @State private var showAllStates = false
    @State private var deletingAssetIds: Set<Int> = []
    @State private var viewingScreenshot: ScreenshotTarget?

    private struct ScreenshotTarget: Identifiable {
        let id = UUID()
        let path: String?
        let title: String
    }
    @State private var pendingStateDelete: GameState?
    @State private var pendingSaveDelete: GameSave?
    @State private var loading = true
    @State private var playing = false
    /// Fetched before `playing` flips true, never after: `PlayerView` does
    /// not fetch its own state, callers resolve one first, so what it
    /// loads is decided in one place instead of chosen deep inside the
    /// player. Nil whenever no state is selected or continuing an
    /// interrupted run, in which case the game just boots normally.
    @State private var stateToLoad: PlayerView.StateToLoad?
    @State private var preparingPlay = false
    @State private var playError: String?
    /// Set when the last session of this game died without a clean exit and
    /// a fresh local autosave exists: iOS took the game, so getting back to
    /// that exact moment is offered, preselected, and declinable.
    @State private var interruptedAt: Date?
    @State private var continueRun = false
    /// The short name EmulatorJS's core catalogue actually indexes by,
    /// resolved once here and threaded to everything downstream that needs
    /// it, rather than recomputed piecemeal. See `Rom.canonicalPlatformSlug`.
    @State private var canonicalSlug = ""
    /// A keyboard machine, not a gamepad one. See ComputerPlatforms: this
    /// app does not offer touch play for these, on purpose, not yet.
    @State private var isComputerPlatform = false
    /// Arcade only: what the cabinet data says this game's controls are,
    /// and the person's current choice, which starts as the data's answer.
    @State private var arcadeBase: ArcadeProfile?
    @State private var arcadeButtons = 6
    @State private var arcadeWays = "8"
    @State private var togglingFavorite = false
    @State private var favoriteError: String?
    @ObservedObject private var keptStore = KeptGameStore.shared
    @StateObject private var exporter = RomExporter()
    @State private var showingExportSheet = false
    /// Whatever export was last attempted, so Retry repeats the same one
    /// (ROM alone, ROM and BIOS, or BIOS alone) rather than only ever
    /// retrying the plain ROM case.
    @State private var retryExport: (() -> Void)?

    /// Feeds the web player's cache from a kept game's local file, so a
    /// kept game skips the big download in either player. The hidden
    /// bridge webview only mounts while a seed is actually running, not
    /// on every visit to this screen. This is Data Saver's machinery with
    /// the network taken out of it: the person-facing feature folded into
    /// Keep, the injection path unchanged.
    @StateObject private var cacheBridge = EmulatorCacheBridge()
    @State private var showingCacheBridge = false
    @State private var seedPhase: SeedPhase = .idle

    enum SeedPhase: Equatable {
        case idle
        case waitingForBridge
        case writing
        case failed
    }

    /// Whether the scroll content is resting at its top, the only moment a
    /// downward drag should be read as "dismiss" rather than "scroll".
    @State private var isScrolledToTop = true
    /// How far the whole screen has been dragged down, for the
    /// hand-rolled swipe-to-dismiss below: `fullScreenCover`, unlike
    /// `sheet`, has no interactive dismiss gesture of its own.
    @State private var dragOffset: CGFloat = 0

    private static let dismissThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ScrollView {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self, value: proxy.frame(in: .named("gameLaunchScroll")).minY
                    )
                }
                .frame(height: 0)

                if landscape {
                    // A short wide screen has width to spare and almost no
                    // height, so the option cards sit side by side rather
                    // than stacking into a column that needs scrolling.
                    // Identity and the primary action stay together on the
                    // left, where the eye starts.
                    HStack(alignment: .top, spacing: 20) {
                        // Identity on the left, choices and the action on
                        // the right. The cover stays small because a
                        // landscape phone leaves roughly 318 points once the
                        // navigation bar and padding take theirs.
                        VStack(spacing: 10) {
                            cover(maxWidth: 115)
                            titleBlock(centred: true)
                        }
                        .frame(width: 170)

                        VStack(spacing: 12) {
                            // Equal halves. Both cards carry a label and a
                            // picker and nothing else, so they match without
                            // being forced to.
                            // Arcade games configure the web player inside
                            // the Player card instead, so a backend switch
                            // never restructures the stack; these standalone
                            // cards serve the games with no picker at all.
                            if !rom.isArcade, selectedBackend == .webview {
                                HStack(alignment: .top, spacing: 12) {
                                    if cores.count > 1 {
                                        coreCard.frame(maxWidth: .infinity)
                                    }
                                    if showsFirmwareCard {
                                        firmwareCard.frame(maxWidth: .infinity)
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                            }

                            if rom.isArcade { playerCard }
                            if showsKeepCard { keepCard }

                            playButton

                            if isComputerPlatform { computerPlatformCard }
                            downloadStatusCard
                            if interruptedAt != nil { continueCard }
                            compatibilityCard
                            if arcadeBase != nil { arcadeControlsCard }
                            if !states.isEmpty || !saves.isEmpty { resumeCard }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 20) {
                        cover(maxWidth: 200)
                        titleBlock(centred: true)
                        playButton
                        options
                    }
                    .padding(20)
                }
            }
            .coordinateSpace(name: "gameLaunchScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { isScrolledToTop = $0 >= -1 }
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDragGesture)
        }
        .background(Color(.systemGroupedBackground))
        // The seeding bridge lives at the screen root, not on the export
        // button it once shared: the button is now hidden on exactly the
        // games that seed, and a webview mounted under a hidden view
        // never loads.
        .background {
            if showingCacheBridge, let serverURL = session.serverURL {
                EmulatorCacheWebView(url: serverURL, bridge: cacheBridge)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: cacheBridge.isReady) { _, ready in
            if ready, seedPhase == .waitingForBridge { Task { await runSeed() } }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                exportButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                favoriteButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { dismiss() }
            }
        }
        .sheet(isPresented: Binding(
            get: { exporter.exportURLs != nil }, set: { if !$0 { exporter.finishExport() } }
        )) {
            if let urls = exporter.exportURLs {
                DocumentExporter(urls: urls) { exporter.finishExport() }
            }
        }
        .task { await load() }
        .fullScreenCover(isPresented: $playing) {
            PlayerView(
                rom: rom, launch: launchChoices, resumeFromAutosave: continueRun, stateToLoad: stateToLoad
            )
        }
        .fullScreenCover(isPresented: $playingNative) {
            if let core = NativeCore.core(for: rom) {
                NativePlayerView(rom: rom, core: core, initialState: nativeInitialState)
            }
        }
        .alert(
            "Couldn't load that state",
            isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })
        ) {
            Button("OK") { playError = nil }
        } message: {
            Text(playError ?? "")
        }
        .sheet(item: $viewingScreenshot) { target in
            ScreenshotViewer(path: target.path, title: target.title)
        }
        // Coming back from a session the person closed themselves, the
        // interruption is spent: leaving the card up would offer to rewind
        // a deliberate exit. Re-ask the marker, which the clean exit
        // cleared.
        .onChange(of: playing) { _, isPlaying in
            if !isPlaying {
                refreshResumeOffer()
            } else {
                // A remote state can run past 100MB, and the player's
                // coordinator copies it out the moment the cover builds.
                // Holding this view's copy for the whole session doubles a
                // buffer that was only needed at boot. Released after a
                // beat, so the cover has provably built first.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    stateToLoad = nil
                }
            }
        }
        // Only changes made after the screen has settled are the person's;
        // the ones during load are this view choosing a default, and every
        // launch recording whichever core or BIOS happened to be that
        // default would conflate "what I chose" with "what I was shown",
        // outranking a better recommendation the next time a default
        // exists. Remembered as soon as a deliberate pick happens, not
        // deferred to Play: leaving the screen any other way, Close among
        // them, must not silently drop it.
        .onChange(of: selectedCore) { _, _ in
            guard !loading else { return }
            LaunchChoices.remember(core: selectedCore, canonicalSlug: canonicalSlug, for: rom)
        }
        .onChange(of: selectedFirmware) { _, _ in
            guard !loading, !rom.isArcade else { return }
            LaunchChoices.remember(firmwareId: selectedFirmware?.id, platformId: rom.platformId)
        }
        .onChange(of: selectedBackend) { _, _ in
            guard !loading else { return }
            LaunchChoices.remember(backend: selectedBackend, for: rom)
            // A state picked for one player cannot load in the other, so a
            // backend switch clears the selection rather than carrying a
            // promise the boot cannot keep.
            selectedState = nil
        }
    }

    // MARK: Pieces

    /// A star, not a card: this is a status toggle someone glances at and
    /// taps in passing, not a decision that needs its own explanation on
    /// the screen the way the arcade or firmware choices do.
    private var favoriteButton: some View {
        Button {
            let romId = rom.id
            togglingFavorite = true
            Task {
                do {
                    try await session.toggleFavorite(romId: romId)
                } catch {
                    favoriteError = error.localizedDescription
                }
                togglingFavorite = false
            }
        } label: {
            Image(systemName: session.isFavorite(romId: rom.id) ? "star.fill" : "star")
                .foregroundStyle(session.isFavorite(romId: rom.id) ? .yellow : .primary)
        }
        .disabled(togglingFavorite)
        .alert(
            "Couldn't update favorites",
            isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } }),
            presenting: favoriteError
        ) { _ in
            Button("OK") { favoriteError = nil }
        } message: { message in
            Text(message)
        }
    }

    /// The single source of truth for whether this app can put the game on
    /// screen at all: `PlatformSupport.isSupported`, the same check that
    /// decides the library's Supported/Unsupported split. Reused here so
    /// Play cannot stay live for a platform the library already calls
    /// unsupported, the zero-core dead end this download feature replaces.
    private var isPlatformSupported: Bool {
        !isComputerPlatform && !cores.isEmpty
    }

    /// One visible action, no exceptions: a game with the keep toggle
    /// shows no export button at all. The kept files, firmware included,
    /// are all in the Files app's Games folder, so there is nothing left
    /// for an export menu to offer that the folder does not already
    /// hold. This menu survives only where Keep cannot exist,
    /// unsupported platforms, keyboard machines, multi-file games,
    /// because there it is the only way to the file. Its earlier
    /// BIOS-only remnant on playable games was the last hedge of the
    /// three-eras accretion this redesign removed, and Marcus caught it
    /// within the hour.
    @ViewBuilder
    private var exportButton: some View {
        if !loading, !showsKeepCard {
            Button {
                showingExportSheet = true
            } label: {
                // The share arrow, up and out, never the download arrow:
                // everything behind this button sends bytes away from
                // the app.
                Image(systemName: "square.and.arrow.up")
            }
            // Attached here, not at the screen root: a confirmationDialog
            // anchors its arrow to whatever view carries this modifier, so
            // it has to sit on the actual toolbar button, not the whole
            // screen, or the arrow points at the wrong place.
            .confirmationDialog("Export", isPresented: $showingExportSheet, titleVisibility: .visible) {
                if !firmware.isEmpty {
                    Button("Export ROM and BIOS") { startExport(includeFirmware: true) }
                    // Always offered on its own, not just folded into
                    // the combined button above: if a previously
                    // exported BIOS file gets deleted or moved outside
                    // this app, this is the only way back to it, since
                    // the app has no visibility into Files once a file
                    // has been handed over.
                    Button("Export BIOS") { startFirmwareOnlyExport() }
                }
                Button("Export ROM") { startExport(includeFirmware: false) }
            }
            .onChange(of: exporter.state) { _, state in
                if case .failed(let message) = state {
                    DiagnosticsLog.record(context: "Export", message: message, romVersion: session.serverVersion)
                }
            }
        }
    }

    private var seedBusy: Bool {
        seedPhase == .waitingForBridge || seedPhase == .writing
    }

    /// Whether keeping this game should also pre-fill the web player's
    /// cache: only where a web launch is actually offered. Saturn is
    /// routed native with no picker, so a seeded copy there would be
    /// hundreds of duplicated megabytes nothing ever reads.
    private var seedsWebCache: Bool {
        guard isPlatformSupported, !rom.hasMultipleFiles else { return false }
        return NativeCore.core(for: rom) == nil || rom.isArcade
    }

    private func startSeeding() {
        seedPhase = .waitingForBridge
        showingCacheBridge = true
        if cacheBridge.isReady {
            Task { await runSeed() }
        }
    }

    /// The `url` this writes has to be byte-identical to what RomM's real
    /// player sets as `EJS_gameUrl`: EmulatorJS 4.2.3's cache key is that
    /// URL's last path segment, query string included. Confirmed broken
    /// on device before this fix (in this machinery's Data Saver era):
    /// `Player.vue` always passes a `file_ids` query parameter,
    /// `fileIDs: props.disc ? [props.disc] : []`, even for a single-file
    /// ROM, RomM's console view still selects a "disc" (the ROM's one
    /// file entry), so the real request is
    /// `/api/roms/{id}/content/{name}?file_ids={fileId}`, not the plain
    /// path. A captured player network log showed the ROM re-fetching on
    /// every Play despite a successful, correctly-shaped cache write,
    /// because that mismatch made every lookup a miss. The file id and
    /// the exact Content-Length header both come from the manifest,
    /// captured at keep time; the bytes come off local disk, no network.
    ///
    /// Failure here is deliberately soft: the kept copy is the promise,
    /// the cache entry only saves the web player one organic download,
    /// so a failed seed logs, shows a quiet caption, and never unkeeps.
    private func runSeed() async {
        guard seedPhase == .waitingForBridge else { return }
        seedPhase = .writing
        defer {
            showingCacheBridge = false
            cacheBridge.detach()
        }
        guard let kept = keptStore.kept(romId: rom.id),
              let fileId = kept.fileId,
              let fileName = kept.webFileName,
              let romURL = keptStore.fileURL(romId: rom.id, fileName: kept.fsName),
              let data = try? Data(contentsOf: romURL, options: .mappedIfSafe)
        else {
            seedPhase = .failed
            return
        }
        let encodedName = Self.jsEncodeURIComponent(fileName)
        let relativeURL = "/api/roms/\(rom.id)/content/\(encodedName)?file_ids=\(fileId)"
        let result = await cacheBridge.put(
            url: relativeURL, type: "rom", contentLength: kept.contentLength, data: data
        )
        if result.success {
            seedPhase = .idle
        } else {
            seedPhase = .failed
            DiagnosticsLog.record(
                context: "Web player copy",
                message: result.error ?? "Couldn't write the kept game into the web player's cache.",
                romVersion: session.serverVersion
            )
        }
    }

    /// Matches JavaScript's `encodeURIComponent` exactly, the unreserved
    /// set it leaves untouched (`A-Za-z0-9-_.!~*'()`) is narrower than any
    /// single built-in `CharacterSet`, and RomM's own `getDownloadPath`
    /// runs the real filename through `encodeURIComponent` before this
    /// app's cache entry has to match it byte-for-byte.
    private static func jsEncodeURIComponent(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    /// The local files that can satisfy an export without touching the
    /// network, or nil when any requested piece is not already on this
    /// phone, in which case the whole export downloads as before rather
    /// than mixing local and fetched halves.
    private func keptExportURLs(includeFirmware: Bool) -> [URL]? {
        guard !rom.hasMultipleFiles,
              let romURL = keptStore.fileURL(romId: rom.id, fileName: rom.fsName)
        else { return nil }
        guard includeFirmware else { return [romURL] }
        guard let bios = firmware.first,
              let biosURL = keptStore.fileURL(romId: rom.id, fileName: bios.fileName)
        else { return nil }
        return [romURL, biosURL]
    }

    private func startExport(includeFirmware: Bool) {
        retryExport = { [self] in startExport(includeFirmware: includeFirmware) }
        // A kept game's files were downloaded by this app and verified at
        // keep time; exporting them is a copy, not a second download.
        if let urls = keptExportURLs(includeFirmware: includeFirmware) {
            exporter.presentLocal(urls: urls)
            return
        }
        Task {
            do {
                var files: [(request: URLRequest, suggestedName: String)] = []
                var folderName: String?

                if rom.hasMultipleFiles {
                    // RomM's own zip endpoint is broken through the reverse
                    // proxy (scope doc, Open items), so each file is fetched
                    // on its own and exported as a folder instead.
                    let romFiles = try await session.romFiles(romId: rom.id)
                    for file in romFiles {
                        let fileRequest = try await session.romFileContentRequest(romId: rom.id, file: file)
                        files.append((fileRequest, file.fileName))
                    }
                    folderName = rom.fsName
                } else {
                    let romRequest = try await session.romContentRequest(rom)
                    files.append((romRequest, rom.fsName))
                }

                if includeFirmware, let bios = firmware.first {
                    let firmwareRequest = try await session.firmwareContentRequest(bios)
                    files.append((firmwareRequest, bios.fileName))
                }
                exporter.start(files: files, folderName: folderName)
            } catch {
                exporter.fail("Couldn't reach the server.")
            }
        }
    }

    /// The BIOS on its own, reachable any time regardless of whether it was
    /// bundled with a ROM before: the app cannot see whether a file handed
    /// to Files earlier is still there.
    private func startFirmwareOnlyExport() {
        guard let bios = firmware.first else { return }
        retryExport = { [self] in startFirmwareOnlyExport() }
        if let biosURL = keptStore.fileURL(romId: rom.id, fileName: bios.fileName) {
            exporter.presentLocal(urls: [biosURL])
            return
        }
        Task {
            do {
                let firmwareRequest = try await session.firmwareContentRequest(bios)
                exporter.start(files: [(firmwareRequest, bios.fileName)])
            } catch {
                exporter.fail("Couldn't reach the server.")
            }
        }
    }

    private func cover(maxWidth: CGFloat) -> some View {
        CoverImage(path: rom.pathCoverLarge ?? rom.pathCoverSmall, title: rom.displayName)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: maxWidth)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(radius: 10, y: 5)
    }

    private func titleBlock(centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 4) {
            Text(rom.displayName)
                .font(.title2.bold())
                .multilineTextAlignment(centred ? .center : .leading)
            Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
    }

    private var playButton: some View {
        Button {
            // Remembering itself already happened the moment the choice was
            // made, see the onChange handlers above.
            Task { await beginPlay() }
        } label: {
            if preparingPlay {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            } else {
                Label(playLabel, systemImage: isComputerPlatform ? "keyboard" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
        }
        .buttonStyle(.borderedProminent)
        // Blocked while a seed runs: letting the game boot mid-write
        // put a whole ROM's worth of buffering next to the emulator's own
        // memory, on a device-wide budget. The keep card explains the
        // wait, and a local copy is quick.
        .disabled(loading || !isPlatformSupported || preparingPlay || seedBusy)
    }

    /// Resolves `stateToLoad` before presenting the player, since a state
    /// someone explicitly picked deserves an explanation if it cannot be
    /// fetched, not a silent boot into the wrong moment. An interrupted
    /// run's own local recovery is untouched: that path never goes near
    /// the server at all, by design, see `PlayerView.resumeFromAutosave`.
    private func beginPlay() async {
        if selectedBackend == .native {
            await beginNativePlay()
            return
        }
        guard !continueRun, let selectedState else {
            stateToLoad = nil
            playing = true
            return
        }
        preparingPlay = true
        defer { preparingPlay = false }
        guard let bytes = try? await session.stateContent(selectedState) else {
            playError = "Couldn't reach the server to load that state."
            return
        }
        stateToLoad = .remote(bytes)
        playing = true
    }

    /// The native path downloads before presenting rather than behind a
    /// boot curtain, so a failure surfaces here as an alert instead of a
    /// black screen with no explanation.
    private func beginNativePlay() async {
        preparingPlay = true
        defer { preparingPlay = false }
        do {
            try await NativeLauncher.prepare(rom: rom, session: session)
            if let selectedState {
                guard let bytes = try? await session.stateContent(selectedState) else {
                    playError = "Couldn't reach the server to load that state."
                    return
                }
                nativeInitialState = bytes
            } else {
                nativeInitialState = nil
            }
            playingNative = true
        } catch {
            playError = error.localizedDescription
        }
    }

    private var playLabel: String {
        if !loading && !isPlatformSupported { return "Unsupported" }
        if continueRun { return "Continue" }
        return selectedState != nil || selectedSave != nil ? "Resume" : "Play"
    }

    /// Why the button above is not a button right now. A keyboard machine
    /// has no fixed pad this app can honestly draw, so it does not try,
    /// rather than offering a control scheme that looks like it works and
    /// does not. Download support, once the app has any, is the planned
    /// way to still get this game, through a real emulator on a real
    /// keyboard instead.
    private var computerPlatformCard: some View {
        LaunchCard(title: "Needs a keyboard", systemImage: "keyboard") {
            Text("This platform is controlled with a keyboard, not a game pad, and this app does not offer that yet. A future version may let you download the ROM to play it in another emulator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var downloadStatusCard: some View {
        switch exporter.state {
        case .idle:
            EmptyView()
        case .downloading(let fraction, let received, let total):
            LaunchCard(title: "Exporting ROM", systemImage: "square.and.arrow.up") {
                VStack(alignment: .leading, spacing: 8) {
                    if total > 0 {
                        Text("\(byteCount(received)) of \(byteCount(total))")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Button("Cancel", role: .destructive) { exporter.cancel() }
                        .font(.callout)
                }
            }
        case .failed(let message):
            LaunchCard(title: "Couldn't export the ROM", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Dismiss") { exporter.cancel() }
                        Spacer()
                        Button("Retry") { retryExport?() }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The offer to pick an interrupted run back up. A card like the others,
    /// preselected because iOS ending the game is the one case where "right
    /// where I was" is almost always the answer, and declinable because
    /// almost is not always.
    private var continueCard: some View {
        LaunchCard(title: "Interrupted game", systemImage: "arrow.uturn.backward.circle") {
            choiceRow(
                label: "Continue where you left off",
                detail: interruptedAt.map {
                    "the game was closed by iOS " + Self.ago.localizedString(
                        for: $0, relativeTo: Date()
                    )
                } ?? "the game was closed by iOS",
                selected: continueRun,
                enabled: true
            ) {
                continueRun.toggle()
                if continueRun {
                    selectedState = nil
                    selectedSave = nil
                }
            }
        }
    }

    private static let ago = RelativeDateTimeFormatter()

    /// Landscape only: cards flow into as many columns as the width allows,
    /// so two or three of them do not become a scrolling column.
    @ViewBuilder
    private var optionsGrid: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading options").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(
                // 210 rather than 250: the space left beside the cover is
                // about 500 points, and 250 wide columns fit only once, which
                // stacked the cards and stretched each to hold two words.
                columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                if isComputerPlatform { computerPlatformCard }
                downloadStatusCard
                if interruptedAt != nil { continueCard }
                if !rom.isArcade, selectedBackend == .webview, cores.count > 1 { coreCard }
                if !rom.isArcade, selectedBackend == .webview, showsFirmwareCard { firmwareCard }
                if rom.isArcade { playerCard }
                if showsKeepCard { keepCard }
                if arcadeBase != nil { arcadeControlsCard }
                if !states.isEmpty || !saves.isEmpty { resumeCard }
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading options").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 14) {
                if isComputerPlatform { computerPlatformCard }
                downloadStatusCard
                if interruptedAt != nil { continueCard }
                if !rom.isArcade, selectedBackend == .webview, cores.count > 1 { coreCard }
                if !rom.isArcade, selectedBackend == .webview, showsFirmwareCard { firmwareCard }
                if rom.isArcade { playerCard }
                if showsKeepCard { keepCard }
                if arcadeBase != nil { arcadeControlsCard }
                if !states.isEmpty || !saves.isEmpty { resumeCard }
            }
        }
    }

    /// The manual override from the scope doc's resolution chain, living on
    /// the launch screen since the detail screen was cut. Shows what the
    /// cabinet data resolved to, owns up when the game was not in the map
    /// at all, and lets the person overrule both. Choices persist per rom
    /// and matching the data's own answer clears the override entirely.
    private var arcadeControlsCard: some View {
        LaunchCard(title: "Arcade controls", systemImage: "dpad") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    Picker("Buttons", selection: $arcadeButtons) {
                        Text("Stick only").tag(0)
                        ForEach(1...6, id: \.self) { count in
                            Text(count == 1 ? "1 button" : "\(count) buttons").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Picker("Stick", selection: $arcadeWays) {
                        Text("Eight way").tag("8")
                        Text("Four way").tag("4")
                        Text("Two way").tag("2")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Spacer()
                }
                Text(arcadeCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: arcadeButtons) { _, _ in storeArcadeChoice() }
        .onChange(of: arcadeWays) { _, _ in storeArcadeChoice() }
    }

    private var arcadeCaption: String {
        guard let base = arcadeBase else { return "" }
        let isOverride = arcadeButtons != base.buttons || arcadeWays != base.ways
        if isOverride {
            return "Your choice. The cabinet data says \(describe(buttons: base.buttons, ways: base.ways))."
        }
        if base.unmapped {
            return "This game is not in the cabinet map, so this is the generic guess. Correct it here if it plays wrong."
        }
        return "From the game's cabinet data."
    }

    private func describe(buttons: Int, ways: String) -> String {
        let b = buttons == 0 ? "stick only" : (buttons == 1 ? "1 button" : "\(buttons) buttons")
        return "\(b), \(ways) way"
    }

    private func storeArcadeChoice() {
        guard let base = arcadeBase else { return }
        if arcadeButtons == base.buttons, arcadeWays == base.ways {
            ArcadeOverride.clear(for: rom.id)
        } else {
            ArcadeOverride.save(buttons: arcadeButtons, ways: arcadeWays, for: rom.id)
        }
    }

    /// Says what is known about this game running here, and never more
    /// than one thing: either it has been marked, or the app has watched
    /// it die enough times to raise the subject. Silent otherwise, which
    /// is almost always.
    @ViewBuilder
    private var compatibilityCard: some View {
        if compatibility.isMarked(rom.id) {
            LaunchCard(title: "Marked as not working", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You marked this game as not working on this phone. It will still play if you want to try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove the mark") {
                        compatibility.setMarked(false, romId: rom.id)
                    }
                    .font(.callout)
                }
            }
        } else if compatibility.shouldSuggestMark(romId: rom.id) {
            LaunchCard(title: "This game keeps closing", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("It has closed itself \(compatibility.crashes(romId: rom.id)) times on this phone. Some boards do not survive here, and a different emulator above sometimes fixes it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Mark it as not working") {
                        compatibility.setMarked(true, romId: rom.id)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var coreCard: some View {
        LaunchCard(title: "Emulator", systemImage: "cpu") {
            Picker("Emulator", selection: $selectedCore) {
                ForEach(cores, id: \.self) { core in
                    Text(CoreCatalog.displayName(core)).tag(Optional(core))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if LaunchChoices.isRecommended(core: selectedCore, rom: rom, available: cores) {
                Text("Recommended for this game's board. The general arcade core runs it too, but not reliably.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Web player or the natively compiled core, arcade only. Not a
    /// temporary limit: this shows only where both players genuinely
    /// work, so there is a real choice to offer. Saturn has a native
    /// core too (see `NativeCore`), but no working web alternative worth
    /// picking between, so `LaunchChoices.defaultBackend` routes it to
    /// native directly and no picker appears; the two-tier
    /// Supported/Unsupported split stays exactly as it was rather than
    /// growing a third state for this.
    /// Save states do not cross the boundary (each player's core build
    /// has its own state format), so the caption says so up front rather
    /// than letting someone discover it after losing a run.
    /// The web player's own configuration (emulator core, BIOS) lives
    /// inside this card, revealed under the segment when Web player is
    /// selected, rather than as sibling cards inserted into the stack.
    /// Structural, not cosmetic: a segmented control that adds and
    /// removes whole cards around itself reflows the entire screen with
    /// springy layout animation, the bounce Marcus flagged, and iOS
    /// segments swap content inside a stable region, they do not
    /// restructure the page. One card changes height, everything else
    /// holds still, and the choices that only configure the web player
    /// now visibly belong to it.
    private var playerCard: some View {
        LaunchCard(title: "Player", systemImage: "play.rectangle.on.rectangle") {
            Picker("Player", selection: $selectedBackend) {
                Text("Web player").tag(LaunchChoices.PlayerBackend.webview)
                Text("Native (beta)").tag(LaunchChoices.PlayerBackend.native)
            }
            .pickerStyle(.segmented)

            if selectedBackend == .native {
                Text("Runs the game in a natively compiled core instead of the web player. Save states stay separate per player.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if Compatibility.shared.crashes(romId: rom.id) >= 3 {
                Text("The web player has crashed repeatedly on this game. The native player may hold up better.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if selectedBackend == .webview {
                if cores.count > 1 {
                    Divider()
                    LabeledContent {
                        Picker("Emulator", selection: $selectedCore) {
                            ForEach(cores, id: \.self) { core in
                                Text(CoreCatalog.displayName(core)).tag(Optional(core))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    } label: {
                        Text("Emulator")
                    }
                    if LaunchChoices.isRecommended(core: selectedCore, rom: rom, available: cores) {
                        Text("Recommended for this game's board. The general arcade core runs it too, but not reliably.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if showsFirmwareCard {
                    Divider()
                    if !firmware.isEmpty {
                        LabeledContent {
                            Picker("BIOS", selection: $selectedFirmware) {
                                Text("None").tag(Optional<Firmware>.none)
                                ForEach(firmware) { item in
                                    Text(item.fileName).tag(Optional(item))
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        } label: {
                            Text("BIOS")
                        }
                    }
                    if !missingFirmware.isEmpty {
                        Label {
                            Text("Missing from the server: \(missingFirmware.map(\.fileName).joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: selectedBackend)
    }

    /// One storage toggle for every game, playable or not; only the
    /// promise in the fine print varies. Unsupported systems included
    /// on purpose: those are exactly the games whose files someone
    /// wants for another emulator, and the toggle-into-Files flow
    /// serves that better than an export picker. Native-capable games
    /// mirror `NativeLauncher.prepare`'s own gates (a Saturn game that
    /// is not a single-file chd gets no toggle rather than a kept copy
    /// nothing can boot). The one true gate left is multi-file ROMs,
    /// which the download machinery cannot fetch yet; they keep the
    /// export menu until keep learns multi-file, a capability gap with
    /// a named successor, not a design carve-out.
    private var showsKeepCard: Bool {
        if let core = NativeCore.core(for: rom) {
            if core == .beetleSaturn {
                return !rom.hasMultipleFiles && rom.fsName.lowercased().hasSuffix(".chd")
            }
            return true
        }
        return !rom.hasMultipleFiles
    }

    /// Whether this app can put the game on screen in any player, which
    /// decides whether the storage captions may promise play at all.
    private var isPlayableHere: Bool {
        NativeCore.core(for: rom) != nil || isPlatformSupported
    }

    private var keepBinding: Binding<Bool> {
        Binding(
            get: { keptStore.kept(romId: rom.id) != nil || keptStore.downloading[rom.id] != nil },
            set: { wantKept in
                seedPhase = .idle
                if wantKept {
                    keptStore.keep(rom: rom, session: session)
                } else {
                    keptStore.remove(romId: rom.id)
                }
            }
        )
    }

    /// One toggle, one copy: keeping stores the ROM and firmware
    /// permanently, the native player boots straight from it, the web
    /// player's cache gets fed from it, Export copies from it. Removal
    /// lives on the same toggle, and the Storage screen lists every kept
    /// game in one place.
    private var keepCard: some View {
        // "Storage", not "Offline": the header has to be true for every
        // class of game, and a downloaded web-only game still needs the
        // server to launch. Neutral header, per-game promise in the
        // caption, and the card now shares name and icon with
        // Settings > Storage, two views of the same concept.
        LaunchCard(title: "Storage", systemImage: "internaldrive") {
            Toggle("Download", isOn: keepBinding)

            if let progress = keptStore.downloading[rom.id] {
                VStack(alignment: .leading, spacing: 8) {
                    if progress.totalBytes > 0 {
                        Text("\(byteCount(progress.receivedBytes)) of \(byteCount(progress.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(progress.fraction, 1))
                    } else {
                        ProgressView()
                    }
                }
            } else if seedBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing the web player's copy").foregroundStyle(.secondary)
                }
                .font(.caption)
            } else if keptStore.kept(romId: rom.id) != nil {
                Text(keptCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let error = keptStore.errors[rom.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(keepCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: keptStore.downloading[rom.id]) { old, new in
            // The moment a keep finishes is the one place the web
            // player's cache copy gets made, from the file just written,
            // no network involved. Removal mid-download lands here too
            // (old non-nil, new nil, nothing kept), and seeds nothing.
            guard old != nil, new == nil,
                  keptStore.kept(romId: rom.id) != nil, seedsWebCache
            else { return }
            startSeeding()
        }
    }

    /// Three promises, each stated only where it is true, under a
    /// header neutral enough to sit over all of them. Saturn-class
    /// games have no player choice, so no qualifier; arcade names the
    /// native player because the picker sits right above this card and
    /// offline belongs to native alone; web-only games get the honest
    /// weaker deal. The BIOS is never mentioned, it comes along as
    /// plumbing, and the Files app is not mentioned either: where the
    /// file lives is a learn-once fact the Storage screen teaches, not
    /// a promise worth repeating on every game.
    private var keptCaption: String {
        let size = keptStore.kept(romId: rom.id).map { byteCount($0.totalBytes) } ?? ""
        if NativeCore.core(for: rom) != nil {
            var caption = rom.isArcade
                ? "\(size) on this iPhone. Plays offline in the native player."
                : "\(size) on this iPhone. Plays without a connection."
            if seedPhase == .failed, rom.isArcade {
                caption += " The web player's copy couldn't be prepared; it will download once there."
            }
            return caption
        }
        // Unsupported systems say nothing beyond the cost: the library
        // already labeled them unsupported, the person downloading one
        // knows why they want the file.
        guard isPlayableHere else { return "\(size) on this iPhone." }
        if seedPhase == .failed {
            return "\(size) on this iPhone. The quick-start copy couldn't be prepared; the first play will download once."
        }
        return "\(size) on this iPhone. Starts faster; launching still needs your server."
    }

    private var keepCaption: String {
        let size = byteCount(rom.fsSizeBytes)
        if NativeCore.core(for: rom) != nil {
            return rom.isArcade
                ? "About \(size). Plays offline in the native player."
                : "About \(size). Plays without a connection."
        }
        guard isPlayableHere else { return "About \(size)." }
        return "About \(size). Starts faster and saves data; launching still needs your server."
    }

    private var showsFirmwareCard: Bool {
        !firmware.isEmpty || !missingFirmware.isEmpty
    }

    private var firmwareCard: some View {
        LaunchCard(title: "BIOS", systemImage: "memorychip") {
            if !firmware.isEmpty {
                Picker("BIOS", selection: $selectedFirmware) {
                    Text("None").tag(Optional<Firmware>.none)
                    ForEach(firmware) { item in
                        Text(item.fileName).tag(Optional(item))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !missingFirmware.isEmpty {
                Label {
                    Text("Missing from the server: \(missingFirmware.map(\.fileName).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
    }

    private var visibleStates: [GameState] {
        // Already newest first, see `load()`, so this is exactly the
        // recent handful the card promises.
        showAllStates ? states : Array(states.prefix(3))
    }

    private var resumeCard: some View {
        LaunchCard(title: "Resume from", systemImage: "clock.arrow.circlepath") {
            // States are greyed out when written by a different core, because
            // a memory snapshot cannot be loaded by an emulator that did not
            // make it. Saves survive a core change, so they are never greyed.
            // RomM's emulator field names the player, not the core: states
            // made through the web player, this app's included, all say
            // "emulatorjs", and greying those out disabled every state the
            // pause menu ever saved.
            ForEach(visibleStates) { state in
                stateRow(state)
            }
            if states.count > 3, !showAllStates {
                Button("Show all \(states.count) states") { showAllStates = true }
                    .font(.footnote)
                    .padding(.leading, 30)
            }
            ForEach(saves) { save in
                saveRow(save)
            }
        }
        .confirmationDialog(
            "Delete this state?",
            isPresented: Binding(
                get: { pendingStateDelete != nil }, set: { if !$0 { pendingStateDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let state = pendingStateDelete { Task { await deleteState(state) } }
            }
        } message: {
            // The one real consequence, spelled out, rather than a generic
            // warning: deleting the newest state changes what Resume does
            // next time, every other one is just cleanup.
            Text(
                pendingStateDelete?.id == states.first?.id
                    ? "This is what Resume currently loads. Deleting it means Resume will use your next most recent save instead."
                    : "This can't be undone."
            )
        }
        .confirmationDialog(
            "Delete this save?",
            isPresented: Binding(
                get: { pendingSaveDelete != nil }, set: { if !$0 { pendingSaveDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let save = pendingSaveDelete { Task { await deleteSave(save) } }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func stateEnabled(_ state: GameState) -> Bool {
        // Each player can only restore states its own core build wrote,
        // so the list follows the backend choice: native states for the
        // native player, everything the webview's cores wrote otherwise.
        let nativeTag = NativeCore.core(for: rom)?.emulatorTag
        if selectedBackend == .native {
            return nativeTag != nil && state.emulator == nativeTag
        }
        if let nativeTag, state.emulator == nativeTag { return false }
        return state.emulator == nil || state.emulator == selectedCore || state.emulator == "emulatorjs"
    }

    private func stateRow(_ state: GameState) -> some View {
        let enabled = stateEnabled(state)
        return HStack(spacing: 10) {
            Button {
                selectedState = selectedState?.id == state.id ? nil : state
                selectedSave = nil
                if selectedState != nil { continueRun = false }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedState?.id == state.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            selectedState?.id == state.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RommDate.relativeLabel(state.updatedAt)).lineLimit(1)
                        Text(state.emulator.map { "state, \($0)" } ?? "state")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            rowMenu(
                screenshotPath: state.screenshotPath, title: RommDate.relativeLabel(state.updatedAt),
                delete: { pendingStateDelete = state }
            )
        }
        .opacity(deletingAssetIds.contains(state.id) ? 0.4 : 1)
    }

    private func saveRow(_ save: GameSave) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedSave = selectedSave?.id == save.id ? nil : save
                selectedState = nil
                if selectedSave != nil { continueRun = false }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedSave?.id == save.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            selectedSave?.id == save.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RommDate.relativeLabel(save.updatedAt)).lineLimit(1)
                        Text("save").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            rowMenu(
                screenshotPath: save.screenshotPath, title: RommDate.relativeLabel(save.updatedAt),
                delete: { pendingSaveDelete = save }
            )
        }
        .opacity(deletingAssetIds.contains(save.id) ? 0.4 : 1)
    }

    /// A menu button, not `.swipeActions`: this card is a plain stack, not
    /// a `List`, and swipe actions only exist inside one, the pattern iOS
    /// itself reserves for genuine lists of comparable rows, Mail and
    /// Messages among them, not a form of distinct configuration cards like
    /// this screen. A menu is the native answer for a form row, matching
    /// how Settings itself handles a destructive action inline.
    ///
    /// Screenshot is left off the menu entirely when there is none to
    /// show, rather than shown disabled: nothing to act on, nothing to
    /// grey out. The option exists again at all because captures at save
    /// time work now, the frame grabbed on the way into the pause; every
    /// state saved before that fix simply has no screenshot to offer.
    private func rowMenu(
        screenshotPath: String?, title: String, delete: @escaping () -> Void
    ) -> some View {
        Menu {
            if screenshotPath != nil {
                Button("Screenshot", systemImage: "photo") {
                    viewingScreenshot = ScreenshotTarget(path: screenshotPath, title: title)
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
    }

    private func deleteState(_ state: GameState) async {
        deletingAssetIds.insert(state.id)
        defer { deletingAssetIds.remove(state.id) }
        do {
            try await session.deleteStates(ids: [state.id])
            states.removeAll { $0.id == state.id }
            if selectedState?.id == state.id { selectedState = nil }
        } catch {
            DiagnosticsLog.record(
                context: "Delete state", message: error.localizedDescription, romVersion: session.serverVersion
            )
        }
    }

    private func deleteSave(_ save: GameSave) async {
        deletingAssetIds.insert(save.id)
        defer { deletingAssetIds.remove(save.id) }
        do {
            try await session.deleteSaves(ids: [save.id])
            saves.removeAll { $0.id == save.id }
            if selectedSave?.id == save.id { selectedSave = nil }
        } catch {
            DiagnosticsLog.record(
                context: "Delete save", message: error.localizedDescription, romVersion: session.serverVersion
            )
        }
    }

    private func choiceRow(
        label: String, detail: String, selected: Bool, enabled: Bool, tap: @escaping () -> Void
    ) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Data

    private var launchChoices: LaunchChoices {
        LaunchChoices(
            core: selectedCore,
            firmwareId: selectedFirmware?.id,
            // Continuing an interrupted run supersedes any server side
            // choice: the autosave loads over whatever the page booted,
            // so choosing a state as well would just boot into it twice.
            saveId: continueRun ? nil : selectedSave?.id
        )
    }

    private func refreshResumeOffer() {
        if SessionMarker.offersResume(romId: rom.id) {
            interruptedAt = SessionMarker.autosaveDate(romId: rom.id)
            continueRun = true
        } else {
            interruptedAt = nil
            continueRun = false
        }
    }

    private func load() async {
        keptStore.reconcileFilesFolder()
        canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        isComputerPlatform = ComputerPlatforms.contains(canonicalSlug)
        cores = CoreCatalog.cores(for: canonicalSlug)
        selectedCore = LaunchChoices.defaultCore(rom: rom, canonicalSlug: canonicalSlug, from: cores)
        selectedBackend = LaunchChoices.defaultBackend(rom: rom)

        if rom.isArcade {
            let base = ArcadeProfileStore.shared.resolve(shortname: rom.fsNameNoExt)
            arcadeBase = base
            let choice = ArcadeOverride.stored(for: rom.id)
            arcadeButtons = choice?.buttons ?? base.buttons
            arcadeWays = choice?.ways ?? base.ways
        }

        refreshResumeOffer()

        async let firmwareTask = try? session.firmware(platformId: rom.platformId)
        async let savesTask = try? session.saves(romId: rom.id)
        async let statesTask = try? session.states(romId: rom.id)

        let allFirmware = await firmwareTask ?? []
        firmware = allFirmware.filter { !$0.missingFromFS }
        missingFirmware = allFirmware.filter { $0.missingFromFS }
        saves = await savesTask ?? []
        states = (await statesTask ?? []).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }

        // Deliberately no BIOS by default on arcade. Every arcade game
        // shares one platform, so "first verified firmware" meant forcing
        // neogeo.zip onto Cave and Capcom boards that have nothing to do
        // with Neo Geo, and a wrong BIOS stops a game booting entirely.
        // Everywhere else, a platform genuinely has one BIOS every game on
        // it wants, so what was picked last is worth remembering the same
        // way a core choice is.
        selectedFirmware = rom.isArcade ? nil : LaunchChoices.defaultFirmware(platformId: rom.platformId, from: firmware)
        loading = false
    }

    /// Hand-rolled swipe-to-dismiss: `fullScreenCover`, unlike `sheet`, has
    /// no interactive dismiss gesture built in. Only reads a downward drag
    /// as "dismiss" while the scroll content is already at its top, so it
    /// cannot fight normal scrolling further down the screen.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard isScrolledToTop, value.translation.height > 0 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard isScrolledToTop, value.translation.height > 0 else {
                    withAnimation(.spring) { dragOffset = 0 }
                    return
                }
                if value.translation.height > Self.dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring) { dragOffset = 0 }
                }
            }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A grouped card, so the screen reads like Settings rather than a web form.
private struct LaunchCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}
