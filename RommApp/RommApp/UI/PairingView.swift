import SwiftUI

/// Second screen. The app asks the server to start a pairing, shows the short
/// code, and waits.
///
/// The password is never typed here. Approval happens in RomM's own web UI
/// where the person is already signed in, which is the whole point of the
/// device authorization flow: this app never sees the password, and the token
/// it ends up holding can be revoked from the server without changing it.
struct PairingView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.openURL) private var openURL

    @State private var start: DeviceAuthInit?
    @State private var error: String?
    @State private var waiting = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Approve this device")
                    .font(.largeTitle.bold())
                if let host = session.serverURL?.host {
                    Text(host)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let start {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your code")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(start.userCode)
                        .font(.system(size: 42, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                }

                Button {
                    if let url = session.approvalURL(for: start) { openURL(url) }
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

                Text("Sign in to RomM in the browser if you are not already, then approve the code above. This screen continues on its own.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if error == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Asking the server for a code")
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Try again") { begin() }
                    .buttonStyle(.bordered)
            }

            Spacer()

            Button("Use a different server") { session.forgetServer() }
                .font(.footnote)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(24)
        .onAppear { begin() }
        .onDisappear { pollTask?.cancel() }
    }

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
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                waiting = false
            }
        }
    }
}
