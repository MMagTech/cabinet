import SwiftUI

@main
struct RommApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    var body: some Scene {
        WindowGroup {
            // The transport probe for the phone-as-controller idea, taken
            // this early because it needs no session, no server and no
            // pairing, only a radio. Debug builds with no such launch
            // argument evaluate one nil check here and boot normally.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-cabinetLink") {
                ControllerPadView()
            } else if let aim = AimLab.launchRole, case .send = aim {
                AimSenderView()
            } else if let role = NetProbe.launchRole {
                NetProbeView(role: role)
            } else {
                appContent
            }
            #else
            appContent
            #endif
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

    private var appContent: some View {
        RootView()
            .environmentObject(session)
            #if os(iOS)
            // A widget press or a Spotlight result arrives here as a
            // cabinet:// URL. See DeepLink.swift.
            .handlesGameDeepLinks(session: session)
            #endif
            .task {
                // A native core crash takes the whole app, so the only
                // moment it can be counted is the next launch.
                NativeSessionMarker.settleAtLaunch()
            }
    }

    private func syncIfOnline() {
        guard !networkMonitor.isOffline else { return }
        Task {
            let savesUploaded = await KeptGameStore.shared.syncPendingStates(session: session)
            let sessionsUploaded = await session.syncPendingPlaySessions()
            await KeptGameStore.shared.refreshStaleMetadata(session: session)
            if savesUploaded > 0 || sessionsUploaded > 0 {
                session.lastSyncSummary = Self.summaryText(saves: savesUploaded, sessions: sessionsUploaded)
            }
        }
    }

    /// Terse on purpose, matching how every other offline-sync caption in
    /// this app reads: the fact that something uploaded is the whole
    /// message, nothing here needs restating why or how.
    private static func summaryText(saves: Int, sessions: Int) -> String {
        var parts: [String] = []
        if saves > 0 { parts.append(saves == 1 ? "1 save" : "\(saves) saves") }
        if sessions > 0 { parts.append(sessions == 1 ? "1 play session" : "\(sessions) play sessions") }
        return parts.joined(separator: ", ") + " uploaded"
    }
}
