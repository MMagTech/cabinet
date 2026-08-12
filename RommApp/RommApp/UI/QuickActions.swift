import SwiftUI
import UIKit

/// The home screen quick actions: long press the app icon, jump straight to
/// a place inside it. Four, because iOS shows at most four, chosen by what
/// actually skips steps rather than what exists: Resume is the app's whole
/// thesis, Search is "I know what I want" from the home screen into a
/// focused field, Favorites and Recents are the two lists games actually
/// get launched from. Platforms and Collections lost their slots for being
/// one tap from the Library tab anyway.
///
/// Deliberately static labels, "Resume" not "Resume Shinobi": Marcus's
/// call, and it makes the whole set registrable once at launch with no
/// update-on-every-play bookkeeping.
enum QuickAction: String {
    case resume, search, favorites, recents

    // Home screen quick actions do not exist on tvOS: there is no icon to
    // long press. The type stays shared so `QuickActionRouter` compiles
    // and reads the same on both platforms, only `pending` just never gets
    // set to anything on tvOS.
    #if os(iOS)
    static func register() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(
                type: QuickAction.resume.rawValue, localizedTitle: "Resume",
                localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "play.fill")
            ),
            UIApplicationShortcutItem(
                type: QuickAction.search.rawValue, localizedTitle: "Search",
                localizedSubtitle: nil, icon: UIApplicationShortcutIcon(type: .search)
            ),
            UIApplicationShortcutItem(
                type: QuickAction.favorites.rawValue, localizedTitle: "Favorites",
                localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "star")
            ),
            UIApplicationShortcutItem(
                type: QuickAction.recents.rawValue, localizedTitle: "Recents",
                localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "clock")
            ),
        ]
    }
    #endif
}

/// The pending action, observed by whichever screen can complete it.
///
/// A shortcut tap arrives at the app's outermost layer (the scene
/// delegate) but has to finish deep inside a specific screen: the tab bar
/// switches tabs, then Home triggers the resume or pushes a list, then
/// clears it. Held rather than dispatched because the destination may not
/// exist yet at the moment of the tap: a cold start sets this before any
/// view has appeared, and Home's resume needs the recents fetch to land
/// first, so each consumer takes the action when, and only when, it is
/// actually able to act on it.
@MainActor
final class QuickActionRouter: ObservableObject {
    static let shared = QuickActionRouter()
    @Published var pending: QuickAction?
}

/// Bridges UIKit's shortcut delivery into the router. SwiftUI's own
/// lifecycle has no hook for shortcut items, so the app delegate names
/// this class as the scene delegate and the two callbacks below are the
/// entire UIKit surface: one for taps while the app is running, one for
/// taps that cold start it.
#if os(iOS)
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene, willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem {
            QuickActionRouter.shared.pending = QuickAction(rawValue: item.type)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActionRouter.shared.pending = QuickAction(rawValue: shortcutItem.type)
        completionHandler(true)
    }
}
#endif
