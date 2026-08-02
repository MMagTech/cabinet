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

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var context: (url: URL, token: String)?
    @State private var failed = false
    @State private var overlayVisible = true
    @State private var gameStarted = false
    @StateObject private var input = PlayerInputBridge()
    @ObservedObject private var controllers = GameControllerManager.shared
    /// The scope doc's bet: the opacity slider matters more than any theme.
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7

    var body: some View {
        GeometryReader { geometry in
            content(isLandscape: geometry.size.width > geometry.size.height)
        }
    }

    private func content(isLandscape: Bool) -> some View {
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
                    overlayVisible: $overlayVisible,
                    gameStarted: $gameStarted,
                    input: input
                )
                .padding(
                    .bottom,
                    showsTouchControls && !isLandscape ? controlStripHeight : 0
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

            // The native pad replaces EmulatorJS's web touch controls, which
            // the injection hides. It appears once the game actually starts,
            // so RomM's pre play page stays fully tappable, and steps aside
            // entirely while a physical controller is driving.
            //
            // Portrait: a strip below the canvas. Landscape: the pad spans
            // the whole screen with controls in the gutters flanking the
            // centred canvas, and passes touches through everywhere else.
            // Orientation follows the device; the person holding the phone
            // decides, never the app.
            if showsTouchControls, let layout = controlLayout {
                if isLandscape {
                    TouchControlPad(items: layout.items(landscape: true)) { id, down in
                        input.send(id: id, down: down)
                    }
                    // A bridged UIKit view has no intrinsic size, so without
                    // this it collapsed to nothing and the landscape controls
                    // never appeared at all. Portrait was fine only because
                    // its strip is given an explicit height.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(controlOpacity)
                } else {
                    VStack {
                        Spacer()
                        TouchControlPad(items: layout.items(landscape: false)) { id, down in
                            input.send(id: id, down: down)
                        }
                        .frame(height: controlStripHeight)
                    }
                    .opacity(controlOpacity)
                }
            }

            // Fades in step with EmulatorJS's menu toggle so nothing sits
            // over the game during play. A tap on the game canvas brings
            // both back, mirroring the injected idle logic.
            Button {
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
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .defersSystemGestures(on: .all)
        .task {
            configureAudioSession()
            UIApplication.shared.isIdleTimerDisabled = true

            controllers.send = { id, down in input.send(id: id, down: down) }
            // The pad's menu button reveals the overlay, which is where
            // EmulatorJS's own menu and this screen's close button live.
            controllers.onMenu = {
                overlayVisible = true
                input.wakeOverlay()
            }
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
            UIApplication.shared.isIdleTimerDisabled = false
            // Detach this screen's callbacks without stopping the shared
            // manager, which Settings and the test screens also use.
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
            let profile = ArcadeProfileStore.shared.resolve(shortname: rom.fsNameNoExt)
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

    /// Vertical games trade some control height for canvas: their picture is
    /// taller than wide and every point matters, while their genres, mostly
    /// shooters, need fewer and simpler inputs.
    private var controlStripHeight: CGFloat {
        if rom.isArcade,
           ArcadeProfileStore.shared.resolve(shortname: rom.fsNameNoExt).vertical {
            return 280
        }
        return 330
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

    func send(id: Int, down: Bool) {
        let js = "window.EJS_emulator && EJS_emulator.gameManager"
            + " && EJS_emulator.gameManager.simulateInput(0, \(id), \(down ? 1 : 0));"
        webView?.evaluateJavaScript(js)
    }

    /// Reveals the overlay from native code, for controllers with no screen
    /// to tap. The page then reports visibility back the usual way.
    func wakeOverlay() {
        webView?.evaluateJavaScript(
            "window.__rommWakeOverlay && window.__rommWakeOverlay();"
        )
    }

    /// Pauses the running game, used when a controller disconnects mid play.
    func pauseGame() {
        webView?.evaluateJavaScript(
            "window.EJS_emulator && !EJS_emulator.paused && EJS_emulator.pause();"
        )
    }
}

struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let token: String
    let launch: LaunchChoices
    let rom: Rom
    @Binding var overlayVisible: Bool
    @Binding var gameStarted: Bool
    let input: PlayerInputBridge

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let parent: PlayerWebView

        init(_ parent: PlayerWebView) { self.parent = parent }

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
    }

    func makeUIView(context: Context) -> WKWebView {
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
                    source: Self.autoStartInjection(expecting: launch.core),
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                )
            )
        }

        config.userContentController.add(context.coordinator, name: "overlay")
        config.userContentController.add(context.coordinator, name: "gameState")
        config.userContentController.add(context.coordinator, name: "diag")

        let webView = WKWebView(frame: .zero, configuration: config)
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
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.scrollView.isScrollEnabled = !gameStarted
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
    static func autoStartInjection(expecting core: String?) -> String {
        let expected: String
        if let core, let data = try? JSONEncoder().encode(core),
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
