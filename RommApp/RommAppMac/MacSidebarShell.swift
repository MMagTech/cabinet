#if targetEnvironment(macCatalyst)
import SwiftUI

/// The Mac's window: a source list on the left, whatever it points at on
/// the right.
///
/// This replaces the `TabView` on this platform, and the reason is the
/// titlebar. Catalyst puts a tab bar up there on the traffic lights' own
/// line, a row above everything each screen draws, and it cannot be
/// moved down into the window because it belongs to the titlebar rather
/// than to the content. Every attempt to take it back, hiding it and
/// drawing a replacement picker, clearing the titlebar as UIKit refilled
/// it, was a trick that showed: the picker rebuilt on every switch and
/// the titlebar changed height mid-change. With no tab controller in the
/// window there is nothing to hoist, so none of that has to be fought.
///
/// A source list is also simply what this app is on a Mac. Three rows
/// would be a tab bar turned sideways and would not earn its width, so
/// the sidebar carries the library itself, the way Music and TV carry
/// theirs: every platform and every collection is one click, where the
/// phone needs three. `LibraryScreen` stays reachable above them, both
/// because it owns the grid and the Collections switch and because it is
/// the one view that still works with no connection.
///
/// iOS and tvOS never compile this and keep their real tab bars.
struct MacSidebarShell: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var keptStore = KeptGameStore.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    @State private var selection: MacDestination? = .home
    @State private var platforms: [Platform] = []
    @State private var collections: [Collection] = []

    // Remembered rather than reset each launch, the way a Mac source
    // list remembers. Unsupported starts closed: those platforms cannot
    // play natively, so they are worth having but not worth the length
    // they add to every other visit.
    @AppStorage("com.mmagtech.RommApp.macSidebar.platforms") private var platformsExpanded = true
    @AppStorage("com.mmagtech.RommApp.macSidebar.unsupported") private var unsupportedExpanded = false
    @AppStorage("com.mmagtech.RommApp.macSidebar.collections") private var collectionsExpanded = true

    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    /// What the Downloaded screen will list, not what the store holds:
    /// a kept game with no native core cannot play on this Mac, and a
    /// badge that counts it promises a game the screen never shows.
    private var downloadedCount: Int {
        keptStore.offlinePlatforms().reduce(0) { $0 + $1.roms.count }
    }

    var body: some View {
        NavigationSplitView {
            SidebarColumn { sidebar }
        } detail: {
            detail
        }
        // Balanced, stated: Apple's abstract, "reduces the size of the
        // detail content to make room when showing the leading column".
        // The pushed launch screen came up laid out for the whole
        // window with the sidebar over its cover, the prominent-detail
        // shape, and nothing here should ever sit under the sidebar.
        .navigationSplitViewStyle(.balanced)
        .macDownloadAllPrompt()
        // File > Download All… acts on the platform the sidebar has
        // selected; the menu bar cannot see SwiftUI state, so it is
        // published where the app delegate can read it.
        .onChange(of: selection, initial: true) { _, now in
            if case .platform(let platform)? = now {
                MacChrome.shared.selectedPlatform = (platform, label(for: platform))
            } else {
                MacChrome.shared.selectedPlatform = nil
            }
        }
        .task { await load() }
        #if DEBUG
        // Proves the queue without a hand on the mouse: boots, fetches
        // the platform, starts the queue, cancels it after N seconds,
        // and logs each step. `-cabinetDownloadAll <platformId>
        // -cabinetDownloadAllCancelAt <seconds>`.
        .task {
            let platformId = UserDefaults.standard.integer(forKey: "cabinetDownloadAll")
            guard platformId > 0 else { return }
            while session.stage != .ready { try? await Task.sleep(for: .seconds(1)) }
            await session.loadPlatformConfigIfNeeded()
            let platform = Platform(id: platformId, name: "bench", displayName: nil, slug: "bench", fsSlug: "bench", romCount: 0)
            MacDownloadAll.shared.prepare(platform, name: "bench", session: session)
            while MacDownloadAll.shared.preparing != nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard case .confirm(_, _, let roms, let bytes, let free) = MacDownloadAll.shared.prompt else {
                NSLog("[downloadall] prompt: %@", String(describing: MacDownloadAll.shared.prompt)); return
            }
            NSLog("[downloadall] %d games, %lld bytes, free %lld", roms.count, bytes, free ?? -1)
            MacDownloadAll.shared.prompt = nil
            MacDownloadAll.shared.start(platform: platform, name: "bench", roms: roms, session: session)
            let cancelAt = UserDefaults.standard.integer(forKey: "cabinetDownloadAllCancelAt")
            var tick = 0
            while let bulk = keptStore.bulk {
                NSLog("[downloadall] t=%ds done=%d of %d current=%d failed=%d", tick, bulk.done, bulk.total, bulk.currentRomId ?? -1, bulk.failed)
                if cancelAt > 0, tick == cancelAt { NSLog("[downloadall] cancelling"); keptStore.cancelBulk() }
                try? await Task.sleep(for: .seconds(1)); tick += 1
            }
            NSLog("[downloadall] finished, kept=%d", keptStore.games.count)
            try? await Task.sleep(for: .seconds(1))
            exit(0)
        }
        #endif
        // The lists are a snapshot of the server, so they go stale the
        // same way every other screen's do. Same triggers the library
        // screen already uses.
        .onChange(of: networkMonitor.isConnected) { _, _ in Task { await load() } }
        .onChange(of: networkMonitor.manualOfflineMode) { _, _ in Task { await load() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Home", systemImage: "house").tag(MacDestination.home)
                Label("Library", systemImage: "square.grid.2x2").tag(MacDestination.library)
                // Only once something is on this disk: a row that opens
                // an empty screen is a promise the Mac cannot keep, the
                // same rule the phone's airplane follows.
                if downloadedCount > 0 {
                    Label("Downloaded", systemImage: "arrow.down.circle")
                        .badge(downloadedCount)
                        .tag(MacDestination.downloaded)
                }
                Label("Search", systemImage: "magnifyingglass").tag(MacDestination.search)
            }
            // Above the platforms deliberately. Collections are few and
            // made by hand, platforms are the whole mechanical catalog,
            // so the curated list would otherwise sit below twenty rows
            // of everything else.
            if !collections.isEmpty {
                Section("Collections", isExpanded: $collectionsExpanded) {
                    ForEach(collections) { collection in
                        Label(collection.name, systemImage: collection.isFavorite ? "star" : "folder")
                            .badge(collection.romCount)
                            .tag(MacDestination.collection(collection))
                    }
                }
            }
            // Supported first and named as such, the same split the
            // library screen makes, so the platforms that actually play
            // are not buried among the ones that do not. Every section
            // below the top one collapses, which is what keeps a list
            // this long from being the whole window.
            if !supportedPlatforms.isEmpty {
                Section("Platforms", isExpanded: $platformsExpanded) {
                    ForEach(supportedPlatforms) { row(for: $0) }
                }
            }
            if !unsupportedPlatforms.isEmpty {
                Section("Unsupported", isExpanded: $unsupportedExpanded) {
                    ForEach(unsupportedPlatforms) { row(for: $0) }
                }
            }
        }
        // Explicit rather than inherited: the disclosure triangles that
        // make those sections collapsible are this style's, not the
        // plain list's.
        .listStyle(.sidebar)
        // The List's own selection-aware menu, Apple's API for a
        // source list, rather than a menu on each row: a row-level
        // menu in a selectable List presents twice on Catalyst, the
        // row's UIKit selection adding a second presentation over the
        // first. Found frame by frame, 2026-09-02.
        .contextMenu(forSelectionType: MacDestination.self) { items in
            if let first = items.first, case .platform(let platform) = first {
                MacPlatformMenu(platform: platform, label: label(for: platform))
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) { MacDownloadAllStatus() }
    }

    private func row(for platform: Platform) -> some View {
        // No icon: every row here would carry the same generic one, which
        // is decoration rather than information. The count is the thing
        // worth reading, and a badge is where a Mac source list puts it.
        Text(label(for: platform))
            .badge(platform.romCount)
            .tag(MacDestination.platform(platform))
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        // Home and Search bring their own NavigationStack; the platform
        // and collection lists are bare screens and need one.
        case .home:
            HomeView()
        case .library:
            NavigationStack { LibraryScreen() }
        case .downloaded:
            NavigationStack { MacDownloadedView() }
        case .search:
            SearchScreen()
        // Identified by the source, not left to SwiftUI's structural
        // identity. Picking a different platform changes only the
        // associated value, so the view stays the same instance, and
        // RomListView loads from `.task`, which fires once per instance:
        // without this the games on screen stay the previous platform's.
        // `modeKey` because a platform and a collection can share an id.
        case .platform(let platform):
            NavigationStack { RomListView(source: .platform(platform)) }
                .id(RomListView.Source.platform(platform).modeKey)
        case .collection(let collection):
            NavigationStack { RomListView(source: .collection(collection)) }
                .id(RomListView.Source.collection(collection).modeKey)
        }
    }

    // MARK: Data

    private func load() async {
        // Offline Mode leaves the sidebar as Home, Library and Search.
        // The sections below are the server's catalog and there is
        // nothing honest to put in them; Library is the row that still
        // works, since that screen shows kept games on its own.
        guard !networkMonitor.isOffline else {
            platforms = []
            collections = []
            return
        }
        if let loaded = try? await session.platforms() { platforms = loaded }
        if let loaded = try? await session.collections() { collections = loaded }
    }

    private func isSupported(_ platform: Platform) -> Bool {
        let canonicalSlug = (session.platformsVersions[platform.fsSlug] ?? platform.fsSlug).lowercased()
        return PlatformSupport.isSupported(
            canonicalSlug: canonicalSlug,
            isArcade: PlatformSupport.arcadeSlugs.contains(platform.slug))
    }

    private var supportedPlatforms: [Platform] { platforms.filter(isSupported) }
    private var unsupportedPlatforms: [Platform] { platforms.filter { !isSupported($0) } }

    /// Same rule as the library screen's, so a platform is never called
    /// one thing in the sidebar and another on the screen it opens.
    private func label(for platform: Platform) -> String {
        let metadataName = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let folderName = platform.fsSlug.isEmpty ? nil : platform.fsSlug
        switch labelSource {
        case .platformName: return metadataName ?? folderName ?? platform.slug
        case .folderName: return folderName ?? metadataName ?? platform.slug
        }
    }
}

/// What the sidebar can be pointing at.
enum MacDestination: Hashable {
    case home
    case library
    case downloaded
    case search
    case platform(Platform)
    case collection(Collection)
}
#endif
