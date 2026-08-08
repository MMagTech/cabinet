import SwiftUI

@main
struct RommApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

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
                // Unconditional, unlike syncIfOnline below: this makes no
                // network call of its own, only reads
                // session.platformsVersions already sitting in memory
                // from whenever it was last fetched, so gating it behind
                // Offline Mode would block a fix that has nothing to do
                // with being online. Found 2026-08-08: wiring this into
                // syncIfOnline the first time meant it silently never ran
                // at all while Offline Mode was on, exactly the state
                // most likely on screen while someone is testing Offline
                // Mode.
                KeptGameStore.shared.healCanonicalSlugs(session: session)
                syncIfOnline()
            }
        }
        // Automatic, anywhere in the app, matching the rest of Offline
        // Mode: a queued save, or a stub entry from a past format
        // change, should not need its own game's screen revisited,
        // only a connection to actually use.
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            if isConnected { KeptGameStore.shared.healCanonicalSlugs(session: session) }
            syncIfOnline()
        }
        .onChange(of: networkMonitor.manualOfflineMode) { _, isManualOffline in
            if !isManualOffline { KeptGameStore.shared.healCanonicalSlugs(session: session) }
            syncIfOnline()
        }
    }

    private func syncIfOnline() {
        guard !networkMonitor.isOffline else { return }
        Task {
            await KeptGameStore.shared.syncPendingStates(session: session)
            await KeptGameStore.shared.refreshStaleMetadata(session: session)
        }
    }
}
