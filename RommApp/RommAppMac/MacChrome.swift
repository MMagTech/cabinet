#if targetEnvironment(macCatalyst)
import SwiftUI

/// Whether a screen is currently covering the shell.
///
/// The sidebar toggle is added by `NavigationSplitView` and lives in the
/// window's title bar. A screen presented over the shell has no sidebar
/// to toggle, so it should not be offered one.
final class MacChrome: ObservableObject {
    static let shared = MacChrome()

    @Published var coveringScreenUp = false

    private init() {}
}

/// Wraps the sidebar column and drops its toggle while a screen covers
/// the shell.
///
/// Two things about this are deliberate, and both were learned the hard
/// way. `toolbar(removing:)` goes on the sidebar's own content inside
/// the split view, which is what Apple's documentation for it shows;
/// applied to a presented screen it does nothing until something forces
/// Catalyst to rebuild the title bar, so the button lingers until it is
/// clicked. And the flag is observed HERE rather than by the shell, so a
/// change re-renders only this column. Observing it in the shell
/// re-renders the detail column too, which is what presents the launch
/// screen, and tearing that down as it appears made it open and
/// immediately close.
struct SidebarColumn<Content: View>: View {
    @ObservedObject private var chrome = MacChrome.shared

    @ViewBuilder var content: Content

    var body: some View {
        if chrome.coveringScreenUp {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}
#endif
