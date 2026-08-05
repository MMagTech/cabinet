import SafariServices
import SwiftUI

/// Second screen. The app asks the server to start a pairing, shows the short
/// code, and waits.
///
/// The password is never typed here. Approval happens in RomM's own web UI
/// where the person is already signed in, which is the whole point of the
/// device authorization flow: this app never sees the password, and the token
/// it ends up holding can be revoked from the server without changing it.
///
/// A tall stack with a 42 point code in it does not survive a landscape
/// phone, so the code sits beside the instructions there rather than above
/// them, and the whole thing scrolls if it still does not fit.
struct PairingView: View {
    @EnvironmentObject private var session: Session

    @State private var start: DeviceAuthInit?
    @State private var error: String?
    @State private var waiting = false
    @State private var showingApproval = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ScrollView {
                if landscape {
                    HStack(alignment: .top, spacing: 28) {
                        codePanel
                            .frame(maxWidth: .infinity, alignment: .leading)
                        instructions(landscape: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        heading
                        codePanel
                        instructions(landscape: false)
                    }
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                }
            }
        }
        .onAppear { begin() }
        .onDisappear { pollTask?.cancel() }
        // An in-app Safari sheet instead of handing off to the real Safari
        // app: the device flow has no redirect to pull anyone back, so
        // leaving the app stranded people wondering whether to return by
        // hand. With the sheet, the app stays visibly underneath, and the
        // pairing poll dismisses it the moment approval lands. Note this
        // sheet does not share cookies with real Safari, so an existing
        // web session there does not carry over; a passkey login (Pocket
        // ID and the like) works inside it regardless.
        .sheet(isPresented: $showingApproval) {
            if let start, let url = session.approvalURL(for: start) {
                SafariView(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: Pieces

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approve this device")
                .font(.largeTitle.bold())
            if let host = session.serverURL?.host {
                Text(host)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var codePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let start {
                Text("Your code")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(start.userCode)
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else if error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking the server for a code")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func instructions(landscape: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // In landscape the heading moves in here, beside the code, so the
            // two columns balance instead of one carrying everything.
            if landscape { heading }

            if let start {
                Button {
                    showingApproval = true
                } label: {
                    Text("Open RomM to approve")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                if waiting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for you to approve")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }

                Text("Sign in if asked, then approve the code. This closes on its own once approved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Try again") { begin() }
                    .buttonStyle(.bordered)
            }

            Button("Use a different server") { session.forgetServer() }
                .font(.footnote)
                .padding(.top, 4)
                // The last thing in the column, so it is the one that gets
                // clipped against the bottom edge without room of its own.
                .padding(.bottom, 16)
        }
    }

    // MARK: Flow

    private func begin() {
        pollTask?.cancel()
        start = nil
        error = nil
        waiting = false

        pollTask = Task {
            do {
                let started = try await session.startPairing()
                start = started
                waiting = true
                try await session.completePairing(started)
                // Approval landed while the Safari sheet was still up:
                // dismiss it explicitly rather than relying on this whole
                // view being swapped out from under an active sheet.
                showingApproval = false
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                waiting = false
                showingApproval = false
            }
        }
    }
}

/// `SFSafariViewController` for the approval page. Real Safari under the
/// hood, so passkey prompts work, which a plain `WKWebView` would need a
/// special entitlement for.
private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
