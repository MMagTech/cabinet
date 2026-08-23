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
    @AppStorage("com.mmagtech.RommApp.rumbleEnabled") private var rumbleEnabled = true
    @AppStorage(ControlTheme.key) private var controlTheme = ControlTheme.system.rawValue
    @AppStorage(PlayerAutosave.key) private var autosaveEnabled = true
    @AppStorage(PlatformLabelSource.key) private var platformLabelSourceRaw = PlatformLabelSource.platformName.rawValue
    @AppStorage(AimSpeed.key) private var aimSpeedRaw = AimSpeed.snap.rawValue
    @ObservedObject private var controllers = GameControllerManager.shared
    /// The TV Controller front door. Settings is where the feature is
    /// discovered; Home only grows its shortcut row once a pairing
    /// exists, so nobody without an Apple TV ever sees it there.
    @State private var showingControllerPad = false

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
                        if controllers.isConnected {
                            // One line per connected slot, not just player 1:
                            // this row used to show a single name back when
                            // only one controller could ever be attached at
                            // once, and kept doing that even after a second
                            // player became possible.
                            ForEach(Array(controllers.connectedNames.enumerated()), id: \.offset) { index, name in
                                if let name {
                                    Text("Player \(index + 1): \(name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                            }
                        } else {
                            Text("None connected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                Text("On screen controls hide while one is connected.")
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

                Toggle("Rumble", isOn: $rumbleEnabled)
            } header: {
                Text("Controls")
            }

            Section {
                Button {
                    showingControllerPad = true
                } label: {
                    Label("TV Controller", systemImage: "appletv")
                        .foregroundStyle(.primary)
                }
            } footer: {
                Text("Requires \u{201C}Allow a phone as a controller\u{201D} in Cabinet\u{2019}s settings on the TV.")
            }

            Section {
                Picker("Aim speed", selection: $aimSpeedRaw) {
                    ForEach(AimSpeed.allCases, id: \.self) { speed in
                        Text(speed.label).tag(speed.rawValue)
                    }
                }
            } header: {
                Text("Lightgun")
            } footer: {
                Text("How far a flick of the wrist moves the aim. Recenter lives on the controller itself.")
            }

            Section {
                Toggle("Autosave while playing", isOn: $autosaveEnabled)
            } header: {
                Text("Saving")
            } footer: {
                Text("Web player only. Save states in the native player are manual.")
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
                Text("If a platform's name looks wrong, switching the source here usually fixes it.")
            }

            Section {
                LabeledContent("Server", value: session.serverURL?.host ?? "unknown")
                if let version = session.serverVersion {
                    LabeledContent("RomM version", value: version)
                }
                NavigationLink {
                    LocalAddressView()
                } label: {
                    LabeledContent(
                        "Second address",
                        value: session.localServerURL?.host ?? "Not set"
                    )
                }
                if session.localServerURL != nil {
                    LabeledContent(
                        "Using",
                        value: session.isUsingLocalAddress ? "Local network" : "Internet"
                    )
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("If your server has a second address, Cabinet uses whichever one is on this network, and the other when you're away.")
            }

            Section {
                NavigationLink {
                    StorageView()
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
            } footer: {
                Text("Games kept on this phone, and the web player's own cache.")
            }

            Section {
                NavigationLink {
                    NativeCoresView()
                } label: {
                    Label("Native cores", systemImage: "cpu")
                }
            } footer: {
                Text("Speed and accuracy options for the cores that run natively instead of in the webview.")
            }

            Section {
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                }
            } footer: {
                Text("The software this app is built from, and the terms it ships under.")
            }

            Section {
                NavigationLink {
                    DebugView()
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
            } footer: {
                Text("Diagnostics for reporting a problem.")
            }

            Section {
                Link(destination: URL(string: "https://github.com/rommapp/romm")!) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } label: {
                        Text("RomM")
                    }
                }
                Link(destination: URL(string: "https://github.com/ilyas-hallak/romm-ios-app")!) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } label: {
                        Text("romm-ios-app")
                    }
                }
            } header: {
                Text("Credits")
            } footer: {
                Text("Cabinet talks to your RomM server, built by the RomM project and team. It was inspired by romm-ios-app, an earlier native client for RomM.")
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
        .fullScreenCover(isPresented: $showingControllerPad) {
            ControllerPadView()
        }
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
