import SwiftUI

/// Server and pairing status, per the scope doc.
///
/// The destructive actions live here, behind a deliberate navigation, after one
/// of them got fired by a stray tap when it sat inside the library list and
/// shifted position while platforms were still loading.
struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @State private var confirmingUnpair = false
    @State private var confirmingForget = false
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7
    @AppStorage("com.mmagtech.RommApp.useRommPlayerScreen") private var useRommScreen = false
    @ObservedObject private var controllers = GameControllerManager.shared

    var body: some View {
        List {
            Section {
                LabeledContent("Controller") {
                    if controllers.isConnected {
                        Label(
                            controllers.controllerName ?? "Connected",
                            systemImage: "gamecontroller.fill"
                        )
                        .foregroundStyle(.green)
                    } else {
                        Text("None connected")
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    ControllerTestView()
                } label: {
                    Label("Test controller", systemImage: "checklist")
                }
                NavigationLink {
                    ControllerRemapView()
                } label: {
                    Label("Change buttons", systemImage: "arrow.triangle.swap")
                }
            } header: {
                Text("Physical controller")
            } footer: {
                Text("Pair a controller in the Settings app under General, then Game Controller. On screen controls hide while one is connected.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Touch control visibility")
                        Spacer()
                        Text("\(Int(controlOpacity * 100))%")
                            .foregroundStyle(.secondary)
                            .font(.callout.monospacedDigit())
                    }
                    Slider(value: $controlOpacity, in: 0.25...1.0, step: 0.05)
                }
            } header: {
                Text("Controls")
            } footer: {
                Text("How strongly the on screen controls show over the game. They respond to touch at any visibility.")
            }

            Section {
                Toggle("Use RomM's own launch screen", isOn: $useRommScreen)
            } header: {
                Text("Launching games")
            } footer: {
                Text("Off means Cabinet shows its own screen for choosing an emulator, BIOS and save. On hands that back to RomM's web page, which is always available as a fallback.")
            }

            Section {
                LabeledContent("Threading") {
                    Text(EmulationInfo.isThreaded ? "On" : "Off")
                        .foregroundStyle(EmulationInfo.isThreaded ? .green : .secondary)
                }
                Text(EmulationInfo.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Emulation")
            } footer: {
                Text("Recorded from the last game you played. Multiple cores need the server to send cross origin isolation headers.")
            }

            Section {
                LabeledContent("Server", value: session.serverURL?.host ?? "unknown")
                if let version = session.serverVersion {
                    LabeledContent("RomM version", value: version)
                }
            } header: {
                Text("Connection")
            }

            Section {
                Button("Unpair this device", role: .destructive) {
                    confirmingUnpair = true
                }
                Button("Use a different server", role: .destructive) {
                    confirmingForget = true
                }
            } footer: {
                Text("Unpairing signs this device out but remembers the server. Switching servers forgets everything.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { controllers.start() }
        .confirmationDialog(
            "Unpair this device?",
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { session.signOut() }
        } message: {
            Text("You will need to approve this device again to reconnect.")
        }
        .confirmationDialog(
            "Forget this server?",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("Forget server", role: .destructive) { session.forgetServer() }
        } message: {
            Text("The saved address and pairing are removed.")
        }
    }
}
