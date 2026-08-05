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
    var body: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                HomeView()
            }
            Tab("Library", systemImage: "square.grid.2x2") {
                NavigationStack { LibraryScreen() }
            }
            // The dedicated search role, not just a third ordinary tab:
            // the system draws it apart from the others, matching Music
            // and Photos, and it is why search stops being something you
            // find inside the library.
            Tab(role: .search) {
                SearchScreen()
            }
        }
        .tabBarMinimized()
    }
}

private extension View {
    /// Shrinking the bar as you scroll down is opt in, not automatic, and
    /// it is iOS 26 only, so it is applied through this rather than
    /// littering the call site with an availability check. On iOS 18 the
    /// bar simply stays put, which is that release's normal behaviour.
    @ViewBuilder
    func tabBarMinimized() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
