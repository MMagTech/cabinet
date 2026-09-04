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
    enum AppTab: Hashable { case home, library, search, settings }

    @State private var selection: AppTab = .home
    @ObservedObject private var quickActions = QuickActionRouter.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    #if !os(tvOS)
    @EnvironmentObject private var session: Session
    #endif
    #if targetEnvironment(macCatalyst)
    @Environment(\.openWindow) private var openWindow
    @State private var showingMacAbout = false
    @State private var showingMacDiagnostics = false
    #endif

    var body: some View {
        #if targetEnvironment(macCatalyst)
        // The Mac is the desk-sized member of the tvOS side of the
        // family: one shared ambient backdrop from game art behind the
        // whole shell, always dark, content floating over it. The same
        // Tab structure runs on top unchanged; iOS keeps its own
        // contained-ambient rule (GameLaunchView only) and never
        // compiles this branch.
        ZStack {
            MacAmbientBackground()
            // Not `tabs`: this platform navigates from a source list, and
            // having no tab controller in the window is what keeps
            // Catalyst from hoisting a tab bar into the titlebar. See
            // MacSidebarShell.
            MacSidebarShell()
        }
        .environment(\.colorScheme, .dark)
        // The app menu's Settings… (Cmd+comma) opens the Settings window,
        // a scene of its own; see MacSettingsWindow. About and
        // Diagnostics are sheets on the shell, session injected
        // explicitly, the Catalyst presentation-inheritance lesson.
        .onReceive(NotificationCenter.default.publisher(for: .cabinetShowSettings)) { _ in
            openWindow(id: MacSettingsWindow.windowID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cabinetShowAbout)) { _ in
            showingMacAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cabinetShowDiagnostics)) { _ in
            showingMacDiagnostics = true
        }
        .sheet(isPresented: $showingMacAbout) {
            MacAboutView()
                .environmentObject(session)
                .environment(\.colorScheme, .dark)
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingMacDiagnostics) {
            NavigationStack {
                DebugView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingMacDiagnostics = false }
                        }
                    }
            }
                .environmentObject(session)
                .environment(\.colorScheme, .dark)
                .presentationBackground(.ultraThinMaterial)
        }
        .onReceive(NotificationCenter.default.publisher(for: .cabinetShowAbout)) { _ in
            showingMacAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cabinetShowDiagnostics)) { _ in
            showingMacDiagnostics = true
        }
        .sheet(isPresented: $showingMacAbout) {
            MacAboutView()
                .environmentObject(session)
                .environment(\.colorScheme, .dark)
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingMacDiagnostics) {
            NavigationStack {
                DebugView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingMacDiagnostics = false }
                        }
                    }
            }
                .environmentObject(session)
                .environment(\.colorScheme, .dark)
                .presentationBackground(.ultraThinMaterial)
        }
        #elseif os(tvOS)
        tabs
        #else
        tabs
            // Download All's confirmation, attached once here so a menu
            // on the platform screen or a library tile can raise it.
            .downloadAllPrompt()
            .task {
                // A queue the system quit the app in the middle of
                // carries on; see DownloadAll.
                DownloadAll.shared.resumeIfNeeded(session: session)
                #if DEBUG
                await DownloadAll.runHarnessIfRequested(session: session)
                #endif
            }
        #endif
    }
    // Tried drawing the tvOS account chip as a `ZStack` overlay here so it
    // stayed visible across every tab instead of only Home. Reverted: the
    // system tab bar manages its own focus internally, and once you
    // navigated right onto an overlay drawn merely above it, going back
    // left couldn't re-enter that closed hierarchy, a genuine dead end
    // (confirmed on device). The chip lives back on `HomeView` only now,
    // as a real sibling in that screen's own content flow, reachable by
    // pressing up from the hero with no cross-hierarchy focus hop
    // involved. See `HomeView.wideLayout`.

    private var tabs: some View {
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
                    // tvOS gets its own library screen rather than
                    // LibraryScreen: that one is a List whose Platforms /
                    // Collections switch lives in a toolbar, and neither
                    // survives on a TV. See TVLibraryView's own note.
                    #if os(tvOS)
                    TVLibraryView()
                    #else
                    NavigationStack { LibraryScreen() }
                    #endif
                }
            }
            // The dedicated search role, not just a third ordinary tab:
            // the system draws it apart from the others, matching Music
            // and Photos, and it is why search stops being something you
            // find inside the library.
            Tab(value: AppTab.search, role: .search) {
                SearchScreen()
            }
            // Settings is a real tab on tvOS, where iOS keeps it a toolbar
            // button on Home. That split is deliberate rather than
            // inconsistent: iOS's reasoning was reach, a toolbar corner
            // suits something visited a few times a month. A TV has no
            // toolbar and no thumb, every destination costs the same
            // number of clicks from the tab bar, so the cheap corner iOS
            // was protecting does not exist here. Controller mapping also
            // matters far more on this platform, since a pad is the only
            // way to play at all.
            #if os(tvOS)
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                TVSettingsView()
            }
            #endif
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
