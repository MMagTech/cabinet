import SwiftUI

/// Where someone tells Cabinet how to reach their own server without leaving
/// the house.
///
/// The address is typed, not discovered. Real discovery would mean RomM
/// advertising itself over Bonjour, which is the server's decision to make,
/// not something a client can add on its own.
///
/// iOS only today. tvOS compiles the routing underneath this screen and
/// behaves exactly as before while no local address is set there.
struct LocalAddressView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var checking = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                TextField("192.168.1.50:8080", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { save() }

                Button {
                    save()
                } label: {
                    if checking {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .disabled(checking || address.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Your server's other address")
            } footer: {
                Text("Add your server's address on this network if you set Cabinet up with its internet address, or the other way round. Cabinet works out which is which and uses the one on this network whenever it can. It checks the address answers before saving it. Type http:// or https:// yourself if your server needs a particular one.")
            }

            if let failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if session.localServerURL != nil {
                Section {
                    Button("Remove second address", role: .destructive) {
                        Task {
                            try? await session.setLocalAddress(nil)
                            address = ""
                        }
                    }
                } footer: {
                    Text("Everything goes back to \(session.serverURL?.host ?? "your server address").")
                }
            }
        }
        .navigationTitle("Second address")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if address.isEmpty, let existing = session.localServerURL {
                address = existing.absoluteString
            }
        }
    }

    private func save() {
        guard !checking else { return }
        checking = true
        failure = nil
        Task {
            do {
                try await session.setLocalAddress(address)
                checking = false
                dismiss()
            } catch {
                failure = error.localizedDescription
                checking = false
            }
        }
    }
}
