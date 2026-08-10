import SwiftUI

/// The app's three destinations, as a real `TabView` rather than a
/// hand-built bottom bar.
///
/// Using the system control is the whole point: on iOS 26 it renders in
/// Liquid Glass, floats over content, shrinks itself as you scroll, and
/// separates the search tab into its own button, none of which is written
/// here. Anything hand-rolled would have to chase all of that and would
/// still look a release behind.
///
/// This replaces two toolbar buttons in Home's top right corner, which put
/// the library and search, the two things reached constantly, at the
/// farthest point from a thumb on a large phone. Settings deliberately
/// stays a toolbar button on Home: reach should track frequency, and it is
/// visited a few times a month, not a few times a session.
///
/// Home stays first and unchanged, so the scope doc's resume-first
/// principle is untouched. That rule is about what Home shows, not about
/// how many taps deep the library sits.
struct MainTabView: View {
    enum AppTab: Hashable { case home, library, search }

    @State private var selection: AppTab = .home
    @ObservedObject private var quickActions = QuickActionRouter.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView()
            }
            // Hidden entirely in Offline Mode, not shown with nothing to
            // browse: its only honest content there is exactly what Home
            // already shows, `OfflineLibraryView`, the one shared view
            // both screens draw from. A second tab pointing at the same
            // screen is just a second way to reach the first (Marcus,
            // 2026-08-07: "if both tabs are the same why two").
            if !networkMonitor.isOffline {
                Tab("Library", systemImage: "square.grid.2x2", value: AppTab.library) {
                    NavigationStack { LibraryScreen() }
                }
            }
            // The dedicated search role, not just a third ordinary tab:
            // the system draws it apart from the others, matching Music
            // and Photos, and it is why search stops being something you
            // find inside the library.
            Tab(value: AppTab.search, role: .search) {
                SearchScreen()
            }
        }
        .tabBarMinimized()
        // This layer's share of a quick action is only choosing the tab.
        // Search is fully done at that point, its screen focuses its own
        // field on appear, so the action is consumed here; the Home bound
        // ones stay pending for HomeView to finish, since resume needs the
        // recents fetch and the lists need a loaded favorites collection.
        .onChange(of: quickActions.pending) { _, action in route(action) }
        .onAppear { route(quickActions.pending) }
        // The tab someone is standing on can vanish out from under them
        // the instant Offline Mode turns on; without this the selection
        // points at a tab that no longer exists.
        .onChange(of: networkMonitor.isOffline) { _, offline in
            if offline, selection == .library { selection = .home }
        }
    }

    private func route(_ action: QuickAction?) {
        guard let action else { return }
        switch action {
        case .search:
            selection = .search
            quickActions.pending = nil
        case .resume, .favorites, .recents:
            selection = .home
        }
    }
}

private extension View {
    /// Shrinking the bar as you scroll down is opt in, not automatic, and
    /// it is iOS 26 only, so it is applied through this rather than
    /// littering the call site with an availability check. On iOS 18 the
    /// bar simply stays put, which is that release's normal behaviour.
    @ViewBuilder
    func tabBarMinimized() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
