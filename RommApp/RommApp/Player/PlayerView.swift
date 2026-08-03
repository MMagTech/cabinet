import AVFoundation
import SwiftUI
import WebKit

/// The player. A full screen webview running RomM's own EmulatorJS page at
/// `/rom/{id}/ejs`. The page is not reimplemented, exactly as the scope doc
/// insists: RomM already knows how to pick cores, wire saves, and cache ROMs
/// into IndexedDB. This screen's job is to host it well on iOS.
///
/// The details below are each load bearing. Removing one produces a failure
/// that looks like an app bug: the ringer switch silencing games, the screen
/// locking mid session, or a stray edge swipe killing the run.
struct PlayerView: View {
    let rom: Rom
    /// What the native launch screen chose. Defaults to standing aside, so
    /// any caller that does not care keeps the old behaviour exactly.
    var launch: LaunchChoices = .none
    /// True when the launch screen offered to continue an interrupted
    /// session and the person took it: once the game starts, the local
    /// autosave is loaded over it, the same path crash recovery uses.
    var resumeFromAutosave: Bool = false

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var context: (url: URL, token: String)?
    @State private var failed = false
    @State private var overlayVisible = true
    @State private var gameStarted = false
    @State private var recovering = false
    /// The game is frozen and the pause menu is up. The freeze happens on
    /// the tap that opens the menu, not after choosing something in it,
    /// because a pause that arrives late is a death in anything that
    /// shoots back.
    @State private var pauseMenuVisible = false
    /// When the game actually began, for the session reported on the way
    /// out. Nil until it starts, so closing a player that never loaded
    /// reports nothing.
    @State private var startedAt: Date?
    /// Loading throws away everything since the save, and the button sits
    /// inches from Resume in a menu people stab at under pressure. A
    /// misfire would cost the run the save was protecting.
    @State private var confirmingLoad = false
    @StateObject private var input = PlayerInputBridge()
    @ObservedObject private var controllers = GameControllerManager.shared
    /// The scope doc's bet: the opacity slider matters more than any theme.
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7

    var body: some View {
        GeometryReader { geometry in
            content(size: geometry.size)
        }
    }

    private func content(size: CGSize) -> some View {
        let isLandscape = size.width > size.height
        return content(isLandscape: isLandscape, size: size)
    }

    private func content(isLandscape: Bool, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let context {
                // The black backdrop bleeds under the Dynamic Island and home
                // indicator, but the page itself stays inside the safe area.
                // Rendered full bleed, the top of the game canvas sits under
                // the island and gets clipped on every notched device.
                //
                // Once the game starts, the webview yields its bottom to the
                // native controls so the canvas sits above them, never behind.
                // Free for horizontal games, essential for vertical ones: a
                // TATE canvas like DoDonPachi is taller than wide and would
                // otherwise extend under the pad. EmulatorJS refits the canvas
                // to the shrunken viewport on its own.
                PlayerWebView(
                    url: context.url,
                    token: context.token,
                    launch: launch,
                    rom: rom,
                    pad: padConfiguration(isLandscape: isLandscape),
                    resumeFromAutosave: resumeFromAutosave,
                    padSystem: controlLayout?.system ?? "",
                    overlayVisible: $overlayVisible,
                    gameStarted: $gameStarted,
                    recovering: $recovering,
                    input: input
                )
            } else if failed {
                VStack(spacing: 12) {
                    Text("Could not start the player.")
                        .foregroundStyle(.white)
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // The curtain for a killed web process. Recovery works, but
            // watching it work reads as the app crashing: RomM's page
            // visibly reloads, loading bars included, before the restored
            // game snaps in. Covering that with a calm native screen turns
            // the same seconds into a handled hiccup. Opaque and above
            // everything, including the touch pad, which is useless until
            // the game is back anyway.
            if recovering {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                        Text("Getting you back in the game")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .transition(.opacity)
            }

            // The pause menu, over a frozen machine. Everything here can be
            // chosen at leisure because the emulator stopped the moment the
            // menu opened.
            if pauseMenuVisible {
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { resumeFromMenu() }
                    VStack(spacing: 18) {
                        VStack(spacing: 4) {
                            Text(rom.displayName)
                                .font(.headline)
                                .lineLimit(1)
                            Text("Paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        VStack(spacing: 10) {
                            Button {
                                resumeFromMenu()
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                input.saveStateToServer()
                                resumeFromMenu()
                            } label: {
                                Label("Save state", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            // Only when there is something to go back to,
                            // and only from the core that made it: a state
                            // one core wrote cannot be read by another, so
                            // a stale button would promise a rescue it
                            // could not perform.
                            if ManualSave.date(romId: rom.id) != nil {
                                Button {
                                    confirmingLoad = true
                                } label: {
                                    Label("Load last save", systemImage: "arrow.uturn.backward")
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                }
                                .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) {
                                SessionMarker.recordCleanExit()
                                dismiss()
                            } label: {
                                Label("Quit", systemImage: "xmark")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: 280)
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 20))
                    .padding(40)
                }
                .transition(.opacity)
            }

            // Fades in step with EmulatorJS's menu toggle so nothing sits
            // over the game during play. A tap on the game canvas brings
            // both back, mirroring the injected idle logic.
            Button {
                // Cleared here as well as in onDisappear: the launch screen
                // refreshes its continue offer the moment dismissal starts,
                // and onDisappear only runs when the animation ends, so
                // clearing only there loses the race and the offer to rewind
                // a deliberate exit flashes back up.
                SessionMarker.recordCleanExit()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(10)
                    .background(.black.opacity(0.35), in: .circle)
            }
            .padding(.top, 8)
            .padding(.leading, 8)
            .opacity(overlayVisible ? 1 : 0)
            .allowsHitTesting(overlayVisible)
            .animation(.easeInOut(duration: 0.35), value: overlayVisible)
        }
        .animation(.easeInOut(duration: 0.3), value: recovering)
        .animation(.easeInOut(duration: 0.15), value: pauseMenuVisible)
        .confirmationDialog(
            "Go back to your last save?",
            isPresented: $confirmingLoad,
            titleVisibility: .visible
        ) {
            Button("Load it", role: .destructive) {
                input.loadLastState()
                resumeFromMenu()
            }
        } message: {
            // The timestamp belongs here, at the moment of deciding, rather
            // than crammed under a button label as a second line. iOS
            // buttons are one line; dialogs are where the detail goes.
            if let saved = ManualSave.date(romId: rom.id) {
                Text("Saved at \(saved.formatted(date: .omitted, time: .shortened)). Everything since then is lost.")
            } else {
                Text("Everything since then is lost.")
            }
        }
        // A dead web process takes the paused game with it; recovery will
        // boot and restore, and a stale pause card over that would offer
        // choices about a machine that no longer exists.
        .onChange(of: gameStarted) { _, started in
            if !started { pauseMenuVisible = false }
        }
        // Tell the server this game is being played, so it reaches Home's
        // resume list and RomM's own. Repeated while the session lasts,
        // since the server treats these as a liveness signal rather than a
        // single event, and a long session should not look like it ended
        // two minutes in.
        .task(id: gameStarted) {
            guard gameStarted else { return }
            if startedAt == nil { startedAt = Date() }
            while !Task.isCancelled {
                await session.reportPlaying(romId: rom.id)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        // The two moments iOS is most likely to kill the webview's content
        // process are a rotation, which spikes memory while WebKit relays
        // everything out, and the app leaving the foreground. An autosave
        // fired at each moment bounds what a kill can cost to seconds,
        // instead of whatever the periodic save happened to capture.
        .onChange(of: isLandscape) { _, _ in
            if gameStarted { input.autosaveNow() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active, gameStarted else { return }
            input.autosaveNow()
        }
        .task {
            // A game is played in the orientation it was started in. See
            // OrientationLock for why honouring rotation mid game was
            // worse than refusing it.
            OrientationLock.lockToCurrent()
            configureAudioSession()
            UIApplication.shared.isIdleTimerDisabled = true

            controllers.send = { id, down in input.send(id: id, down: down) }
            // Menu means pause now, from either input world: the pad's Menu
            // pill and a controller's Menu button both freeze the game on
            // the press and open the same native menu.
            controllers.onMenu = { showPauseMenu() }
            input.onMenu = { showPauseMenu() }
            // Nobody is holding anything after a disconnect, so stop the
            // game rather than letting it run on unattended. The touch
            // controls reappear on their own.
            controllers.onDisconnect = { input.pauseGame() }
            controllers.start()

            if let context = await session.playerContext(for: rom) {
                self.context = context
            } else {
                failed = true
            }
        }
        .onDisappear {
            // Report the finished session on a task of its own rather than
            // the view's, which is being torn down: a .task here would be
            // cancelled before the request left.
            if let startedAt {
                let session = session
                let romId = rom.id
                Task { await session.reportPlaySession(romId: romId, start: startedAt, end: Date()) }
            }
            // The one deliberate way out. An evicted app never runs this,
            // which is exactly how the next launch can tell the difference.
            SessionMarker.recordCleanExit()
            OrientationLock.unlock()
            UIApplication.shared.isIdleTimerDisabled = false
            // Detach this screen's callbacks without stopping the shared
            // manager, which Settings and the remap screen also use.
            controllers.send = nil
            controllers.onMenu = nil
            controllers.onDisconnect = nil
        }
    }

    /// Console layouts are bundled files keyed by platform. Arcade layouts
    /// are per game: the romset shortname resolves through the bundled MAME
    /// profile map and the layout is built from what the cabinet had.
    private var controlLayout: ControlLayout? {
        if rom.isArcade {
            let profile = ArcadeProfileStore.shared.resolve(
                romId: rom.id, shortname: rom.fsNameNoExt
            )
            return ArcadeLayout.build(for: profile)
        }
        return ControlLayout.forPlatform(slug: rom.platformSlug)
    }

    /// Touch controls show only while a game is running and no physical
    /// controller has taken over. When a pad is connected the strip is not
    /// merely hidden, the space goes back to the game.
    private var showsTouchControls: Bool {
        gameStarted && !controllers.isConnected && controlLayout != nil
    }

    /// What the container should do with the touch pad. The pad lives inside
    /// the same UIKit hierarchy as the webview now: as SwiftUI siblings the
    /// webview won every touch wherever the two overlapped, which in
    /// landscape is everywhere, and the controls drew perfectly while
    /// receiving nothing. Same hierarchy makes the layering a guarantee
    /// instead of a negotiation between frameworks.
    private func padConfiguration(isLandscape: Bool) -> PlayerWebView.PadConfiguration {
        guard showsTouchControls, let layout = controlLayout else { return .hidden }
        if isLandscape {
            return .overlay(items: layout.items(landscape: true), opacity: controlOpacity)
        }
        return .bottomStrip(
            items: layout.items(landscape: false),
            height: controlStripHeight,
            opacity: controlOpacity
        )
    }

    /// Vertical games trade some control height for canvas: their picture is
    /// taller than wide and every point matters, while their genres, mostly
    /// shooters, need fewer and simpler inputs.
    private var controlStripHeight: CGFloat {
        if rom.isArcade,
           ArcadeProfileStore.shared.resolve(
               romId: rom.id, shortname: rom.fsNameNoExt
           ).vertical {
            return 280
        }
        return 330
    }

    private func showPauseMenu() {
        guard gameStarted, !pauseMenuVisible else { return }
        input.pauseGame()
        pauseMenuVisible = true
    }

    private func resumeFromMenu() {
        pauseMenuVisible = false
        input.resumeGame()
    }

    /// `.playback` or the phone's ringer switch silences the game.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

/// Hands native control presses to the emulator inside the webview.
///
/// EmulatorJS exposes gameManager.simulateInput(player, id, value), the same
/// call its own touch and gamepad paths use, settling scope doc open item 2:
/// there is a real input method, and synthetic KeyboardEvents are not needed.
final class PlayerInputBridge: ObservableObject {
    weak var webView: WKWebView?
    /// The touch pad's Menu control lands here rather than in the emulator:
    /// it is not a game input, it is the person asking for the pause menu.
    var onMenu: (() -> Void)?

    /// Sends one input change to the emulator.
    ///
    /// The expression is kept as short as it can possibly be because this
    /// is the hottest path in the app: every direction change and every
    /// button edge crosses here, and each call is an IPC hop plus a fresh
    /// script compile inside the web process. The resident helper is
    /// installed once at document start, so what gets compiled per press is
    /// a dozen characters rather than a hundred and ten with three property
    /// lookups. Nothing about the emulator side changes.
    func send(id: Int, down: Bool) {
        webView?.evaluateJavaScript("__ci(\(id),\(down ? 1 : 0))")
    }

    /// Reveals the overlay from native code, for controllers with no screen
    /// to tap. The page then reports visibility back the usual way.
    func wakeOverlay() {
        webView?.evaluateJavaScript(
            "window.__rommWakeOverlay && window.__rommWakeOverlay();"
        )
    }

    /// Pauses the running game: the pause menu opening, or a controller
    /// disconnecting mid play.
    func pauseGame() {
        webView?.evaluateJavaScript(
            "window.EJS_emulator && !EJS_emulator.paused && EJS_emulator.pause();"
        )
    }

    func resumeGame() {
        webView?.evaluateJavaScript(
            "window.EJS_emulator && EJS_emulator.paused && EJS_emulator.play();"
        )
    }

    /// Saves the frozen moment to RomM as a real server state, through the
    /// page's own upload hook, so it appears on the launch screen next time
    /// like any state made through EmulatorJS's menu.
    func saveStateToServer() {
        webView?.evaluateJavaScript(
            "window.__cabinetMenuSave && __cabinetMenuSave();"
        )
    }

    /// Puts back the last state banked from the pause menu.
    func loadLastState() {
        webView?.evaluateJavaScript(
            "window.__cabinetLoadManual && __cabinetLoadManual();"
        )
    }

    /// Writes an autosave state right now, ahead of a moment that might kill
    /// the webview's content process.
    func autosaveNow() {
        webView?.evaluateJavaScript(
            "window.__cabinetAutosaveNow && __cabinetAutosaveNow();"
        )
    }

}

struct PlayerWebView: UIViewRepresentable {
    /// Where the touch pad sits relative to the game, decided by the host.
    enum PadConfiguration {
        case hidden
        /// Full screen pad over the canvas, controls in the gutters.
        case overlay(items: [ControlLayout.Item], opacity: Double)
        /// Pad below the canvas, the portrait arrangement.
        case bottomStrip(items: [ControlLayout.Item], height: CGFloat, opacity: Double)
    }

    let url: URL
    let token: String
    let launch: LaunchChoices
    let rom: Rom
    let pad: PadConfiguration
    var resumeFromAutosave: Bool = false
    /// The layout's system name, which decides the control colours.
    var padSystem: String = ""
    @Binding var overlayVisible: Bool
    @Binding var gameStarted: Bool
    @Binding var recovering: Bool
    let input: PlayerInputBridge

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let parent: PlayerWebView
        /// Set while a game start should pull the autosave back in: either a
        /// reload recovering from a dead content process, or a launch the
        /// person explicitly asked to continue. Never set by a plain launch,
        /// which must respect the launch screen's choices.
        private var pendingRecovery: Bool
        /// How old an autosave the restore may use. Crash recovery keeps it
        /// tight, because there the person chose nothing and a wrong restore
        /// is a surprise. An accepted continue offer widens it to the same
        /// half day the offer itself allows.
        private var recoveryWindowMs = 300_000
        /// When each recovery happened this session.
        ///
        /// This used to be a plain count capped at three, written when a
        /// killed web process looked like a rare accident. It is not rare:
        /// the same kill reproduces in Safari with none of this app
        /// involved, roughly once a minute of play, so a cap of three
        /// meant the fourth kill of a long session stranded the player on
        /// a dead screen. What actually needs guarding against is a reload
        /// loop, where recovery itself is what kills the process, and that
        /// looks completely different: several deaths within seconds of
        /// each other rather than a steady drumbeat minutes apart.
        private var recoveryTimes: [Date] = []

        init(_ parent: PlayerWebView) {
            self.parent = parent
            pendingRecovery = parent.resumeFromAutosave
            if parent.resumeFromAutosave { recoveryWindowMs = 43_200_000 }
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "overlay":
                if let visible = message.body as? Bool {
                    parent.overlayVisible = visible
                }
            case "gameState":
                if message.body as? String == "started" {
                    parent.gameStarted = true
                    SessionMarker.recordGameRunning(romId: parent.rom.id)
                    resumeAfterRecovery(in: message.webView)
                    if !pendingRecovery {
                        // Nothing is going to be restored, so last
                        // session's state is dead weight in this origin's
                        // storage. Drop it before this session starts
                        // writing its own.
                        message.webView?.evaluateJavaScript(
                            "window.__cabinetDropAutosave && __cabinetDropAutosave();"
                        )
                    }
                }
            case "autosave":
                SessionMarker.recordAutosave(romId: parent.rom.id)
            case "frame":
                if let dataURL = message.body as? String {
                    LastFrame.save(dataURL: dataURL, romId: parent.rom.id)
                }
            // The outcome of the last menu save, kept because a phone in a
            // hand has no console: when someone says saving did nothing,
            // this answers with the status code it got.
            case "manualSave":
                ManualSave.record(romId: parent.rom.id)
            case "vitals":
                if let line = message.body as? String {
                    EmulationInfo.recordVitals(line)
                }
            case "saveResult":
                UserDefaults.standard.set(
                    "\(String(describing: message.body)) rom \(parent.rom.id)",
                    forKey: "com.mmagtech.RommApp.lastStateSave"
                )
            case "diag":
                // Recorded rather than logged, because a console cannot be
                // attached to a phone someone is actually holding and using.
                if let text = message.body as? String {
                    UserDefaults.standard.set(text, forKey: EmulationInfo.key)
                }
            default:
                break
            }
        }

        /// The web process died, taking the running emulator with it.
        ///
        /// This is not something the app causes and not something it can
        /// prevent: the same kill reproduces in Safari on the same phone,
        /// with the same core and none of this app's code, about a minute
        /// into playing. So the job here is not to stop it happening, it
        /// is to make it cost as little as possible. The page is reloaded
        /// deliberately, the launch seeds and auto start press Play again,
        /// and once the game reports started the autosave from just before
        /// the kill is loaded, so play resumes near where it stopped.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            EmulationInfo.recordRecovery()
            EmulationInfo.freezeVitalsAtDeath()
            Compatibility.shared.recordCrash(romId: parent.rom.id)
            parent.gameStarted = false

            // Recovery is unlimited by design, because the deaths are
            // unlimited. Only a genuine reload loop, three deaths inside
            // half a minute, is worth giving up on: a steady kill every
            // minute is survivable forever and stopping would strand
            // someone mid session.
            let now = Date()
            recoveryTimes.append(now)
            recoveryTimes = recoveryTimes.filter { now.timeIntervalSince($0) < 30 }
            guard recoveryTimes.count < 3 else {
                parent.recovering = false
                return
            }
            pendingRecovery = true
            recoveryWindowMs = 300_000
            parent.recovering = true
            var request = URLRequest(url: parent.url)
            request.setValue("Bearer \(parent.token)", forHTTPHeaderField: "Authorization")
            webView.load(request)

            // If the game is not back inside a minute, something beyond a
            // process kill is wrong, and a stuck curtain would hide both
            // the page's own error and the way out. Lifting it is safe at
            // any time; it only covers, it never controls.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.parent.recovering = false
            }
        }

        /// A short settle delay before loading the state: the core has only
        /// just started and FBNeo needs a beat before a full machine state
        /// lands cleanly.
        private func resumeAfterRecovery(in webView: WKWebView?) {
            guard pendingRecovery else { return }
            pendingRecovery = false
            let window = recoveryWindowMs
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                webView?.evaluateJavaScript(
                    "window.__cabinetRecover && __cabinetRecover(\(window));"
                ) { _, _ in
                    // The state lands within a frame or two of the call;
                    // the extra beat lets the restored picture render
                    // before the curtain fades from over it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.parent.recovering = false
                    }
                }
            }
        }
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        // RomM's player authenticates through the session cookie its web login
        // sets. This app holds a bearer token instead, and the backend's
        // HybridAuthBackend accepts bearer on every endpoint. So every request
        // the page makes to this server gets the token attached before it
        // leaves: fetch and XHR both, which covers the SPA's API calls and
        // EmulatorJS downloading the ROM through /api/roms/{id}/content.
        let script = WKUserScript(
            source: Self.authInjection(token: token),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(script)

        // Seed RomM's own storage with what the launch screen chose, before
        // its page reads any of it, then press its Play button once the page
        // is ready. Both are skipped when the launch screen stood aside.
        let seed = launch.injection(for: rom)
        if !seed.isEmpty {
            config.userContentController.addUserScript(
                WKUserScript(source: seed, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
            config.userContentController.addUserScript(
                WKUserScript(
                    source: Self.autoStartInjection(
                        expecting: launch.core,
                        // Proof that the seeded core was applied only means
                        // something when there was a choice to get wrong.
                        verifyCore: CoreCatalog.cores(for: rom.platformSlug).count > 1
                    ),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.recoveryInjection(
                    romId: rom.id, autosaveEnabled: PlayerAutosave.isEnabled
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        config.userContentController.add(context.coordinator, name: "overlay")
        config.userContentController.add(context.coordinator, name: "gameState")
        config.userContentController.add(context.coordinator, name: "diag")
        config.userContentController.add(context.coordinator, name: "autosave")
        config.userContentController.add(context.coordinator, name: "frame")
        config.userContentController.add(context.coordinator, name: "saveResult")
        config.userContentController.add(context.coordinator, name: "manualSave")
        config.userContentController.add(context.coordinator, name: "vitals")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        input.webView = webView
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        // No bounce, no zoom. Scrolling stays on for RomM's pre play page,
        // whose core and firmware pickers sit below the fold, and switches
        // off in updateUIView once the game starts and the page becomes a
        // canvas.
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        webView.load(request)

        let padView = ControlPadView(items: []) { [weak input] id, down in
            // Menu is native, everything else is the emulator's.
            if id == RetroPad.overlay {
                if down { input?.onMenu?() }
                return
            }
            input?.send(id: id, down: down)
        }
        padView.backgroundColor = .clear
        padView.isMultipleTouchEnabled = true
        return PlayerContainerView(webView: webView, pad: padView)
    }

    func updateUIView(_ container: PlayerContainerView, context: Context) {
        container.webView.scrollView.isScrollEnabled = !gameStarted
        container.pad.system = padSystem
        container.pad.theme = ControlTheme.current
        container.apply(pad)
    }

    /// Presses RomM's own Play button, but only once its page has visibly
    /// applied the core that was seeded.
    ///
    /// Waiting for the Play button alone is not enough: it renders before
    /// RomM finishes loading the game asynchronously, so clicking then
    /// launched on whatever core was default, which for arcade is a 2003
    /// MAME that cannot start most games. The core name appearing in its own
    /// picker is proof the configuration was read. Failing to find it leaves
    /// the page visible rather than guessing, which is the intended
    /// degradation.
    /// - Parameter verifyCore: whether to wait for proof that the seeded
    ///   core was applied before pressing Play. This is worth waiting for
    ///   on arcade, where picking wrong means a 2003 MAME that cannot run
    ///   most of the library. It is not worth waiting for on a platform
    ///   with a single core, where there is nothing to get wrong and no
    ///   picker for the id to appear in, so the proof never arrives and
    ///   auto start used to give up and strand the player on RomM's own
    ///   screen. That was every single core system: Game Boy Advance, the
    ///   Nintendo handhelds, most consoles.
    static func autoStartInjection(expecting core: String?, verifyCore: Bool) -> String {
        let expected: String
        if let core, verifyCore, let data = try? JSONEncoder().encode(core),
           let literal = String(data: data, encoding: .utf8) {
            expected = literal
        } else {
            expected = "null"
        }

        return """
        (function () {
          if (!window.__rommLaunchSeeded) return;
          var want = \(expected);
          var tries = 0;
          var timer = setInterval(function () {
            tries++;
            var play = document.querySelector(".r-v2-ejs__play");
            if (!play) { if (tries > 100) clearInterval(timer); return; }

            // No core to verify means nothing to get wrong, so a settle
            // delay is enough.
            if (!want) {
              if (tries > 8) { clearInterval(timer); play.click(); }
              return;
            }

            // Looking for specific component class names was too brittle:
            // RomM's v2 UI wraps its selects in its own components, so the
            // markup is not Vuetify's. The core id appearing anywhere in the
            // rendered page is a looser but far more durable signal that the
            // configuration was read and applied.
            var text = (document.body && document.body.innerText) || "";
            if (text.indexOf(want) !== -1) { clearInterval(timer); play.click(); return; }
            if (tries > 100) clearInterval(timer);
          }, 100);
        })();
        """
    }

    /// The safety net for a killed content process. iOS can take the
    /// webview's process, and the emulator inside it, at any moment it needs
    /// memory back, and no app is exempt. What can be controlled is the
    /// cost: a state autosaved into the browser's own on disk storage every
    /// thirty seconds, plus on demand at the risky moments, means the
    /// recovery reload resumes near where play stopped.
    ///
    /// EmulatorJS's own state store is reused rather than a parallel
    /// database: `storage.states` is the IndexedDB home of its save state
    /// slots, it survives the process dying, and it needs no schema of this
    /// app's own. The key carries the rom id so games never collide.
    ///
    /// Loading is native initiated only. The page cannot tell a crash
    /// recovery from a fresh launch, but the app can, and a fresh launch
    /// must never have its chosen save quietly replaced by an autosave.
    /// The five minute freshness guard is for the one gap the native flag
    /// cannot see: a kill that lands before the first autosave of a new
    /// session, where the store still holds a state from a previous day.
    static func recoveryInjection(romId: Int, autosaveEnabled: Bool) -> String {
        """
        (function () {
          const KEY = "cabinet.autosave.\(romId)";
          const MANUAL_KEY = "cabinet.manual.\(romId)";
          const START = Date.now();

          // Puts back the last state banked from the pause menu. Separate
          // from the autosave, which is a safety net nobody asked for and
          // should never overwrite a moment someone deliberately kept.
          window.__cabinetLoadManual = function () {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started || !e.storage || !e.storage.states) return;
              e.storage.states.get(MANUAL_KEY).then(function (rec) {
                if (!rec || !rec.data) return;
                e.gameManager.loadState(new Uint8Array(rec.data));
                e.displayMessage("BACK AT YOUR SAVED MOMENT");
              }).catch(function () {});
            } catch (x) {}
          };

          // The input path, resident so the native side never has to ship
          // it again. Held on window rather than closed over so it survives
          // being called from an evaluateJavaScript with no scope of its
          // own, and resolved fresh each call because gameManager does not
          // exist until a game loads.
          window.__ci = function (id, down) {
            try {
              const e = window.EJS_emulator;
              if (e && e.gameManager) e.gameManager.simulateInput(0, id, down);
            } catch (x) {}
          };

          // Autosave has to stay cheap or it becomes the thing it protects
          // against. The webview's content process runs under a much
          // tighter memory ceiling than the app, and every allocation here
          // competes with the emulator's own footprint. An earlier version
          // took a full resolution PNG on every save and base64'd it across
          // the bridge, roughly ten megabytes of churn every thirty
          // seconds, and killed the process about every fifth cycle.
          //
          // So: the state is saved on a timer whose period scales with how
          // big the state actually is, and the screenshot is not on the
          // timer at all.
          let period = 30000;
          let timer = null;

          const schedule = (ms) => {
            if (ms === period && timer) return;
            period = ms;
            if (timer) clearInterval(timer);
            timer = setInterval(save, period);
          };

          function save() {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started || e.paused) return;
              if (!e.gameManager || !e.storage || !e.storage.states) return;
              const data = e.gameManager.getState();
              if (!data || !data.length) return;
              e.storage.states.put(KEY, { t: Date.now(), data: data });
              // Mirrored to native so the launch screen can decide whether
              // an autosave is worth offering before any webview exists to
              // ask.
              try { window.webkit.messageHandlers.autosave.postMessage(true); }
              catch (x) {}

              // A CV1000 state is over a hundred megabytes. Copying that
              // every thirty seconds is its own memory emergency, and the
              // games with the biggest states are exactly the ones with the
              // least headroom left. Back off in proportion.
              // Cheap states are saved often, because the interval is
              // exactly how much play a kill costs, and the kills are not
              // going to stop. Progear's state is 0.3MB: writing that every
              // ten seconds is nothing, and it turns a death into losing a
              // few seconds rather than half a minute. Only the genuinely
              // huge states have to be rationed.
              const mb = data.length / 1048576;
              schedule(mb > 32 ? 180000 : mb > 8 ? 90000 : mb > 2 ? 30000 : 10000);

              // Vitals, so that when the process dies there is evidence
              // rather than another theory. A phone in a hand has no
              // console, and iOS reports nothing about why it took a
              // content process, so the only record is what was true a
              // moment before.
              try {
                window.webkit.messageHandlers.vitals.postMessage(
                  "state " + mb.toFixed(1) + "MB"
                    + ", " + Math.round((Date.now() - START) / 1000) + "s in"
                );
              } catch (x) {}
            } catch (x) {}
          }

          // The Home hero's frame, on a slow timer of its own.
          //
          // It cannot ride the pause: the core writes its screenshot on the
          // next emulated frame, and pausing stops frames, so a capture
          // fired alongside a pause returns a correctly sized black
          // rectangle. Delaying the pause to let it through would defeat
          // the one thing the pause menu is for. A lazy timer sidesteps
          // that entirely, and the hero being a couple of minutes stale is
          // invisible: it is a picture of your game, not a clock.
          //
          // Downscaled to a small jpeg before crossing the bridge, because
          // the bridge takes a base64 string and a full resolution png
          // becomes megabytes of it.
          window.__cabinetCaptureFrame = function () {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started || e.paused) return;
              // The core's own screenshot path, not the canvas: the canvas
              // is WebGL and reads back empty once a frame is presented,
              // which yields a perfectly sized black rectangle. Safe here
              // only because this is always called while the game is still
              // running, never after the pause has landed.
              e.takeScreenshot(undefined, "png", 1).then(function (shot) {
                const blob = shot && (shot.blob || shot.screenshot);
                if (!blob) return;
                return createImageBitmap(blob).then(function (bitmap) {
                  const w = Math.min(bitmap.width, 480);
                  const h = Math.max(1, Math.round(bitmap.height * (w / bitmap.width)));
                  const off = document.createElement("canvas");
                  off.width = w;
                  off.height = h;
                  off.getContext("2d").drawImage(bitmap, 0, 0, w, h);
                  bitmap.close();
                  const url = off.toDataURL("image/jpeg", 0.6);
                  off.width = 0;
                  off.height = 0;
                  try { window.webkit.messageHandlers.frame.postMessage(url); }
                  catch (x) {}
                });
              }).catch(function () {});
            } catch (x) {}
          };

          // Autosaves were never deleted, so every game ever played left
          // its largest state in this origin's storage permanently: a
          // hundred and thirty seven megabytes for one Cave game, sitting
          // there while an unrelated game runs. WebKit accounts storage
          // per origin, and the origin here also holds the cached ROMs, so
          // an unbounded pile of dead states is the last thing this process
          // needs. The previous session's state is dropped once the current
          // one no longer needs it, which is the moment the game is up and
          // any restore has already happened.
          window.__cabinetDropAutosave = function () {
            try {
              const e = window.EJS_emulator;
              if (e && e.storage && e.storage.states) e.storage.states.remove(KEY);
            } catch (x) {}
          };

          if (\(autosaveEnabled ? "true" : "false")) {
            schedule(30000);
            setInterval(window.__cabinetCaptureFrame, 120000);
          }
          window.__cabinetAutosaveNow = save;

          // The upload goes through fetch directly rather than RomM's
          // EJS_onSaveState, which swallows failures into the console and
          // can sit unresolved for minutes on a body the proxy will refuse.
          // The person just chose to bank a run; they get told what
          // happened. The CSRF token rides along from the cookie the same
          // way RomM's own client sends it, and the auth patch adds the
          // bearer token like any request. CV1000 class states run over a
          // hundred megabytes, which reverse proxies commonly refuse: 413
          // gets its own message because the fix, raising the proxy's body
          // limit, belongs to the server owner, not the player.
          window.__cabinetMenuSave = function () {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started || !e.gameManager) return;
              const state = e.gameManager.getState();
              if (!state || !state.length) return;

              // Kept locally as well as sent to the server, so the pause
              // menu can put it back without a round trip and without
              // caring whether the upload succeeded. This is the copy Load
              // reads, which also means it always came from the core
              // currently running: a snapshot one core made is unreadable
              // by another.
              try {
                if (e.storage && e.storage.states) {
                  e.storage.states.put(MANUAL_KEY, { t: Date.now(), data: state });
                  window.webkit.messageHandlers.manualSave.postMessage(true);
                }
              } catch (x) {}
              const upload = function (shot) {
                try {
                  const fd = new FormData();
                  fd.append("stateFile", new Blob([state]), "state.save");
                  fd.append("screenshotFile", shot || new Blob([]), "screenshot.png");
                  const m = document.cookie.match(/romm_csrftoken=([^;]+)/);
                  fetch("/api/states?rom_id=\(romId)&emulator=emulatorjs", {
                    method: "POST",
                    headers: m ? { "x-csrftoken": m[1] } : {},
                    body: fd
                  }).then(function (r) {
                    if (r.ok) { e.displayMessage("STATE SAVED TO YOUR SERVER"); }
                    else if (r.status === 413) { e.displayMessage("STATE TOO LARGE FOR THE SERVER"); }
                    else { e.displayMessage("STATE SAVE FAILED (" + r.status + ")"); }
                    try { window.webkit.messageHandlers.saveResult.postMessage("http " + r.status); }
                    catch (x) {}
                  }).catch(function (err) {
                    e.displayMessage("STATE SAVE FAILED, CHECK THE CONNECTION");
                    try { window.webkit.messageHandlers.saveResult.postMessage("network " + err); }
                    catch (x) {}
                  });
                } catch (x) {}
              };
              // The canvas source, not retroarch's: the retroarch path waits
              // for the core to process a screenshot command, and a paused
              // core processes nothing, so the save would never happen.
              try {
                e.takeScreenshot("canvas", "png", 1).then(function (s) {
                  upload(s && (s.blob || s.screenshot));
                }).catch(function () { upload(null); });
              } catch (x) { upload(null); }
            } catch (x) {}
          };

          window.__cabinetRecover = function (maxAgeMs) {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.storage || !e.storage.states) return;
              e.storage.states.get(KEY).then(function (rec) {
                if (!rec || !rec.data || !rec.t) return;
                if (Date.now() - rec.t > (maxAgeMs || 300000)) return;
                e.gameManager.loadState(new Uint8Array(rec.data));
                e.displayMessage("PICKING UP WHERE YOU LEFT OFF");
              }).catch(function () {});
            } catch (x) {}
          };
        })();
        """
    }

    static func authInjection(token: String) -> String {
        """
        (function () {
          const TOKEN = \(tokenLiteral(token));
          const sameOrigin = (url) => {
            try { return new URL(url, location.href).origin === location.origin; }
            catch { return false; }
          };

          const origFetch = window.fetch;
          window.fetch = function (input, init) {
            try {
              const url = typeof input === "string" ? input : input && input.url;
              if (sameOrigin(url)) {
                init = init || {};
                const headers = new Headers(
                  init.headers || (input instanceof Request ? input.headers : undefined)
                );
                if (!headers.has("Authorization")) {
                  headers.set("Authorization", "Bearer " + TOKEN);
                }
                init.headers = headers;
              }
            } catch (e) {}
            return origFetch.call(this, input, init);
          };

          const origOpen = XMLHttpRequest.prototype.open;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function (method, url) {
            this.__rommSameOrigin = sameOrigin(url);
            this.__rommUrl = String(url);
            return origOpen.apply(this, arguments);
          };
          XMLHttpRequest.prototype.send = function () {
            if (this.__rommSameOrigin) {
              try { this.setRequestHeader("Authorization", "Bearer " + TOKEN); }
              catch (e) {}
            }
            return origSend.apply(this, arguments);
          };

          // Physical controllers are captured natively with GameController,
          // so the web side must not see them too or every press registers
          // twice. EmulatorJS polls navigator.getGamepads in a loop, so
          // emptying that one function is the whole suppression, and the
          // connection events go quiet alongside it for anything that
          // listens rather than polls. Settles scope doc open item 5.
          try {
            Object.defineProperty(navigator, "getGamepads", {
              value: () => [], configurable: true,
            });
            if (navigator.webkitGetGamepads) {
              Object.defineProperty(navigator, "webkitGetGamepads", {
                value: () => [], configurable: true,
              });
            }
          } catch (e) {}
          window.addEventListener("gamepadconnected", (e) => e.stopImmediatePropagation(), true);
          window.addEventListener("gamepaddisconnected", (e) => e.stopImmediatePropagation(), true);

          // Ask EmulatorJS for the multi threaded build of the core.
          //
          // RomM only requests threads for dosbox_pure, ppsspp and azahar, so
          // arcade cores run single threaded even where a threaded build
          // exists on the server, and the heaviest boards, Cave's CV1000
          // among them, have no headroom to spare. EmulatorJS only honours
          // this when the page is cross origin isolated, which needs COOP and
          // COEP headers from the server, and falls back to the single
          // threaded core when it is not, so setting it unconditionally is
          // safe: with no isolation nothing changes.
          try {
            if (typeof SharedArrayBuffer === "function" && window.crossOriginIsolated) {
              window.EJS_threads = true;
            }
          } catch (e) {}

          // Report what the emulator settled on, read from its own state
          // once a game is running.
          //
          // An earlier version watched for the core download instead, which
          // reported nothing on any replay: EmulatorJS caches cores in
          // browser storage and never re-requests them, so the only sessions
          // it could observe were first ever loads.
          window.__rommReportEmulation = function () {
            try {
              const e = window.EJS_emulator;
              const sab = typeof SharedArrayBuffer === "function";
              let core = "unknown", threads = false;
              if (e) {
                try { core = e.getCore ? e.getCore() : (e.config && e.config.system) || "unknown"; } catch (x) {}
                try {
                  const pref = e.preGetSetting && e.preGetSetting("ejs_threads");
                  threads = sab && (pref ? pref === "enabled" : !!(e.config && e.config.threads));
                } catch (x) {}
              }
              window.webkit.messageHandlers.diag.postMessage(
                "core " + core + (threads ? "-thread" : "") +
                " isolated=" + !!window.crossOriginIsolated +
                " sab=" + sab
              );
            } catch (e) {}
          };

          // RomM's app shell wraps every route, the player included, in its
          // site navigation: a fixed header with the logo and account chip,
          // and a bottom nav on small screens (v2 AppLayout.vue). On the
          // website fullscreen covers them; in this webview there is no
          // fullscreen, so they float over the game. This webview only ever
          // shows the player, so hide the shell chrome outright and release
          // the top padding the layout reserves for the header.
          //
          // .ejs_virtualGamepad_open is EmulatorJS's floating menu toggle,
          // the three bar button. It gets the same fade treatment as the
          // native close button, driven by the idle logic below.
          // .ejs_virtualGamepad_parent holds EmulatorJS's web touch pads,
          // replaced wholesale by the native overlay. The menu toggle is a
          // sibling attached to the game element, so it survives.
          const style = document.createElement("style");
          style.textContent =
            ".r-v2-nav-bar, .r-v2-bottom-nav { display: none !important } " +
            "#r-v2-main { padding-top: 0 !important } " +
            ".ejs_virtualGamepad_parent { display: none !important } " +
            ".ejs_virtualGamepad_open { transition: opacity 0.35s !important } " +
            "html.romm-overlay-idle .ejs_virtualGamepad_open " +
            "{ opacity: 0 !important; pointer-events: none !important }";
          document.documentElement.appendChild(style);

          // EmulatorJS reveals its menu toggle exactly when the game starts
          // (it flips the element's display on its own start event), which is
          // the cleanest signal the page offers. Watch it both ways and keep
          // the native side in sync, so the control pad appears with the game
          // and disappears when the game does. This script reruns on every
          // page load, so a reload, a rotation that reloads, or a failed
          // boot resets the native side to "no game" instead of stranding
          // ghost controls over RomM's config screen.
          const postGameState = (state) => {
            try {
              window.webkit.messageHandlers.gameState.postMessage(state);
            } catch (e) {}
          };
          postGameState("stopped");

          let gameOn = false;
          const gameObserver = new MutationObserver(() => {
            const toggle = document.querySelector(".ejs_virtualGamepad_open");
            const on = !!toggle && toggle.style.display !== "none";
            if (on !== gameOn) {
              gameOn = on;
              postGameState(on ? "started" : "stopped");
              if (on && window.__rommReportEmulation) {
                setTimeout(window.__rommReportEmulation, 400);
              }
            }
          });
          gameObserver.observe(document.documentElement, {
            subtree: true,
            childList: true,
            attributes: true,
            attributeFilter: ["style"],
          });

          // Overlay idle logic. The close button and the EmulatorJS menu
          // toggle show briefly, then fade so nothing sits over the game.
          // Only touches on the UPPER part of the screen wake them: during
          // play both thumbs live on the virtual controls at the bottom, and
          // waking on every d-pad press would keep the buttons up forever.
          // Tapping the game canvas is the deliberate "show me the controls"
          // gesture. The native side mirrors the same visibility for its
          // close button through the overlay message handler.
          let idleTimer = null;
          const setIdle = (idle) => {
            document.documentElement.classList.toggle("romm-overlay-idle", idle);
            try {
              window.webkit.messageHandlers.overlay.postMessage(!idle);
            } catch (e) {}
          };
          const wake = () => {
            setIdle(false);
            clearTimeout(idleTimer);
            idleTimer = setTimeout(() => setIdle(true), 3000);
          };
          window.addEventListener("touchstart", (event) => {
            const touch = event.touches && event.touches[0];
            if (touch && touch.clientY < window.innerHeight * 0.55) wake();
          }, { passive: true, capture: true });

          // A physical controller has no screen to tap, so native code calls
          // this to reveal the overlay. Going through the same wake keeps one
          // source of truth: EmulatorJS's menu button and the app's close
          // button appear and fade together rather than drifting apart.
          window.__rommWakeOverlay = wake;

          wake();
        })();
        """
    }

    /// The token goes into the script as a JSON string literal, never by plain
    /// interpolation, so nothing in it can break out of the quote.
    private static func tokenLiteral(_ token: String) -> String {
        guard let data = try? JSONEncoder().encode(token),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }
}


/// One UIKit hierarchy holding the webview and the touch pad.
///
/// They used to be SwiftUI siblings, and wherever they overlapped the
/// webview received every touch while the pad received none, despite the pad
/// drawing exactly where it should. In landscape they overlap everywhere, so
/// the controls looked right and did nothing, and a rotation to portrait,
/// where they do not overlap, made them work. With both views in one
/// hierarchy the pad is simply the topmost subview, and its own point(inside:)
/// decides what passes through to the game underneath.
final class PlayerContainerView: UIView {
    let webView: WKWebView
    let pad: ControlPadView

    private var placement: PlayerWebView.PadConfiguration = .hidden

    init(webView: WKWebView, pad: ControlPadView) {
        self.webView = webView
        self.pad = pad
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(webView)
        addSubview(pad)
        pad.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ configuration: PlayerWebView.PadConfiguration) {
        placement = configuration
        switch configuration {
        case .hidden:
            pad.isHidden = true
        case .overlay(let items, let opacity), .bottomStrip(let items, _, let opacity):
            pad.items = items
            pad.alpha = opacity
            pad.isHidden = false
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch placement {
        case .hidden, .overlay:
            webView.frame = bounds
            pad.frame = bounds
        case .bottomStrip(_, let height, _):
            let split = max(bounds.height - height, 0)
            webView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: split)
            pad.frame = CGRect(x: 0, y: split, width: bounds.width, height: height)
        }
    }
}
