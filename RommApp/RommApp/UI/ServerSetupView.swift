import SwiftUI

/// Where a RomM address gets typed. Shared by both platforms: on tvOS
/// this is the first screen on a fresh install, on iOS it sits behind
/// the first door of `WelcomeView`.
///
/// The copy is deliberately short. A field showing romm.example.com
/// already says "enter an address", and the old footnote spent
/// twenty-six words narrating the pairing screen, which explains
/// itself when it arrives. What survives is the one thing someone
/// genuinely wonders here: no password is coming.
struct ServerSetupView: View {
    @EnvironmentObject private var session: Session
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Text("Connect to RomM")
                    .font(.largeTitle.bold())
                Text("The same address you open in a browser.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("romm.example.com", text: $address)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .padding(14)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                    .onSubmit { Task { await connect() } }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Button {
                Task { await connect() }
            } label: {
                HStack(spacing: 8) {
                    if checking { ProgressView().tint(.white) }
                    Text(checking ? "Checking" : "Continue")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || checking)

            Text("No password here. You approve this device in RomM itself.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .padding(24)
        .onAppear { addressFocused = true }
    }

    private func connect() async {
        checking = true
        error = nil
        do {
            try await session.connect(toAddress: address)
        } catch {
            self.error = error.localizedDescription
        }
        checking = false
    }
}
