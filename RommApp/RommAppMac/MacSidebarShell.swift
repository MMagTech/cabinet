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

    var body: some View {
        NavigationSplitView {
            SidebarColumn { sidebar }
        } detail: {
            detail
        }
        .task { await load() }
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
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
    case search
    case platform(Platform)
    case collection(Collection)
}
#endif
