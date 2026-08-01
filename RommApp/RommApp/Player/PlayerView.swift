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

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var context: (url: URL, token: String)?
    @State private var failed = false
    @State private var overlayVisible = true
    @State private var gameStarted = false
    @StateObject private var input = PlayerInputBridge()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let context {
                // The black backdrop bleeds under the Dynamic Island and home
                // indicator, but the page itself stays inside the safe area.
                // Rendered full bleed, the top of the game canvas sits under
                // the island and gets clipped on every notched device.
                PlayerWebView(
                    url: context.url,
                    token: context.token,
                    overlayVisible: $overlayVisible,
                    gameStarted: $gameStarted,
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

            // The native pad replaces EmulatorJS's web touch controls, which
            // the injection hides. It appears once the game actually starts,
            // so RomM's pre play page stays fully tappable.
            if gameStarted, let layout = controlLayout {
                VStack {
                    Spacer()
                    TouchControlPad(layout: layout) { id, down in
                        input.send(id: id, down: down)
                    }
                    .frame(height: 330)
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
            if let context = await session.playerContext(for: rom) {
                self.context = context
            } else {
                failed = true
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
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
}

struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let token: String
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
        config.userContentController.add(context.coordinator, name: "overlay")
        config.userContentController.add(context.coordinator, name: "gameState")

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
          // the cleanest signal the page offers. Watch for that and tell the
          // native side, so the control pad appears with the game and never
          // over RomM's pre play screen.
          const startObserver = new MutationObserver(() => {
            const toggle = document.querySelector(".ejs_virtualGamepad_open");
            if (toggle && toggle.style.display !== "none") {
              try {
                window.webkit.messageHandlers.gameState.postMessage("started");
              } catch (e) {}
              startObserver.disconnect();
            }
          });
          startObserver.observe(document.documentElement, {
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
