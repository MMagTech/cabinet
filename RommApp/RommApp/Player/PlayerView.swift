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
    /// A specific save state to load once the game has booted, resolved
    /// before this view was ever created. Not seeded through RomM's
    /// localStorage configuration the way core and BIOS are: that path
    /// was tried for states too and does nothing, confirmed on device,
    /// nothing in RomM's own page ever consumes a seeded `state_id`. This
    /// is loaded directly through the emulator's own JavaScript API
    /// instead, the same call the pause menu's own Load button already
    /// uses successfully.
    var stateToLoad: StateToLoad?

    /// Where the bytes to load after boot come from. `local` reuses the
    /// pause menu's own last-saved slot with no network involved, `remote`
    /// carries bytes already downloaded from RomM. Callers decide which
    /// before presenting this view; nothing here fetches on its own,
    /// keeping the state actually loaded rehearsed and predictable rather
    /// than chosen deep inside the player.
    enum StateToLoad {
        case local
        case remote(Data)
    }

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// The short name EmulatorJS's core catalogue actually indexes by. See
    /// `Rom.canonicalPlatformSlug`: `rom.platformSlug` is IGDB's metadata
    /// slug and answers a different question, one that happens to agree
    /// with EmulatorJS's naming only by coincidence on most platforms.
    private var canonicalSlug: String {
        rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
    }
    @State private var context: (url: URL, token: String)?
    @State private var failed = false
    @State private var overlayVisible = true
    @State private var gameStarted = false
    /// Boot watchdog. `lastBootProgress` moves whenever the loading status
    /// changes; a boot whose status has been frozen for 20 seconds without
    /// the game starting is stalled, and the known cause is a wedged
    /// EmulatorJS-core database (a mid-transaction process kill corrupts
    /// it, after which its reads never resolve and never error, so nothing
    /// downstream can time out). The repair is deleting that database and
    /// reloading, attempted automatically once; a second stall lifts the
    /// curtain instead, so a genuinely broken boot shows the page's own
    /// error rather than a progress screen that never ends.
    @State private var lastBootProgress = Date()
    @State private var bootRepairAttempted = false
    /// Nil while booting normally. Set once the watchdog gives up, which
    /// now happens for two distinct reasons that deserve different words:
    /// no network at all, detected before wasting the one repair attempt
    /// on storage that was never broken, or a stall that persisted even
    /// after repairing it.
    @State private var bootFailure: BootFailure?
    @State private var bootWatchdogNote: String?

    enum BootFailure: Equatable {
        case offline
        case stalled
    }
    @State private var recovering = false
    /// EmulatorJS's own boot status, mirrored from the page. Nil before the
    /// page's loading text has appeared at all, which the curtain still
    /// covers, just with an indeterminate chase instead of a real count.
    @State private var bootStatus: LoadingStatus?
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
                    stateToLoad: stateToLoad,
                    canonicalPlatformSlug: canonicalSlug,
                    padSystem: controlLayout?.system ?? "",
                    overlayVisible: $overlayVisible,
                    gameStarted: $gameStarted,
                    recovering: $recovering,
                    bootStatus: $bootStatus,
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

            // The boot curtain. RomM's own loading UI never actually shows:
            // this sits over the webview from the moment it exists until the
            // game reports started, same as the recovery curtain just below,
            // just for the ordinary first boot rather than a crash.
            if context != nil, !gameStarted, !recovering, bootFailure == nil {
                BootCurtain(
                    title: rom.displayName, status: bootStatus,
                    platformLabel: rom.platformLabel(source: .platformName, platformNames: session.platformNames),
                    watchdogNote: bootWatchdogNote,
                    coverPath: rom.pathCoverLarge ?? rom.pathCoverSmall
                )
                    .transition(.opacity)
            }

            // What the watchdog hands back when it gives up, instead of
            // just letting the curtain drop and exposing whatever raw
            // page state is underneath: a native explanation and a real
            // retry, the same "clear message, not a crash" shape
            // OfflineNotice already gives Home, the library and search.
            if let bootFailure {
                PlayerLoadFailure(reason: bootFailure) {
                    self.bootFailure = nil
                    bootRepairAttempted = false
                    bootWatchdogNote = nil
                    lastBootProgress = Date()
                    input.reloadPage()
                }
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
                    // No tap-to-dismiss here on purpose: this menu holds a
                    // destructive action, and a stray tap outside it while
                    // reaching for something else used to resume the game
                    // out from under whoever opened it. Resume is a real
                    // button now, not a rest state you can back into.
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
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
                            // Quit leads, not trails: the destructive choice
                            // sat at the bottom, exactly where a thumb
                            // reaching up into a centred popup naturally
                            // lands, which is the easiest button in the
                            // menu to hit by accident. Resume closes the
                            // stack instead, in the spot that reach favours,
                            // since it is the one button worth favouring.
                            Button(role: .destructive) {
                                SessionMarker.recordCleanExit()
                                dismiss()
                            } label: {
                                Label("Quit", systemImage: "xmark")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            Button {
                                // Deliberately no resumeFromMenu() here.
                                // Saving used to drop straight back into
                                // gameplay, which meant a save landed while
                                // still under whatever pressure caused it.
                                // The menu now stays up: Save just saves,
                                // and Resume is its own explicit tap.
                                input.saveStateToServer()
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
                            Button {
                                resumeFromMenu()
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
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
        .animation(.easeInOut(duration: 0.3), value: gameStarted)
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
        .onChange(of: bootStatus) { _, _ in
            lastBootProgress = Date()
            bootWatchdogNote = nil
        }
        // The watchdog loop. Checks every five seconds rather than
        // scheduling one precise timer, because the deadline moves with
        // every status change and a coarse poll is simpler than rebuilding
        // a timer on each one.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !gameStarted, context != nil, !recovering, bootFailure == nil else { continue }
                let quiet = Date().timeIntervalSince(lastBootProgress)
                // The narration comes well before the repair: a person
                // starts doubting a frozen screen long before twenty
                // seconds, and the difference between hung and handled is
                // the curtain admitting it noticed.
                if quiet > 10, bootWatchdogNote == nil, !bootRepairAttempted {
                    bootWatchdogNote = "Taking longer than usual"
                }
                guard quiet > 20 else { continue }
                // Checked at every give-up decision, not just the first:
                // a repair-and-reload attempted with no network fails for
                // an unrelated reason and would otherwise mislabel a
                // plain connectivity problem as a storage one on the
                // second stall too.
                guard !NetworkMonitor.shared.isOffline else {
                    bootFailure = .offline
                    DiagnosticsLog.record(
                        context: "Boot watchdog",
                        message: "Boot stalled with no network; skipped storage repair.",
                        romVersion: session.serverVersion
                    )
                    continue
                }
                if bootRepairAttempted {
                    bootFailure = .stalled
                    DiagnosticsLog.record(
                        context: "Boot watchdog",
                        message: "Boot stalled again after storage repair; curtain lifted.",
                        romVersion: session.serverVersion
                    )
                } else {
                    bootRepairAttempted = true
                    lastBootProgress = Date()
                    bootWatchdogNote = "Fixing a loading problem"
                    DiagnosticsLog.record(
                        context: "Boot watchdog",
                        message: "Boot stalled 20s with no progress; repairing core storage and reloading.",
                        romVersion: session.serverVersion
                    )
                    input.repairCoreStorageAndReload()
                }
            }
        }
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
            // Report the finished session through Session rather than a
            // loose task: a .task here would be cancelled before the
            // request left, and a detached one races Home's refresh.
            if let startedAt {
                session.reportPlaySessionEnded(romId: rom.id, start: startedAt, end: Date())
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
        return ControlLayout.forPlatform(slug: canonicalSlug)
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
            headroom: layout.headroom ?? 0,
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
        // N64's C-buttons and a twin-stick arcade game's second joystick are
        // both ordinary digital buttons on the real hardware, but EmulatorJS
        // and the core underneath it route both through the analog dispatch
        // path, not the plain digital one: N64's C-buttons confirmed from
        // EmulatorJS's own control scheme in data/src/emulator.js, the
        // arcade case from FBNeo's libretro port funneling a second
        // joystick's directions into RETRO_DEVICE_ANALOG's right stick. A
        // boolean __ci call would arrive as magnitude 1 out of a possible
        // 0x7fff, well under whatever deadzone either reads a press against,
        // and never register. See RetroPad.isAnalogAxis(id:).
        if RetroPad.isAnalogAxis(id) {
            webView?.evaluateJavaScript("__cm(\(id),\(down ? 0x7fff : 0))")
            return
        }
        webView?.evaluateJavaScript("__ci(\(id),\(down ? 1 : 0))")
    }

    /// A stick's live position, x and y each -1 to 1. `ids` are
    /// x-positive/x-negative/y-positive/y-negative, EmulatorJS's own order.
    /// Each axis sends whichever direction is live at full drag magnitude
    /// and zeroes the other, the exact scheme EmulatorJS's own on screen
    /// stick uses (`data/src/emulator.js`'s nipplejs "move" handler), so a
    /// touch drag and EmulatorJS's own stick are indistinguishable to the
    /// core.
    func sendStick(ids: [Int], x: Double, y: Double) {
        guard ids.count == 4 else { return }
        let scale = 0x7fff as Double
        let xMag = Int((abs(x) * scale).rounded())
        let yMag = Int((abs(y) * scale).rounded())
        webView?.evaluateJavaScript("""
        __cm(\(ids[0]),\(x > 0 ? xMag : 0));\
        __cm(\(ids[1]),\(x < 0 ? xMag : 0));\
        __cm(\(ids[2]),\(y > 0 ? yMag : 0));\
        __cm(\(ids[3]),\(y < 0 ? yMag : 0));
        """)
    }

    /// Pauses the running game: the pause menu opening, or a controller
    /// disconnecting mid play.
    ///
    /// Through `__cabinetPauseWithCapture`, which grabs one frame on its
    /// way down and then pauses from inside that same frame callback: the
    /// only moment a WebGL canvas is readable is between a draw and its
    /// composite, so the pixels have to be taken while the game still
    /// renders, and this is the last instant it does. Costs at most one
    /// rendered frame of pause latency, ~8 to 16ms, below the variance of
    /// the tap itself. The captured frame is held for Save and dumped on
    /// resume. Falls back to a plain pause if the helper is not resident.
    func pauseGame() {
        webView?.evaluateJavaScript(
            """
            if (window.__cabinetPauseWithCapture) { __cabinetPauseWithCapture(); }
            else if (window.EJS_emulator && !EJS_emulator.paused) { EJS_emulator.pause(); }
            """
        )
    }

    func resumeGame() {
        webView?.evaluateJavaScript(
            """
            window.__cabinetHeldShot = null;
            window.EJS_emulator && EJS_emulator.paused && EJS_emulator.play();
            """
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

    /// Deletes the EmulatorJS-core database and reloads the page: the
    /// repair for a boot wedged on a corrupted core cache, run inside the
    /// player's own webview since IndexedDB is origin scoped and this
    /// webview is already on RomM's origin. Cores redownload on the
    /// reload; states, saves and the ROM cache live in other databases
    /// and are untouched. The reload happens through location.reload, so
    /// every injected script reruns exactly as on a first load.
    func repairCoreStorageAndReload() {
        webView?.evaluateJavaScript(
            """
            (function () {
              var reloaded = false;
              function go() {
                if (reloaded) return;
                reloaded = true;
                location.reload();
              }
              try {
                var req = indexedDB.deleteDatabase("EmulatorJS-core");
                req.onsuccess = go;
                req.onerror = go;
                req.onblocked = go;
                setTimeout(go, 4000);
              } catch (e) { go(); }
            })();
            """
        )
    }

    /// A plain reload, nothing deleted: for retrying after a connectivity
    /// failure, where nothing pointed at the core cache being the problem.
    func reloadPage() {
        webView?.evaluateJavaScript("location.reload();")
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
        /// Pad below the canvas, the portrait arrangement. `headroom` is
        /// extra pad height, as a fraction of `height`, for a layout too
        /// crowded to fit the normal strip: the webview keeps the exact
        /// frame it would have had at `height` alone, and the pad grows
        /// upward from the bottom edge to overlap the last bit of it, the
        /// same "controls float over the picture, opacity keeps it legible"
        /// deal landscape already makes everywhere.
        case bottomStrip(items: [ControlLayout.Item], height: CGFloat, headroom: Double, opacity: Double)
    }

    let url: URL
    let token: String
    let launch: LaunchChoices
    let rom: Rom
    let pad: PadConfiguration
    var resumeFromAutosave: Bool = false
    var stateToLoad: PlayerView.StateToLoad?
    /// The short name EmulatorJS's core catalogue indexes by, resolved once
    /// in `PlayerView` and passed down here rather than recomputed: this
    /// view has no `Session` of its own to read the live folder mapping
    /// from. See `Rom.canonicalPlatformSlug`.
    var canonicalPlatformSlug: String = ""
    /// The layout's system name, which decides the control colours.
    var padSystem: String = ""
    @Binding var overlayVisible: Bool
    @Binding var gameStarted: Bool
    @Binding var recovering: Bool
    @Binding var bootStatus: LoadingStatus?
    let input: PlayerInputBridge

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let parent: PlayerWebView
        /// Set while a game start should pull the autosave back in: either a
        /// reload recovering from a dead content process, or a launch the
        /// person explicitly asked to continue. Never set by a plain launch,
        /// which must respect the launch screen's choices.
        private var pendingRecovery: Bool
        /// Consumed once, the same way `pendingRecovery` is: set from the
        /// resolved choice this view was created with, cleared the instant
        /// it is acted on so a later reload of this same webview (crash
        /// recovery reloads it in place) never loads it a second time.
        private var pendingStateToLoad: PlayerView.StateToLoad?
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
            pendingStateToLoad = parent.stateToLoad
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
            case "loadingStatus":
                if let text = message.body as? String, !text.isEmpty {
                    parent.bootStatus = LoadingStatus(raw: text)
                }
            case "gameState":
                if message.body as? String == "started" {
                    parent.gameStarted = true
                    SessionMarker.recordGameRunning(romId: parent.rom.id)
                    resumeAfterRecovery(in: message.webView)
                    loadPendingState(in: message.webView)
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
                // "stopped" is deliberately ignored. It looks like the
                // missing half of this handler, but the page derives it
                // from the menu toggle's visibility, which EmulatorJS
                // flickers mid-session (the pause menu is enough), and
                // resetting gameStarted here re-arms the boot watchdog
                // against a boot that finished minutes ago: its progress
                // clock is long stale, so it "repairs" storage and
                // reloads a healthy running game within seconds. Tried
                // once, shipped, and it did exactly that on device.
            case "autosave":
                SessionMarker.recordAutosave(romId: parent.rom.id)
            // The outcome of the last menu save, kept because a phone in a
            // hand has no console: when someone says saving did nothing,
            // this answers with the status code it got.
            case "manualSave":
                ManualSave.record(romId: parent.rom.id)
            case "vitals":
                if let line = message.body as? String {
                    EmulationInfo.recordVitals(line)
                }
            case "playerNetwork":
                if let url = message.body as? String {
                    PlayerNetworkLog.append(url)
                }
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
            // Stale, so the boot curtain does not flash the old run's
            // status text once the recovery curtain above it lifts.
            parent.bootStatus = nil

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

        /// A short settle delay, the same reasoning as recovery above: the
        /// core needs a beat after booting before a full state lands
        /// cleanly, FBNeo especially.
        private func loadPendingState(in webView: WKWebView?) {
            guard let toLoad = pendingStateToLoad else { return }
            pendingStateToLoad = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                switch toLoad {
                case .local:
                    webView?.evaluateJavaScript(
                        "window.__cabinetLoadManual && __cabinetLoadManual();"
                    )
                case .remote(let data):
                    let base64 = data.base64EncodedString()
                    let literal = self?.jsStringLiteral(base64) ?? "\"\""
                    webView?.evaluateJavaScript(
                        "window.__cabinetLoadStateBytes && __cabinetLoadStateBytes(\(literal));"
                    )
                }
            }
        }

        private func jsStringLiteral(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                let literal = String(data: data, encoding: .utf8)
            else { return "\"\"" }
            return literal
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
        #if DEBUG
        // One-off diagnostic: dumps every entry actually sitting in
        // EmulatorJS-roms from this page's own execution context, before
        // EmulatorJS runs. Isolates whether a Data Saver write is visible
        // to the real player at all, versus a logic difference inside
        // EmulatorJS's own cache-hit check. Remove once Data Saver's
        // read side is confirmed working.
        config.userContentController.addUserScript(
            WKUserScript(source: Self.cacheProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        #endif
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
                        verifyCore: CoreCatalog.cores(for: canonicalPlatformSlug).count > 1
                    ),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        config.userContentController.addUserScript(
            WKUserScript(
                source: Self.recoveryInjection(
                    romId: rom.id, stateBaseName: rom.fsNameNoExt,
                    autosaveEnabled: PlayerAutosave.isEnabled
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        config.userContentController.add(context.coordinator, name: "overlay")
        config.userContentController.add(context.coordinator, name: "loadingStatus")
        config.userContentController.add(context.coordinator, name: "gameState")
        config.userContentController.add(context.coordinator, name: "diag")
        config.userContentController.add(context.coordinator, name: "autosave")
        config.userContentController.add(context.coordinator, name: "manualSave")
        config.userContentController.add(context.coordinator, name: "vitals")
        #if DEBUG
        config.userContentController.add(context.coordinator, name: "playerNetwork")
        PlayerNetworkLog.startNewSession(romName: rom.displayName)
        #endif

        // The crash-to-curtain investigation's conclusion, so nobody
        // reopens it without new evidence. The WebContent process loses
        // a fixed-size chunk of compositor memory per frame presented
        // until iOS kills it at its hard 2GB cap, roughly a minute of
        // continuous play. Eliminated by on-device experiment: page
        // settings and shaders, canvas resolution (9x smaller changed
        // nothing), the webview's own layer size (scaled-down view plus
        // transform changed nothing), every private WebKit feature flag
        // in all three lists (the GPU-process switches do not exist on
        // iOS 26), opacity, zoom, autosave, observers, and all injected
        // work. Present rate is the only variable that moved survival.
        // Safari on the same phone runs the same page indefinitely; the
        // leak is Apple's, in the embedded-webview compositor path, and
        // is reported via Feedback with jetsam evidence. Mitigations
        // live elsewhere: crash recovery restores within seconds, and
        // the pause menu is the natural place for a preemptive process
        // recycle if one is ever added.
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        #if DEBUG
        // Reachable from Safari on the Mac this device is paired with:
        // Develop menu > device name > this page. Lets Data Saver's real
        // effect be watched directly in the Network tab, whether the
        // ROM's own content request fires on a later Play, rather than
        // inferred from timing on a throttled connection. The
        // playerNetwork log above is the same proof without needing
        // Safari open at all: check Debug > Copy diagnostics after Play.
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif
        input.webView = webView
        // Opaque, deliberately. A non-opaque webview composites its WebGL
        // canvas through extra blending surfaces, and the WebContent
        // process pays for every one of them: this app's crash-to-curtain
        // hunt found the process ballooning to the 2GB jetsam cap on
        // memory invisible to the page, the exact signature of the
        // IOSurface accumulation WebKit is known for in embedded webviews
        // (FB16462982). The page's own background is black anyway.
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        // No bounce, no zoom, and the zoom scale pinned hard: zoom and
        // relayout traffic drives the same remote-layer surface path as
        // above. Scrolling stays on for RomM's pre play page, whose core
        // and firmware pickers sit below the fold, and switches off in
        // updateUIView once the game starts and the page becomes a canvas.
        webView.scrollView.bounces = false
        webView.scrollView.bouncesZoom = false
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        webView.load(request)

        let padView = ControlPadView(
            items: [],
            send: { [weak input] id, down in
                // Menu is native, everything else is the emulator's.
                if id == RetroPad.overlay {
                    if down { input?.onMenu?() }
                    return
                }
                input?.send(id: id, down: down)
            },
            sendStick: { [weak input] ids, x, y in input?.sendStick(ids: ids, x: x, y: y) }
        )
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

            // Giving up here used to mean leaving RomM's own screen sitting
            // untouched, which is the "have to press Play a second time"
            // bug: any mismatch, however harmless, stranded the whole
            // launch. But nothing about tapping Play depends on the seed
            // having matched. RomM's page always has some core selected,
            // ours or its own default, and reaching this screen at all
            // already means whatever choice mattered was made back on the
            // native launch screen. Pressing Play late is a worse pick,
            // never a worse experience than not pressing it at all.
            if (tries > 100) { clearInterval(timer); play.click(); }
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
    static func recoveryInjection(romId: Int, stateBaseName: String, autosaveEnabled: Bool) -> String {
        let escapedBase = (try? JSONEncoder().encode(stateBaseName))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"state\""
        return """
        (function () {
          const KEY = "cabinet.autosave.\(romId)";
          const MANUAL_KEY = "cabinet.manual.\(romId)";
          const STATE_BASE = \(escapedBase);
          const START = Date.now();

          // Pause, but read one frame on the way down. The drawing buffer
          // of a WebGL canvas is only readable between a draw and its
          // composite (no preserveDrawingBuffer), so the grab is scheduled
          // into the next animation frame, while the game still renders,
          // and the pause fires synchronously right after the readback in
          // that same callback. Total added pause latency: one rendered
          // frame at most, with a 50ms timeout backstop so a throttled
          // rAF can never leave the game running.
          //
          // The shot is held for Save (a screenshot of the moment actually
          // being saved, which a post-pause capture can never produce,
          // verified blank twice before) and dumped when the menu resumes
          // without saving.
          window.__cabinetHeldShot = null;
          window.__cabinetPauseWithCapture = function () {
            try {
              const e = window.EJS_emulator;
              if (!e || e.paused) return;
              window.__cabinetHeldShot = null;
              let done = false;
              const freeze = function () {
                if (done) return;
                done = true;
                try { if (!e.paused) e.pause(); } catch (x) {}
                // Big-state games have no timer autosave, so the pause
                // menu is their protection point. Deferred so the state
                // copy never delays the pause itself.
                setTimeout(function () { try { save(true); } catch (x) {} }, 0);
              };
              requestAnimationFrame(function () {
                try {
                  const src = e.canvas;
                  if (src && src.width > 0 && src.height > 0) {
                    const w = Math.min(src.width, 1000);
                    const h = Math.max(1, Math.round(src.height * (w / src.width)));
                    const off = document.createElement("canvas");
                    off.width = w;
                    off.height = h;
                    const ctx = off.getContext("2d", { alpha: false });
                    ctx.drawImage(src, 0, 0, w, h);
                    freeze();
                    // Everything after the freeze is off the hot path.
                    // Blank detection samples a grid of pixels: a failed
                    // readback is solid black, and a real game frame is
                    // not, so any lit sample proves the grab took. The
                    // stride is computed from the pixel count, not fixed,
                    // so this always takes roughly the same number of
                    // samples: a fixed byte stride tuned against a large
                    // arcade canvas left a native-resolution console
                    // frame (NES included, often under 300 pixels wide)
                    // with only a handful of samples, and Jackal's own
                    // dark backgrounds landed on every one of them,
                    // discarding a perfectly good capture as blank.
                    const sample = ctx.getImageData(0, 0, w, h).data;
                    const stride = Math.max(4, Math.floor((w * h) / 200) * 4);
                    let lit = false;
                    for (let i = 0; i < sample.length; i += stride) {
                      if (sample[i] > 8 || sample[i + 1] > 8 || sample[i + 2] > 8) { lit = true; break; }
                    }
                    if (lit) {
                      off.toBlob(function (blob) {
                        if (blob) window.__cabinetHeldShot = blob;
                      }, "image/png");
                    }
                    off.width = 0;
                    off.height = 0;
                  } else {
                    freeze();
                  }
                } catch (x) { freeze(); }
              });
              setTimeout(freeze, 50);
            } catch (x) {
              try {
                const e = window.EJS_emulator;
                if (e && !e.paused) e.pause();
              } catch (y) {}
            }
          };

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

          // The counterpart for a state fetched from RomM rather than read
          // out of this device's own storage: same load call, bytes handed
          // in instead of read from IndexedDB. This is the real mechanism
          // behind picking a state on the launch screen, or Home's Resume
          // button; seeding a state id into RomM's own localStorage
          // configuration was tried first and does nothing, nothing in
          // RomM's page ever reads it back to actually load a state.
          window.__cabinetLoadStateBytes = function (base64) {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started || !e.gameManager) return;
              const binary = atob(base64);
              const bytes = new Uint8Array(binary.length);
              for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
              e.gameManager.loadState(bytes);
              e.displayMessage("BACK AT YOUR SAVED MOMENT");
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

          // The magnitude twin of __ci above, for N64's stick and C-button
          // indices (16-23), which EmulatorJS reads as analog values rather
          // than a boolean down/up. Same call, same resident reasoning.
          window.__cm = function (id, value) {
            try {
              const e = window.EJS_emulator;
              if (e && e.gameManager) e.gameManager.simulateInput(0, id, value);
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

          // `force` marks an event save: pause, backgrounding, rotation.
          // Those moments may arrive with the game already paused, and the
          // paused guard only exists to stop the timer churning while
          // someone sits in a menu.
          function save(force) {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started || (!force && e.paused)) return;
              if (!e.gameManager || !e.storage || !e.storage.states) return;
              const data = e.gameManager.getState();
              if (!data || !data.length) return;
              e.storage.states.put(KEY, { t: Date.now(), data: data });
              // Mirrored to native so the launch screen can decide whether
              // an autosave is worth offering before any webview exists to
              // ask.
              try { window.webkit.messageHandlers.autosave.postMessage(true); }
              catch (x) {}

              // The acceptance test for anything running during play is
              // Safari: the same page in Safari survives games this app
              // was reloading, and the difference is what this script does
              // while the game runs. Copying a multi-megabyte state on a
              // timer is the biggest such cost, and the games with the
              // biggest states are exactly the ones with the least
              // headroom. So past 8MB the timer retires entirely: those
              // games are protected at the moments that are already free,
              // pause, backgrounding, rotation, exit, and during actual
              // play the page runs as close to bare as Safari's.
              // Cheap states keep the timer, because the interval is
              // exactly how much play a kill costs. Progear's state is
              // 0.3MB: writing that every ten seconds is nothing.
              const mb = data.length / 1048576;
              if (mb > 8) {
                if (timer) { clearInterval(timer); timer = null; }
              } else {
                schedule(mb > 2 ? 30000 : 10000);
              }

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
          }
          window.__cabinetAutosaveNow = function () { save(true); };

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
              // The name and the emulator tag both mirror RomM's own
              // player exactly (frontend `buildStateName` and
              // `saveState`, views/Player/EmulatorJS/utils.ts at tag
              // 5.1.0): the rom's short name plus an ISO timestamp with
              // separators dashed, and the actual core rather than the
              // literal "emulatorjs". Every save used to upload as the
              // same constant "state.save", indistinguishable in any
              // list, ours or RomM's own web UI; and the core tag is
              // what lets the launch screen's compatibility greying
              // mean something for states made here.
              //
              // The screenshot is the frame grabbed on the way into the
              // pause menu, held by __cabinetPauseWithCapture: a capture
              // attempted here, after the pause, reads back blank
              // (verified twice), so the only correct picture of this
              // moment is the one taken while the game still rendered,
              // one frame before the freeze. Omitted entirely when no
              // held shot survived its blank check, which the API
              // allows, rather than sending an empty image.
              try {
                const stamp = new Date().toISOString()
                  .replace(/[:.]/g, "-").replace("T", " ").replace("Z", "");
                const fd = new FormData();
                fd.append("stateFile", new Blob([state]), STATE_BASE + " [" + stamp + "].state");
                const shot = window.__cabinetHeldShot;
                if (shot) {
                  fd.append("screenshotFile", shot, STATE_BASE + " [" + stamp + "].png");
                  try { window.webkit.messageHandlers.manualSave.postMessage(true); }
                  catch (x) {}
                }
                const core = (typeof window.EJS_core === "string" && window.EJS_core)
                  ? window.EJS_core : "emulatorjs";
                const m = document.cookie.match(/romm_csrftoken=([^;]+)/);
                fetch("/api/states?rom_id=\(romId)&emulator=" + encodeURIComponent(core), {
                  method: "POST",
                  headers: m ? { "x-csrftoken": m[1] } : {},
                  body: fd
                }).then(function (r) {
                  if (r.ok) { e.displayMessage("STATE SAVED TO YOUR SERVER"); }
                  else if (r.status === 413) { e.displayMessage("STATE TOO LARGE FOR THE SERVER"); }
                  else { e.displayMessage("STATE SAVE FAILED (" + r.status + ")"); }
                }).catch(function (err) {
                  e.displayMessage("STATE SAVE FAILED, CHECK THE CONNECTION");
                });
              } catch (x) {}
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

    #if DEBUG
    static let cacheProbeScript = """
        (function () {
            try {
                window.webkit.messageHandlers.playerNetwork.postMessage("[cache-probe] script started");
            } catch (e) {}
            function post(msg) {
                try {
                    if (window.webkit && window.webkit.messageHandlers.playerNetwork) {
                        window.webkit.messageHandlers.playerNetwork.postMessage("[cache-probe] " + msg);
                    }
                } catch (e) {}
            }
            try {
                var open = indexedDB.open("EmulatorJS-roms", 1);
                open.onerror = function () { post("open failed: " + open.error); };
                open.onblocked = function () {
                    post("BLOCKED, another connection is still open somewhere");
                };
                open.onupgradeneeded = function () {
                    var db = open.result;
                    if (!db.objectStoreNames.contains("rom")) db.createObjectStore("rom");
                };
                open.onsuccess = function (event) {
                    var db = event.target.result;
                    post("stores: " + Array.from(db.objectStoreNames));
                    if (!db.objectStoreNames.contains("rom")) { post("no rom store"); return; }
                    var store = db.transaction("rom", "readonly").objectStore("rom");
                    // Keys only, never the values. An earlier version did
                    // store.get() on every entry to report byte sizes, and
                    // each get materializes the entry's full ROM bytes in
                    // this process: with a couple of gigabytes cached, one
                    // boot of this probe put the content process under
                    // memory pressure before the game even started, made
                    // play sluggish, and got the process killed mid game.
                    // The whole point of this app is that the player runs
                    // the same page Safari does; a diagnostic that ruins
                    // that is worse than no diagnostic.
                    var keysReq = store.get("?EJS_KEYS!");
                    keysReq.onsuccess = function () {
                        var keys = keysReq.result || [];
                        post("tracked keys (" + keys.length + "): " + JSON.stringify(keys));
                    };
                    keysReq.onerror = function () { post("key index read failed"); };
                };
            } catch (e) { post("exception " + e); }
        })();
        """
    #endif

    static func authInjection(token: String) -> String {
        // The request log only exists in debug builds (its handler is
        // registered under #if DEBUG), so release pages get a no-op
        // instead of building a string and probing for a listener on
        // every fetch and XHR the emulator makes.
        #if DEBUG
        let logRequestJS = """
              // Method included because EmulatorJS's cache-hit path still
              // sends one HEAD for the ROM URL on every launch: a lone
              // "HEAD .../content/..." line is a cache hit, HEAD followed by
              // GET on the same URL is a miss.
              const logRequest = (url, method) => {
                try {
                  if (window.webkit && window.webkit.messageHandlers.playerNetwork) {
                    window.webkit.messageHandlers.playerNetwork.postMessage(
                      (method ? method + " " : "") + String(url)
                    );
                  }
                } catch (e) {}
              };
            """
        #else
        let logRequestJS = "const logRequest = function () {};"
        #endif
        return """
        (function () {
          // Note from the crash investigation: a devicePixelRatio
          // override was tried here (canvas shrank 9x, verified) and
          // survival did not move, while a slower-rendering game lasted
          // proportionally longer. The leak is per frame PRESENTED at a
          // size the page cannot influence, so no in-page lever helps.
          const TOKEN = \(tokenLiteral(token));

          // A property trap once lived here forcing FBNeo's
          // allow-depth-32 option off, testing whether 32-bit frames
          // drove the webview leak. Verified applied through the
          // player's own settings screen, and the leak did not move, so
          // the override was removed rather than shipped: it would have
          // silently denied 32-bit color to everyone for no benefit.
          const sameOrigin = (url) => {
            try { return new URL(url, location.href).origin === location.origin; }
            catch { return false; }
          };

          \(logRequestJS)

          const origFetch = window.fetch;
          window.fetch = function (input, init) {
            try {
              const url = typeof input === "string" ? input : input && input.url;
              const method = (init && init.method) || (input instanceof Request && input.method) || "GET";
              logRequest(url, method);
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
            logRequest(url, method);
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

          // Resize traffic counter only. Earlier revisions also wrapped
          // the canvas's width/height setters (first to swallow
          // same-value sets, then to scale sizes down, chasing the
          // WebGL buffer leak): both variants blanked the picture on
          // device, RetroArch does not tolerate the canvas disagreeing
          // with the size it believes it set. Do not reintroduce
          // property interception on the game canvas.
          let resizeEvents = 0;
          window.addEventListener("resize", () => { resizeEvents += 1; }, true);

          // Animation heartbeat counter, measurement only. An earlier
          // revision also wrapped requestAnimationFrame to cap delivery
          // near 60; it shipped alongside the canvas interception that
          // blanked the picture, so both were pulled to get back to a
          // page that behaves exactly like the stock one. (Research
          // says the embedded webview is capped near 60 anyway.)
          let rafRaw = 0;
          const rafNative = window.requestAnimationFrame.bind(window);
          (function count(t) { rafRaw += 1; rafNative(count); })(0);
          let gameOn = false;
          let obsHits = 0;
          const gameObserver = new MutationObserver(() => {
            obsHits += 1;
            const toggle = document.querySelector(".ejs_virtualGamepad_open");
            const on = !!toggle && toggle.style.display !== "none";
            if (on !== gameOn) {
              gameOn = on;
              postGameState(on ? "started" : "stopped");
              if (on && window.__rommReportEmulation) {
                setTimeout(window.__rommReportEmulation, 400);
              }
              // The boot status observer's element is gone once the game
              // is up, but watching characterData across the whole
              // document keeps firing on every DOM tick EmulatorJS makes
              // during play. Off while a game runs, back on when it
              // stops, in case a next boot happens without a page load.
              // (Safe to reference here: observer callbacks are
              // asynchronous, so statusObserver below exists by the time
              // this runs.)
              try {
                if (on) statusObserver.disconnect();
                else statusObserver.observe(document.documentElement, {
                  subtree: true, childList: true, characterData: true,
                });
              } catch (e) {}
            }
          });
          gameObserver.observe(document.documentElement, {
            subtree: true,
            childList: true,
            attributes: true,
            attributeFilter: ["style"],
          });

          // Memory probe, debug builds only (logRequest is a no-op in
          // release). Jetsam reports show this process reaching its 2GB
          // cap within about a minute of arcade play, roughly 30MB/s of
          // growth a 30MB game cannot justify. Every ten seconds this
          // logs the numbers the page can actually see: the wasm heap's
          // size (the core's own memory), the DOM node count, and how
          // often the game observer fired, so one run says whether the
          // growth is the core's heap or the page around it.
          setInterval(() => {
            try {
              const e = window.EJS_emulator;
              if (!e || !e.started) return;
              // The wasm heap hides in different spots depending on the
              // build; try each and report which one answered.
              let heap = "?";
              const mods = [
                ["gm.Module", () => e.gameManager.Module],
                ["e.Module", () => e.Module],
                ["win.Module", () => window.Module],
                ["gm.wasm", () => e.gameManager],
              ];
              for (const [tag, get] of mods) {
                try {
                  const m = get();
                  const buf = m && (m.HEAP8 ? m.HEAP8.buffer
                    : m.HEAPU8 ? m.HEAPU8.buffer
                    : m.wasmMemory ? m.wasmMemory.buffer : null);
                  if (buf && buf.byteLength) {
                    heap = tag + ":" + Math.round(buf.byteLength / 1048576) + "MB";
                    break;
                  }
                } catch (x) {}
              }
              // Canvas backing stores: a runaway canvas size would cost
              // real memory per composited frame.
              let canv = "";
              try {
                const all = document.querySelectorAll("canvas");
                canv = all.length + "x[";
                all.forEach((c) => { canv += c.width + "*" + c.height + " "; });
                canv += "]";
              } catch (x) {}
              // Whether the injected 16-bit override actually reached the
              // core. Three sources, so the answer is definitive: what
              // the defaultOptions trap holds, what EmulatorJS resolved
              // into its settings, and what the core's option catalog
              // lists (choices only, no current value).
              let depth = "";
              try {
                depth += "trap:" + ((window.EJS_defaultOptions || {})["fbneo-allow-depth-32"] || "unset");
              } catch (x) {}
              try {
                const s = e.settings || (e.config && e.config.defaultOptions) || {};
                depth += ",settings:" + (JSON.stringify(s).match(/depth-32[^,}]*/) || ["absent"])[0];
              } catch (x) {}
              try {
                const opts = String(e.gameManager.getCoreOptions());
                depth += ",core:" + ((opts.match(/fbneo-allow-depth-32[^\\n]*/) || ["absent"])[0]).slice(0, 60);
              } catch (x) {}
              // Audio: a suspended or interrupted context that keeps
              // getting buffers queued into it is a classic growth path.
              let audio = "?";
              try {
                const ctx = (e.gameManager && e.gameManager.audioContext)
                  || e.audioContext || window.AL && window.AL.currentCtx
                    && window.AL.currentCtx.audioCtx;
                if (ctx) audio = ctx.state + "@" + ctx.sampleRate;
              } catch (x) {}
              logRequest(
                "[memprobe] heap=" + heap
                  + " depth=" + depth
                  + " canvas=" + canv
                  + " resize=" + resizeEvents
                  + " raf=" + Math.round(rafRaw / 10) + "Hz"
                  + " audio=" + audio
                  + " nodes=" + document.getElementsByTagName("*").length
                  + " obs=" + obsHits + "/10s"
                  + " t=" + Math.round(performance.now() / 1000) + "s"
              );
              obsHits = 0;
              resizeEvents = 0;
              rafRaw = 0;
            } catch (x) {}
          }, 10000);

          // EmulatorJS's own boot status, mirrored verbatim so the native
          // curtain can show real progress instead of a black flash while
          // this page loads underneath it. The element (.ejs_loading_text)
          // is created fresh each load and removed once the game starts,
          // so this re-queries on every mutation rather than caching a
          // reference, the same reasoning the game state observer above
          // already follows for its own element.
          let lastStatusText = null;
          const statusObserver = new MutationObserver(() => {
            const el = document.querySelector(".ejs_loading_text");
            const text = el ? el.innerText : null;
            if (text && text !== lastStatusText) {
              lastStatusText = text;
              try {
                window.webkit.messageHandlers.loadingStatus.postMessage(text);
              } catch (e) {}
            }
          });
          statusObserver.observe(document.documentElement, {
            subtree: true,
            childList: true,
            characterData: true,
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
        case .overlay(let items, let opacity), .bottomStrip(let items, _, _, let opacity):
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
        case .bottomStrip(_, let height, let headroom, _):
            let split = max(bounds.height - height, 0)
            webView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: split)
            let padHeight = height * (1 + headroom)
            pad.frame = CGRect(x: 0, y: bounds.height - padHeight, width: bounds.width, height: padHeight)
        }
    }
}

/// What the boot watchdog shows in place of the raw webview once it has
/// genuinely given up. White on black, matching `BootCurtain`'s own
/// styling rather than reaching for a system component here: a
/// `ContentUnavailableView` leans on adaptive colors tuned for a normal
/// page background, not the fixed black the player always sits on.
private struct PlayerLoadFailure: View {
    let reason: PlayerView.BootFailure
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: reason == .offline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.8))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
        }
    }

    private var title: String {
        reason == .offline ? "No connection to your server" : "This game couldn't load"
    }

    private var message: String {
        switch reason {
        case .offline: return "Check your signal, then try again."
        case .stalled: return "Something kept it from starting. Try again, or check your connection."
        }
    }
}
