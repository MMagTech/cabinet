import SwiftUI

@main
struct RommApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

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
        // Edits in the Files app happen while this app is not looking,
        // and the moment it can look again is exactly here. Without
        // this, a game deleted in Files kept showing its toggle on
        // until its screen happened to reload.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                KeptGameStore.shared.reconcileFilesFolder()
            }
        }
    }
}
