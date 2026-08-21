import SwiftUI

/// The library: platforms and collections to browse into.
///
/// A tab of its own, reached from the bar rather than pushed from Home.
/// Searching every game lives in `SearchScreen`, its own tab, so this
/// screen is purely about browsing structure.
struct LibraryScreen: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var platforms: [Platform] = []
    @State private var loadingPlatforms = true
    @State private var platformsError: LoadFailure?

    /// Two cover paths per platform tile, keyed by `LibraryTileArt.key`.
    /// Filled in the background after the platform list lands, so the grid
    /// appears immediately and the art fills in rather than the whole
    /// screen waiting on N extra requests.
    @State private var mosaics: [String: [String]] = [:]

    @State private var collections: [Collection] = []
    @State private var loadingCollections = true
    @State private var collectionsError: String?

    @State private var browsing: Browsing = .platforms

    @State private var playing: Rom?

    /// Same toggle as `RomListView`'s, in the same trailing slot, stored
    /// the same way: this screen is a sibling of the game list and the
    /// switch between artwork and rows should feel like one control that
    /// happens to exist on both. One shared key for Platforms and
    /// Collections rather than one each, so the toggle never goes dead
    /// or flips behaviour when the segmented switcher changes.
    @State private var viewMode: ViewMode

    enum ViewMode: String {
        case grid, list
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.viewModeKey)
        _viewMode = State(initialValue: stored.flatMap(ViewMode.init) ?? .grid)
    }

    private static let viewModeKey = "com.mmagtech.RommApp.viewMode.library"

    enum Browsing: String, CaseIterable {
        case platforms = "Platforms", collections = "Collections"
    }

    var body: some View {
        Group {
            switch browsing {
            case .platforms: platformList
            case .collections: collectionList
            }
        }
        // The switcher belongs to the bar, not the page. Sitting in the
        // content it was a chrome shaped control marooned in a content
        // shaped place, which read as leftover layout once there were real
        // floating bars above and below it. In the bar it picks up the
        // system's own material and the list scrolls cleanly underneath.
        //
        // The title goes inline and gives its slot to the switcher rather
        // than stacking both: the tab bar already says Library, so a large
        // title would only repeat it while pushing the list further down.
        .navigationTitle("Library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Browse by", selection: $browsing) {
                    ForEach(Browsing.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarTrailing) {
                // A menu, not a segmented picker, for the same iOS 26
                // glass-nesting reason as RomListView's copy of this
                // control; see the comment there.
                Menu {
                    Picker("View", selection: $viewMode) {
                        Label("Grid", systemImage: "square.grid.3x3").tag(ViewMode.grid)
                        Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                    }
                } label: {
                    Image(systemName: viewMode == .grid ? "square.grid.3x3" : "list.bullet")
                }
            }
            #endif
        }
        .onChange(of: viewMode) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: Self.viewModeKey)
        }
        // No search field here any more: searching every game is its own
        // tab, so a second entry point would be two ways to do one thing,
        // each with its own state.
        .task {
            // Yesterday's picks paint instantly from the disk cache while
            // the live platform list loads; a new day rolls fresh art.
            mosaics = LibraryTileArt.restore(namespace: "ios")
            await loadPlatforms()
        }
        .task { await loadCollections() }
        // Live, not just at the next pull-to-refresh: closes the same gap
        // as Home's own onChange below. loadPlatforms()'s branching was
        // fixed alongside this so a failed live refresh can never hide a
        // platform list already sitting on screen, only correct or add to
        // it once a connection returns.
        .onChange(of: networkMonitor.isConnected) { _, _ in Task { await loadPlatforms() } }
        .onChange(of: networkMonitor.manualOfflineMode) { _, _ in Task { await loadPlatforms() } }
        // GameLaunchView is iOS-only for now; see HomeView.swift for why.
        #if os(iOS)
        .fullScreenCover(item: $playing) { rom in
            NavigationStack { GameLaunchView(rom: rom) }
        }
        #endif
    }

    // MARK: Platforms

    @ViewBuilder
    private var platformList: some View {
        // Checked first, ahead of the live list entirely, and unlike the
        // branches inside that list not gated on `platforms.isEmpty`: a
        // deliberate toggle, or a real signal loss, has to visibly
        // change what this screen shows the moment it happens, not wait
        // for the live list to be empty already. The same view Home
        // shows, not a second one built to look like it (Marcus,
        // 2026-08-07): browsing the full server catalog was always out
        // of scope for offline, but kept games were never meant to be
        // invisible here just because the rest of the catalog is.
        if networkMonitor.isOffline {
            OfflineLibraryView(onRetry: loadPlatforms)
        } else if viewMode == .list {
            List {
                // Every one of these branches is gated on
                // `platforms.isEmpty` too, not just its own flag: a live
                // connectivity change re-runs `loadPlatforms()` on its
                // own (see the onChange above), and a list that already
                // loaded successfully must never vanish behind a loading
                // spinner or an offline banner just because the latest
                // background refresh failed. Nothing here discards good
                // data, only a launch with nothing loaded yet falls
                // through to these.
                if loadingPlatforms, platforms.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your library")
                            .foregroundStyle(.secondary)
                    }
                } else if platformsError == .offline, platforms.isEmpty {
                    OfflineNotice { await loadPlatforms() }
                        .listRowBackground(Color.clear)
                } else if let platformsError, platforms.isEmpty {
                    Text(platformsError.message).foregroundStyle(.red)
                    Button("Try again") { Task { await loadPlatforms() } }
                } else {
                    if !supportedPlatforms.isEmpty {
                        Section("Supported") {
                            ForEach(supportedPlatforms) { platform in
                                platformRow(platform)
                            }
                        }
                    }
                    if !unsupportedPlatforms.isEmpty {
                        Section("Unsupported") {
                            ForEach(unsupportedPlatforms) { platform in
                                platformRow(platform)
                            }
                        }
                    }
                }
            }
            // Inset rows read as cards floating under the bars, where the
            // full width plain style ran straight into them.
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .refreshable { await loadPlatforms() }
        } else {
            ScrollView {
                // Every one of these branches is gated on
                // `platforms.isEmpty` too, not just its own flag: a live
                // connectivity change re-runs `loadPlatforms()` on its
                // own (see the onChange above), and a grid that already
                // loaded successfully must never vanish behind a loading
                // spinner or an offline banner just because the latest
                // background refresh failed. Nothing here discards good
                // data, only a launch with nothing loaded yet falls
                // through to these.
                if loadingPlatforms, platforms.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your library")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                } else if platformsError == .offline, platforms.isEmpty {
                    OfflineNotice { await loadPlatforms() }
                        .padding()
                } else if let platformsError, platforms.isEmpty {
                    VStack(spacing: 12) {
                        Text(platformsError.message).foregroundStyle(.red)
                        Button("Try again") { Task { await loadPlatforms() } }
                    }
                    .padding(.top, 60)
                } else {
                    // Two columns of artwork tiles, the same visual
                    // language as the tvOS platform tile at phone scale.
                    // This was the one screen in the app with no artwork
                    // at all.
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        if !supportedPlatforms.isEmpty {
                            Section {
                                ForEach(supportedPlatforms) { platform in
                                    platformTile(platform)
                                }
                            } header: {
                                gridHeader("Supported")
                            }
                        }
                        if !unsupportedPlatforms.isEmpty {
                            Section {
                                ForEach(unsupportedPlatforms) { platform in
                                    platformTile(platform)
                                }
                            } header: {
                                gridHeader("Unsupported")
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
            .refreshable { await loadPlatforms() }
        }
    }

    /// Styled to match an inset grouped list's section header, which is
    /// what this screen used before the grid and what the Collections
    /// list beside it still uses.
    private func gridHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.footnote)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 4)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    private func platformRow(_ platform: Platform) -> some View {
        NavigationLink {
            RomListView(source: .platform(platform))
        } label: {
            HStack {
                Text(platformLabel(for: platform))
                Spacer()
                Text("\(platform.romCount)")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private func platformTile(_ platform: Platform) -> some View {
        tile(
            title: platformLabel(for: platform),
            count: platform.romCount,
            coverKey: LibraryTileArt.key(platform: platform),
            source: .platform(platform)
        )
    }

    private func collectionTile(_ collection: Collection) -> some View {
        tile(
            title: collection.name,
            count: collection.romCount,
            coverKey: LibraryTileArt.key(collection: collection),
            source: .collection(collection)
        )
    }

    private func tile(
        title: String, count: Int, coverKey: String, source: RomListView.Source
    ) -> some View {
        let covers = mosaics[coverKey] ?? []
        return NavigationLink {
            RomListView(source: source)
        } label: {
            ZStack(alignment: .bottomLeading) {
                tileBackdrop(covers: covers)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    Text("\(count) games")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
                .padding(11)
            }
            .frame(height: 96)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .animation(.easeOut(duration: 0.35), value: covers)
        }
        .buttonStyle(.plain)
    }

    /// The tile's art: two covers filling the trailing side edge to edge,
    /// with the label zone kept a flat opaque panel that fades out over
    /// the art. Proportional, never fixed points: the label zone is a
    /// fraction of the tile's own width, so the same tile works on any
    /// phone or pad width. The lesson came from the tvOS tile, where
    /// fixed widths squeezed "Arcade" until it hyphenated.
    private func tileBackdrop(covers: [String]) -> some View {
        GeometryReader { geo in
            // Where the covers start, as a fraction of the tile. The
            // label overhangs into the faded region for long names, which
            // is why the gradient's first stretch stays mostly opaque.
            let labelZone = geo.size.width * 0.42
            ZStack(alignment: .leading) {
                Self.panel
                if !covers.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(covers.prefix(2).enumerated()), id: \.offset) { _, path in
                            CoverImage(path: path, title: "", showsPlaceholder: false)
                                .frame(
                                    width: (geo.size.width - labelZone) / 2,
                                    height: geo.size.height
                                )
                                .clipped()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    // A solid fill for the label zone rather than the
                    // gradient's own opaque stop: on the tvOS tile an
                    // interpolated "opaque" stop left a per-platform
                    // hairline of art color at the tile's edge, and a
                    // plain Rectangle has no interpolation to get wrong.
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Self.panel)
                            .frame(width: labelZone)
                        LinearGradient(
                            stops: [
                                .init(color: Self.panel, location: 0),
                                .init(color: Self.panel.opacity(0.8), location: 0.28),
                                .init(color: Self.panel.opacity(0), location: 0.8),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// The same panel value the tvOS tile settled on, and deliberately
    /// darker and less saturated than the approved mockup's purple: the
    /// same sRGB values render far more vividly on a wide-gamut display,
    /// which is how the first tvOS build came out a loud electric purple.
    private static let panel = Color(red: 0.14, green: 0.10, blue: 0.24)

    /// A platform this app can actually put a Play button in front of:
    /// not a keyboard machine, per `ComputerPlatforms`, and RomM's own core
    /// map, `Resources/cores.json`, actually lists a core for it. Dreamcast
    /// and Flash fail this the same way a keyboard machine does, just for a
    /// different reason, no core exists at all rather than no touch input.
    private func isSupported(_ platform: Platform) -> Bool {
        let canonicalSlug = (session.platformsVersions[platform.fsSlug] ?? platform.fsSlug).lowercased()
        return PlatformSupport.isSupported(
            canonicalSlug: canonicalSlug,
            isArcade: PlatformSupport.arcadeSlugs.contains(platform.slug))
    }

    private var supportedPlatforms: [Platform] { platforms.filter(isSupported) }
    private var unsupportedPlatforms: [Platform] { platforms.filter { !isSupported($0) } }

    private func loadPlatforms() async {
        loadingPlatforms = true
        platformsError = nil
        // Real suppression, not a cosmetic switch: manual offline mode
        // must actually stop this screen from touching the network, the
        // same reason GameLaunchView and Home both skip their own
        // fetches outright rather than just hiding the result. Whatever
        // list already loaded stays exactly as it was, per the branching
        // in platformList above.
        guard !networkMonitor.isOffline else {
            platformsError = LoadFailure(RommError.offline)
            loadingPlatforms = false
            return
        }
        // A no-op once a real mapping exists; the recovery path for a
        // launch that started with no connection, so Supported and
        // Unsupported settle correctly the first time this screen is
        // visited or refreshed with a connection, rather than staying
        // wrong for the rest of the session.
        await session.loadPlatformConfigIfNeeded()
        do {
            platforms = try await session.platforms()
                .sorted { platformLabel(for: $0) < platformLabel(for: $1) }
            await loadTileArt()
        } catch {
            platformsError = LoadFailure(error)
            DiagnosticsLog.record(
                context: "Library load", message: error.localizedDescription, romVersion: session.serverVersion
            )
        }
        loadingPlatforms = false
    }

    /// Unsupported platforms get art too: on iOS "unsupported" only means
    /// no native core, and those games still play through the webview
    /// player, so their tiles are not a dead end the way they would be
    /// on tvOS.
    private func loadTileArt() async {
        let fresh = await LibraryTileArt.load(
            platforms: platforms, collections: collections,
            existing: mosaics, session: session
        )
        guard !fresh.isEmpty else { return }
        mosaics.merge(fresh) { _, new in new }
        LibraryTileArt.persist(mosaics, namespace: "ios")
    }

    // MARK: Collections

    @ViewBuilder
    private var collectionList: some View {
        if viewMode == .list {
            List {
                if loadingCollections {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your collections")
                            .foregroundStyle(.secondary)
                    }
                } else if let collectionsError {
                    Text(collectionsError).foregroundStyle(.red)
                    Button("Try again") { Task { await loadCollections() } }
                } else if collections.isEmpty {
                    Text("No collections yet. Make one in RomM to see it here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(collections) { collection in
                        collectionRow(collection)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.plain)
            #endif
            .refreshable { await loadCollections() }
        } else {
            ScrollView {
                if loadingCollections {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading your collections")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 60)
                } else if let collectionsError {
                    VStack(spacing: 12) {
                        Text(collectionsError).foregroundStyle(.red)
                        Button("Try again") { Task { await loadCollections() } }
                    }
                    .padding(.top, 60)
                } else if collections.isEmpty {
                    Text("No collections yet. Make one in RomM to see it here.")
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                        .padding(.horizontal)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                        spacing: 10
                    ) {
                        ForEach(collections) { collection in
                            collectionTile(collection)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .refreshable { await loadCollections() }
        }
    }

    private func collectionRow(_ collection: Collection) -> some View {
        NavigationLink {
            RomListView(source: .collection(collection))
        } label: {
            HStack {
                Text(collection.name)
                Spacer()
                Text("\(collection.romCount)")
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
        }
    }

    private func loadCollections() async {
        loadingCollections = true
        collectionsError = nil
        do {
            collections = try await session.collections()
                .sorted { $0.name < $1.name }
            // Runs from both load paths; LibraryTileArt.load skips tiles
            // that already have art, so whichever list lands second only
            // fetches its own.
            await loadTileArt()
        } catch {
            collectionsError = error.localizedDescription
        }
        loadingCollections = false
    }

    /// Same choice as `Rom.platformLabel`, for a `Platform` itself rather
    /// than a rom: no per-rom display name to fall through, only the
    /// metadata name and the folder it was scanned from.
    private func platformLabel(for platform: Platform) -> String {
        let metadataName = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let folderName = platform.fsSlug.isEmpty ? nil : platform.fsSlug
        switch labelSource {
        case .platformName: return metadataName ?? folderName ?? platform.slug
        case .folderName: return folderName ?? metadataName ?? platform.slug
        }
    }
}
