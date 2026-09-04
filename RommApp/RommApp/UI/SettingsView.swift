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
    @AppStorage(RaisedControls.key) private var raisedControls = true
    @AppStorage(ControlTheme.key) private var controlTheme = ControlTheme.system.rawValue
    @AppStorage(PlayerAutosave.key) private var autosaveEnabled = true
    @AppStorage(ExperimentalCores.key) private var experimentalCores = false
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
                ControllerStatusRow()
                NavigationLink {
                    ControllerRemapView()
                } label: {
                    Label("Change buttons", systemImage: "arrow.triangle.swap")
                }
                #if targetEnvironment(macCatalyst)
                // The Mac's own front door to the phone controller. The
                // television reaches the same feature from its own
                // settings; iOS is the phone side of it and has no host
                // screen to offer.
                NavigationLink {
                    MacPhonePairingView()
                } label: {
                    Label("Phone controller", systemImage: "iphone.gen3")
                }
                // With the pad, where it belongs: on the Mac the Controls
                // section below is phone-only touch settings, and a
                // section holding one toggle was a leftover of that.
                Toggle("Rumble", isOn: $rumbleEnabled)
                #endif
            } header: {
                Text("Physical controller")
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("Games are played with a controller. Pair one to this Mac over Bluetooth.")
                #else
                Text("On screen controls hide while one is connected.")
                #endif
            }
            .tvRow()

            #if !targetEnvironment(macCatalyst)
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

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Raised controls", isOn: $raisedControls)
                    Text("Off draws them flat, which is easier to read.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Toggle("Rumble", isOn: $rumbleEnabled)
            } header: {
                Text("Controls")
            }
            .tvRow()
            #endif

            // Letterbox glow lives in the Mac's View menu; see MacMenus.

            #if !targetEnvironment(macCatalyst)
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
            .tvRow()

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
            .tvRow()

            Section {
                Toggle("Autosave while playing", isOn: $autosaveEnabled)
            } header: {
                Text("Saving")
            } footer: {
                Text("Web player only. Save states in the native player are manual.")
            }
            .tvRow()
            #endif

            // On the Mac this is View > Show Platforms By; see MacMenus.
            #if !targetEnvironment(macCatalyst)
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
            .tvRow()
            #endif

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
                #if targetEnvironment(macCatalyst)
                // The account actions live with the account, the way a
                // Mac app's account pane keeps Sign Out beside the
                // server it signs out of. Apple's words, not the phone's
                // "unpair": a Mac is not a device you pair.
                Button("Sign Out…", role: .destructive) {
                    confirmingUnpair = true
                }
                Button("Switch Server…", role: .destructive) {
                    confirmingForget = true
                }
                #endif
            } header: {
                #if targetEnvironment(macCatalyst)
                Text("Server")
                #else
                Text("Connection")
                #endif
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("If your server has a second address, Cabinet uses whichever one is on this network. Signing out keeps the server; switching servers forgets everything.")
                #else
                Text("If your server has a second address, Cabinet uses whichever one is on this network, and the other when you're away.")
                #endif
            }
            .tvRow()

            Section {
                NavigationLink {
                    StorageView()
                } label: {
                    Label("Storage", systemImage: "internaldrive")
                }
                #if targetEnvironment(macCatalyst)
                // The Mac's own gesture for a folder an app fills.
                Button("Show in Finder") {
                    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Cabinet", isDirectory: true)
                    UIApplication.shared.open(folder)
                }
                #endif
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("Games kept on this Mac, in Documents/Cabinet.")
                #else
                Text("Games kept on this phone, and the web player's own cache.")
                #endif
            }
            .tvRow()

            Section {
                NavigationLink {
                    NativeCoresView()
                } label: {
                    Label("Native cores", systemImage: "cpu")
                }
                #if !targetEnvironment(macCatalyst)
                Toggle(isOn: $experimentalCores) {
                    Label("Experimental cores", systemImage: "testtube.2")
                }
                #endif
            } footer: {
                #if targetEnvironment(macCatalyst)
                Text("Speed and accuracy options for the native cores.")
                #else
                Text("Speed and accuracy options for the cores that run natively instead of in the webview.\n\nExperimental cores are Dreamcast and Nintendo 64. Speed varies by game. Off, Nintendo 64 uses the web player and Dreamcast is unavailable.")
                #endif
            }
            .tvRow()

            // On the Mac, Licenses and Credits are behind About and
            // Debug is Help > Diagnostics; see MacMenus and MacAboutView.
            #if !targetEnvironment(macCatalyst)
            Section {
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses", systemImage: "doc.text")
                }
            } footer: {
                Text("The software this app is built from, and the terms it ships under.")
            }
            .tvRow()

            Section {
                NavigationLink {
                    DebugView()
                } label: {
                    Label("Diagnostics", systemImage: "ladybug")
                }
            } footer: {
                Text("Diagnostics for reporting a problem.")
            }
            .tvRow()

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
            .tvRow()
            #endif

            #if !targetEnvironment(macCatalyst)
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
            .tvRow()
            #endif
        }
        #if targetEnvironment(macCatalyst)
        // The TV settings screen's read at a desk: rows as glass over
        // the ambient shell, no opaque grouped-list slab, every
        // section carrying the same material the TV's RowFocusStyle
        // paints. tvRow() below is what each Section wears.
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { controllers.start() }
        .fullScreenCover(isPresented: $showingControllerPad) {
            ControllerPadView()
        }
        .confirmationDialog(
            Self.signOutTitle,
            isPresented: $confirmingUnpair,
            titleVisibility: .visible
        ) {
            Button(Self.signOutAction, role: .destructive) {
                // Both outlive the pairing they describe if left alone: a
                // widget still showing the last account's games on a
                // shared home screen, and Spotlight results naming them.
                WidgetWriter.wipe()
                SpotlightIndexer.wipe()
                session.signOut()
            }
        } message: {
            Text("You will need to approve this device again to reconnect.")
        }
        .confirmationDialog(
            Self.switchTitle,
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button(Self.switchAction, role: .destructive) {
                // Same hygiene as Unpair above.
                WidgetWriter.wipe()
                SpotlightIndexer.wipe()
                session.forgetServer()
            }
        } message: {
            Text("The saved address and pairing are removed.")
        }
    }

    // The Mac says sign out and switch; the phone and TV keep unpair
    // and forget, which is how their pairing was introduced to them.
    #if targetEnvironment(macCatalyst)
    private static let signOutTitle = "Sign out?"
    private static let signOutAction = "Sign Out"
    private static let switchTitle = "Switch server?"
    private static let switchAction = "Switch Server"
    #else
    private static let signOutTitle = "Unpair this device?"
    private static let signOutAction = "Unpair"
    private static let switchTitle = "Forget this server?"
    private static let switchAction = "Forget server"
    #endif
}

