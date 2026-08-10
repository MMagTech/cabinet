import SwiftUI

/// tvOS's own entry point, the sibling of `RommApp.swift`.
///
/// Deliberately thinner: no `AppDelegate`/`UIApplicationDelegateAdaptor`
/// (that exists on iOS only to serve orientation lock and home screen quick
/// actions, neither of which apply to a TV), and none of the Files app /
/// offline-sync wiring `RommApp.swift` does at launch and on scene phase
/// changes, since tvOS's storage model is the transient, same-network cache
/// described in the roadmap rather than a kept-games mirror. Reuses
/// `RootView`/`Session` exactly as iOS does; that is the whole shared core.
@main
struct RommAppTV: App {
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
        }
    }
}
