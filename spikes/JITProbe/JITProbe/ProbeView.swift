import SwiftUI
import WebKit

/// Throwaway spike for open item 1 in docs/scope-v0.1.md.
///
/// The scope doc rests on the claim that WKWebView's WebContent process carries
/// the dynamic code signing entitlement, so WASM cores get a real JIT while the
/// same cores linked into the app process would run interpreted. Everything
/// else in the design follows from that. This measures it rather than assuming
/// it, by running one identical integer loop three ways on the same device:
/// native Swift, WASM inside the webview, and JavaScript inside the webview.
///
/// Native Swift is the yardstick. It is compiled ahead of time and cannot be
/// anything other than full speed, so it fixes what this chip is capable of.
/// If the webview's WASM lands in the same order of magnitude, it is jitted.
/// If it is twenty times slower or worse, it is interpreted and the scope doc's
/// central assumption is wrong.
///
/// Everything runs unattended and prints to stdout, so a host driving the
/// device over a cable can collect the result without anyone tapping a screen.
struct ProbeView: View {
    @State private var native: (millionPerSec: Double, checksum: Int32)?
    @State private var web: ProbeResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProbeWebView(result: $web)

            VStack(alignment: .leading, spacing: 8) {
                Text("Native Swift reference")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let native {
                    Text(String(format: "%.1f M/s", native.millionPerSec))
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                } else {
                    Text("measuring")
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let verdict {
                    Text(verdict)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.thinMaterial)
        }
        .ignoresSafeArea(edges: .bottom)
        .task {
            // Off the main thread so the webview can load and run alongside it.
            let measured = await Task.detached(priority: .userInitiated) {
                NativeBench.measure()
            }.value
            native = measured
            report()
        }
        .onChange(of: web?.wasmMillionPerSec) { _, _ in report() }
    }

    private var verdict: String? {
        guard let native, let web else { return nil }
        let ratio = web.wasmMillionPerSec / native.millionPerSec
        return String(
            format: "wasm is %.2fx native  |  %@",
            ratio,
            ratio > 0.2 ? "JIT present" : "looks interpreted"
        )
    }

    /// One line to stdout once both halves have finished, for the cable host.
    private func report() {
        guard let native, let web else { return }
        let checksumsAgree = web.checksumAgrees && native.checksum == web.checksum
        print("""
        PROBE_RESULT \
        native=\(String(format: "%.1f", native.millionPerSec)) \
        wasm=\(String(format: "%.1f", web.wasmMillionPerSec)) \
        js=\(String(format: "%.1f", web.jsMillionPerSec)) \
        wasm_over_native=\(String(format: "%.3f", web.wasmMillionPerSec / native.millionPerSec)) \
        checksums_agree=\(checksumsAgree)
        """)
    }
}

struct ProbeResult {
    let wasmMillionPerSec: Double
    let jsMillionPerSec: Double
    let checksum: Int32
    let checksumAgrees: Bool
}

struct ProbeWebView: UIViewRepresentable {
    @Binding var result: ProbeResult?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "probe")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.bounces = false

        guard let url = Bundle.main.url(forResource: "bench", withExtension: "html") else {
            assertionFailure("bench.html missing from the bundle. Regenerate it with tools/build_jit_probe.py")
            return webView
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let parent: ProbeWebView

        init(_ parent: ProbeWebView) { self.parent = parent }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let wasm = body["wasmMillionPerSec"] as? Double,
                  let js = body["jsMillionPerSec"] as? Double
            else { return }

            parent.result = ProbeResult(
                wasmMillionPerSec: wasm,
                jsMillionPerSec: js,
                checksum: Int32(truncatingIfNeeded: body["checksum"] as? Int ?? 0),
                checksumAgrees: body["checksumAgrees"] as? Bool ?? false
            )
        }
    }
}
