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

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let context {
                // The black backdrop bleeds under the Dynamic Island and home
                // indicator, but the page itself stays inside the safe area.
                // Rendered full bleed, the top of the game canvas sits under
                // the island and gets clipped on every notched device.
                PlayerWebView(url: context.url, token: context.token)
            } else if failed {
                VStack(spacing: 12) {
                    Text("Could not start the player.")
                        .foregroundStyle(.white)
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

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

    /// `.playback` or the phone's ringer switch silences the game.
    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

struct PlayerWebView: UIViewRepresentable {
    let url: URL
    let token: String

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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        // A game canvas, not a document. No scrolling, no bounce, no zoom.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        webView.load(request)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

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
          const style = document.createElement("style");
          style.textContent =
            ".r-v2-nav-bar, .r-v2-bottom-nav { display: none !important } " +
            "#r-v2-main { padding-top: 0 !important }";
          document.documentElement.appendChild(style);
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
