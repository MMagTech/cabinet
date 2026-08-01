import SwiftUI

/// First screen on a fresh install. Nobody's server is assumed or remembered,
/// so this is where anyone using the app puts in their own RomM address.
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
                Text("Enter the address of your own RomM server. It is the same address you use in a browser.")
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

            Text("You will not type a password here. The next step opens RomM in your browser, where you approve this device while signed in as yourself.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
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
