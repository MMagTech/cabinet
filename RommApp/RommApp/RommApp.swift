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
            } else if ProcessInfo.processInfo.arguments.contains("-cabinetVMUSkin") {
                // The stamped-skin bench: the VMU player straight at the
                // root, for eyeballing the shell against the approved
                // mock in a simulator, where no core can run. The boot
                // alert is dismissed by hand (dismiss on a root view is
                // a no-op) and every frontend-side behavior stays live:
                // the tilting cross, the depressing buttons, SLEEP's
                // fade and z animation, MENU and the LED rules.
                VMUPlayerView(
                    rom: Rom(
                        id: 0, name: "Skin bench", fsName: "skin-bench.chd",
                        fsNameNoTags: "skin-bench", fsNameNoExt: "skin-bench",
                        platformId: 0, platformSlug: "dc", platformFsSlug: "dc",
                        platformDisplayName: "Dreamcast", summary: nil,
                        pathCoverSmall: nil, pathCoverLarge: nil,
                        fsSizeBytes: 0, hasMultipleFiles: false, md5Hash: nil
                    ),
                    cardURL: FileManager.default.temporaryDirectory.appendingPathComponent("skin-bench-card.bin")
                )
                .environmentObject(session)
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
        .onChange(of: session.stage) { _, stage in
            // A fresh pairing has nothing written at all, and somebody
            // may add the widget before they open the app a second time.
            if stage == .ready {
                WidgetWriter.refresh(session: session)
                SpotlightIndexer.refresh(session: session)
            }
        }
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

        #if targetEnvironment(macCatalyst)
        // The Mac's Settings window, opened from the app menu; see
        // MacSettingsWindow. A second scene, which the shared scene
        // manifest already permits for the external display.
        WindowGroup(id: MacSettingsWindow.windowID) {
            MacSettingsWindow()
                .environmentObject(session)
        }
        #endif
    }

    private var appContent: some View {
        #if targetEnvironment(macCatalyst)
        // The PS2 picture cannot be verified by building, and the
        // headless smoke test deliberately draws nothing, so this is
        // the one way to exercise the real render path without a
        // person clicking through sign-in and the library. Inert
        // without its launch argument.
        if let disc = PS2BenchHarness.discPath, !disc.isEmpty {
            return AnyView(PS2BenchView(discPath: disc))
        }
        if let disc = GCBenchHarness.discPath, !disc.isEmpty {
            return AnyView(GCBenchView(discPath: disc))
        }
        #endif
        return AnyView(appShell)
    }

    private var appShell: some View {
        RootView()
            .environmentObject(session)
            #if targetEnvironment(macCatalyst)
            .onAppear { MacWindow.styleAll() }
            // The whole app's type, one dial: a desk sits further from
            // the glass than a hand does, so the Mac reads every
            // semantic font two dynamic-type notches up. Set here so it
            // cascades through every screen and presentation.
            //
            // Two rather than one because Catalyst has already mapped
            // every iOS text style down to Mac metrics before this
            // applies, putting body at 13pt against the phone's 17, so
            // the first notch only undoes part of that.
            .dynamicTypeSize(.xxLarge)
            #endif
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
        // The widget cannot fetch anything itself, so the app has to
        // leave it something current whenever it has a connection. Cheap
        // when nothing changed: unchanged covers are not rewritten.
        WidgetWriter.refresh(session: session)
        // Spotlight likewise, though it gates itself to a daily walk:
        // fourteen hundred games do not change between breakfast and
        // lunch, and the widget's recents do.
        SpotlightIndexer.refresh(session: session)
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
