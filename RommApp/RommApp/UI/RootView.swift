import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        switch session.stage {
        case .needsServer:
            ServerSetupView()
        case .needsPairing:
            PairingView()
        case .ready:
            ConnectedView()
        }
    }
}

/// Placeholder for what becomes Home. For now it does one useful thing: makes a
/// real authenticated call, so pairing is proved end to end rather than assumed.
struct ConnectedView: View {
    @EnvironmentObject private var session: Session
    @State private var platforms: [Platform] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Loading your library")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error {
                        Text(error).foregroundStyle(.red)
                    } else if platforms.isEmpty {
                        Text("No platforms on this server yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(platforms) { platform in
                            HStack {
                                Text(platform.name ?? platform.slug)
                                Spacer()
                                Text("\(platform.romCount)")
                                    .foregroundStyle(.secondary)
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                } header: {
                    Text("Platforms")
                }

                Section {
                    LabeledContent("Server", value: session.serverURL?.host ?? "unknown")
                    if let version = session.serverVersion {
                        LabeledContent("RomM version", value: version)
                    }
                    Button("Unpair this device", role: .destructive) {
                        session.signOut()
                    }
                    Button("Use a different server", role: .destructive) {
                        session.forgetServer()
                    }
                } header: {
                    Text("Connection")
                }
            }
            .navigationTitle("Connected")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            platforms = try await session.platforms()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
