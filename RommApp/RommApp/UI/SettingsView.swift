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
    @AppStorage(ControlTheme.key) private var controlTheme = ControlTheme.system.rawValue
    @AppStorage(PlayerAutosave.key) private var autosaveEnabled = true
    @AppStorage(PlatformLabelSource.key) private var platformLabelSourceRaw = PlatformLabelSource.platformName.rawValue
    @ObservedObject private var controllers = GameControllerManager.shared

    var body: some View {
        List {
            Section {
                // The name goes underneath rather than trailing. As a
                // LabeledContent value it was squeezed into whatever width
                // was left after the label, and a real controller name is
                // longer than that: "OhSnap MCON II" wrapped to a stack of
                // clipped lines, which rendered as an empty gap the height
                // of the wrap. Below the title it has the whole row.
                HStack(spacing: 10) {
                    Image(systemName: controllers.isConnected
                          ? "gamecontroller.fill" : "gamecontroller")
                        .foregroundStyle(controllers.isConnected
                                         ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Controller")
                        Text(controllers.isConnected
                             ? (controllers.controllerName ?? "Connected")
                             : "None connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
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
                Picker("Button colours", selection: $controlTheme) {
                    ForEach(ControlTheme.allCases, id: \.self) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                Text(ControlTheme(rawValue: controlTheme)?.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                Toggle("Autosave while playing", isOn: $autosaveEnabled)
                Text(autosaveEnabled
                     ? "Keeps a local snapshot every half minute so a game iOS closes costs seconds, not the run."
                     : "Off. Nothing is written while you play, and a game iOS closes starts over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Saving")
            }

            Section {
                Text(EmulationInfo.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if EmulationInfo.recoveries > 0 {
                    LabeledContent("Player reloads survived", value: "\(EmulationInfo.recoveries)")
                }
                if let vitals = EmulationInfo.vitalsAtDeath {
                    Text("Last reload happened at: \(vitals)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Emulation")
            } footer: {
                Text("Recorded from the last game you played.")
            }

            Section {
                Picker("Platform names", selection: $platformLabelSourceRaw) {
                    ForEach(PlatformLabelSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source.rawValue)
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("A server's metadata name and the folder a platform was scanned from can each be wrong in ways the other is not. Switch here if a platform looks strange.")
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
