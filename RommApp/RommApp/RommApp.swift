import SwiftUI

@main
struct RommApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .task {
                    // A native core crash takes the whole app, so the only
                    // moment it can be counted is the next launch.
                    NativeSessionMarker.settleAtLaunch()
                }
        }
    }
}
