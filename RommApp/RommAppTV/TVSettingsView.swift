#if os(tvOS)
import SwiftUI

/// The pairing listener and the player's game receiver must never
/// advertise at once; the player posts these so the Controllers page
/// can yield even when a fullScreenCover launch leaves it alive
/// underneath.
extension Notification.Name {
    static let cabinetGameLinkStarted = Notification.Name("com.mmagtech.RommAppTV.gameLinkStarted")
    static let cabinetGameLinkEnded = Notification.Name("com.mmagtech.RommAppTV.gameLinkEnded")
}

/// tvOS's settings, the scoped-down sibling of iOS's `SettingsView`.
///
/// A hub of five category rows, each pushing a flat page, the system
/// Settings app's own shape. On a television that beats one long
/// column: every row of scroll is focus travel on a remote, while a
/// short top level with pushed pages is a click. The rows carry their
/// live state (current profile, connected pads, server host) so most
/// glances are answered without entering anything, and no page nests
/// further than the links that already existed (Buttons, Cores): five
/// categories, one level, that is the whole structure.
///
/// Laid out as real cards rather than a `List`: a plain List on tvOS
/// gives every row the full width of a 1920pt canvas with a focus
/// plate to match. Cards in a bounded column look like the rest of
/// this app and leave the focus effect something sensibly sized to
/// land on.
struct TVSettingsView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var controllers = GameControllerManager.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    /// The Controllers row's live state: pads only, in a word. The
    /// page itself names each player.
    private var controllersDetail: String {
        let names = controllers.connectedNames.compactMap { $0 }
        switch names.count {
        case 0: return "None connected"
        case 1: return names[0]
        default: return "\(names.count) connected"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // No "Settings" heading: the tab bar already says it, and
                // repeating it directly underneath is an iOS habit that
                // buys nothing on a TV. Same reasoning as TVLibraryView.
                VStack(alignment: .leading, spacing: 16) {
                    NavigationLink {
                        TVAccountsSettingsView()
                    } label: {
                        SettingsUI.actionRow(
                            title: "Accounts",
                            detail: TVProfileStore.activeProfile?.label,
                            chevron: true
                        )
                    }
                    .buttonStyle(RowFocusStyle())

                    NavigationLink {
                        TVControllersSettingsView()
                    } label: {
                        SettingsUI.actionRow(
                            title: "Controllers",
                            detail: controllersDetail,
                            chevron: true
                        )
                    }
                    .buttonStyle(RowFocusStyle())

                    NavigationLink {
                        TVEmulationSettingsView()
                    } label: {
                        SettingsUI.actionRow(
                            title: "Emulation",
                            detail: "Cores and glow",
                            chevron: true
                        )
                    }
                    .buttonStyle(RowFocusStyle())

                    NavigationLink {
                        TVLibrarySettingsView()
                    } label: {
                        SettingsUI.actionRow(
                            title: "Library",
                            detail: "Sort by \((PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName).label.lowercased())",
                            chevron: true
                        )
                    }
                    .buttonStyle(RowFocusStyle())

                    NavigationLink {
                        TVServerSettingsView()
                    } label: {
                        SettingsUI.actionRow(
                            title: "Server",
                            detail: session.serverURL?.host,
                            chevron: true
                        )
                    }
                    .buttonStyle(RowFocusStyle())
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            .task { controllers.start() }
            .task {
                // Cheap no-op past "nothing to fetch": backfills a
                // profile that predates avatar/username fetching, same
                // as the Home chip, for whoever opens Settings without
                // visiting Home first in a session.
                if let profile = TVProfileStore.activeProfile {
                    TVProfileStore.enrichIfNeeded(profile)
                }
            }
        }
    }
}

// MARK: - Accounts

private struct TVAccountsSettingsView: View {
    @State private var showingAccountSwitcher = false
    @State private var settingPIN = false
    @AppStorage("com.mmagtech.RommAppTV.requirePINToSwitch") private var requirePIN = false
    @AppStorage("com.mmagtech.RommAppTV.switchPIN") private var storedPIN = ""

    var body: some View {
        SettingsUI.page("Accounts") {
            if let label = TVProfileStore.activeProfile?.label {
                SettingsUI.infoRow(label: "Current profile", value: label)
            }
            Button {
                showingAccountSwitcher = true
            } label: {
                SettingsUI.actionRow(title: "Switch or add a profile", detail: nil, chevron: true)
            }
            .buttonStyle(RowFocusStyle())
            Toggle(isOn: $requirePIN) {
                SettingsUI.actionRow(
                    title: "Require a PIN to switch",
                    detail: storedPIN.isEmpty ? "Set a PIN below first" : nil,
                    chevron: false
                )
            }
            .toggleStyle(.switch)
            .disabled(storedPIN.isEmpty)
            Button {
                settingPIN = true
            } label: {
                SettingsUI.actionRow(
                    title: storedPIN.isEmpty ? "Set a PIN" : "Change PIN",
                    detail: nil, chevron: true
                )
            }
            .buttonStyle(RowFocusStyle())
        }
        .fullScreenCover(isPresented: $showingAccountSwitcher) {
            TVAccountSwitcherView()
        }
        .fullScreenCover(isPresented: $settingPIN) {
            TVSetPINView { newPIN in
                storedPIN = newPIN
            }
        }
    }
}

// MARK: - Controllers

private struct TVControllersSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var controllers = GameControllerManager.shared

    /// Deliberately the iOS key, not a tvOS one: the core reads this exact
    /// name from Objective-C++, and it means the same thing on both.
    @AppStorage("com.mmagtech.RommApp.rumbleEnabled") private var rumbleEnabled = true
    /// Off by default, and the whole feature hangs from it: while this is
    /// off the television never binds a socket, so to the network the
    /// feature does not exist. See docs/scope-phone-controller-pairing.md.
    @AppStorage(ControllerPairing.allowKey) private var allowPhoneController = false
    /// The lobby: while this page is open with the switch on, the
    /// television listens so a phone can pair with no game running.
    /// Marcus's call on the first device run: a person turning the
    /// switch on and picking up their phone expects pairing to happen
    /// right here, not to first know that a game must be started. The
    /// socket stays bounded by presence, this page or a running game,
    /// nothing else.
    @State private var pairingLink: ControllerLinkReceiver?
    @State private var phonePairingCode: String?
    @State private var phoneLinkConnected = false
    @State private var confirmingForgetPhones = false

    var body: some View {
        SettingsUI.page("Controllers") {
            ForEach(Array(controllers.connectedNames.enumerated()), id: \.offset) { index, name in
                if let name {
                    SettingsUI.infoRow(label: "Player \(index + 1)", value: name)
                }
            }
            if controllers.connectedNames.allSatisfy({ $0 == nil }) {
                SettingsUI.infoRow(label: "No controller connected", value: "")
            }
            // An Apple TV has no Taptic Engine of its own, so unlike
            // iOS there is nothing to fall back to when a pad has no
            // motors of its own: the rumble is simply dropped rather
            // than coming out of the device.
            Toggle(isOn: $rumbleEnabled) {
                SettingsUI.actionRow(title: "Rumble", detail: nil, chevron: false)
            }
            .toggleStyle(.switch)
            NavigationLink {
                ControllerRemapView()
            } label: {
                SettingsUI.actionRow(title: "Buttons", detail: "Map any button to any input", chevron: true)
            }
            .buttonStyle(RowFocusStyle())
            // The phone-as-controller master switch. While this is off
            // the television never opens a socket, so the feature is
            // invisible to the network, not merely refusing
            // connections. No detail line on purpose: flipping the
            // switch on makes a live "Ready to pair" row appear right
            // below, which answers where and when better than a
            // sentence could. The title must not be reworded casually:
            // the phone's Settings footer quotes it verbatim.
            Toggle(isOn: $allowPhoneController) {
                SettingsUI.actionRow(
                    title: "Allow a phone as a controller",
                    detail: nil,
                    chevron: false
                )
            }
            .toggleStyle(.switch)
            if allowPhoneController {
                if let phonePairingCode {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Enter this code on the phone")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(ControllerPairing.displayCode(phonePairingCode))
                            .font(.system(size: 54, weight: .bold, design: .monospaced))
                    }
                    .padding(.vertical, 8)
                    .transition(.opacity)
                } else {
                    SettingsUI.infoRow(
                        label: phoneLinkConnected ? "Phone connected" : "Ready to pair",
                        value: ""
                    )
                }
                Button {
                    confirmingForgetPhones = true
                } label: {
                    SettingsUI.actionRow(
                        title: "Forget paired phones", detail: nil,
                        chevron: false, destructive: true
                    )
                }
                .buttonStyle(RowFocusStyle())
            }
        }
        .alert("Forget paired phones?", isPresented: $confirmingForgetPhones) {
            Button("Forget", role: .destructive) {
                ControllerPairing.forgetAllPairings()
                // A phone joined through the live lobby holds a valid
                // session key; bouncing the lobby ends it, so forget
                // means forgotten now, not at the next reconnect.
                stopPairingLobby()
                startPairingLobby()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each phone will need a new code to join again.")
        }
        // The lobby's whole lifecycle: alive while this page is in
        // front with the switch on and the app active, gone the moment
        // any of that stops being true, and yielding to a game's own
        // receiver when one starts over this page.
        .onAppear { startPairingLobby() }
        .onDisappear { stopPairingLobby() }
        .onChange(of: allowPhoneController) { _, on in
            if on { startPairingLobby() } else { stopPairingLobby() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startPairingLobby() } else { stopPairingLobby() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cabinetGameLinkStarted)) { _ in
            stopPairingLobby()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cabinetGameLinkEnded)) { _ in
            startPairingLobby()
        }
    }

    /// The Controllers page listening as a pairing lobby: the same
    /// receiver the player uses, with no game name (the lobby
    /// advertisement) and every game verb a no-op. A phone can pair
    /// and even join here; its panel side shows "start a game" until
    /// one is running.
    private func startPairingLobby() {
        guard allowPhoneController, pairingLink == nil, scenePhase == .active else { return }
        let link = ControllerLinkReceiver(
            shortname: "",
            assignPort: { phoneID in
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        GameControllerManager.shared.claimPhoneSlot(for: phoneID)
                    }
                }
            },
            releasePort: { phoneID in
                Task { @MainActor in
                    GameControllerManager.shared.releasePhoneSlot(for: phoneID)
                }
            },
            onButton: { _, _, _ in }, onStick: { _, _, _ in }, onRelative: { _, _, _ in },
            onPointer: { _, _, _, _ in }, onOffscreen: { _, _ in },
            onPause: { _ in }, onSave: {}, onLoad: {},
            onPhone: { joined in
                Task { @MainActor in phoneLinkConnected = joined }
            },
            onPairingCode: { code in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.25)) { phonePairingCode = code }
                }
            },
            onDrop: {}
        )
        link.start()
        pairingLink = link
    }

    private func stopPairingLobby() {
        guard pairingLink != nil else { return }
        pairingLink?.stop()
        pairingLink = nil
        phonePairingCode = nil
        phoneLinkConnected = false
        GameControllerManager.shared.releaseAllPhoneSlots()
    }
}

// MARK: - Emulation

private struct TVEmulationSettingsView: View {
    @AppStorage(BiasGlowLevel.storageKey) private var glowStored = BiasGlowLevel.subtle.rawValue
    @AppStorage(ExperimentalCores.key) private var experimentalCores = false

    var body: some View {
        SettingsUI.page("Emulation") {
            NavigationLink {
                TVNativeCoresView()
            } label: {
                SettingsUI.actionRow(
                    title: "Cores",
                    // "run natively" contrasted with the webview
                    // player, which exists on iOS and not here: on this
                    // platform every core is native, so the qualifier
                    // only raised the question it answered.
                    detail: "Speed and accuracy options for each emulator",
                    chevron: true
                )
            }
            .buttonStyle(RowFocusStyle())
            // The detail is blunter than the phone's because the stakes
            // are: iOS falls back to the web player when this is off,
            // while this platform has no other player, so off means
            // those libraries are not playable on this Apple TV at all.
            Toggle(isOn: $experimentalCores) {
                SettingsUI.actionRow(
                    title: "Experimental cores",
                    detail: "Dreamcast and Nintendo 64. Speed varies by game; off, this Apple TV can't play them.",
                    chevron: false
                )
            }
            .toggleStyle(.switch)
            // Mirror of the pause menu's Glow row, the primary home;
            // now that Off/Subtle/Strong are settled values rather
            // than something to tune live, a plain picker here is
            // enough.
            Menu {
                ForEach(BiasGlowLevel.allCases) { candidate in
                    Button {
                        glowStored = candidate.rawValue
                    } label: {
                        if candidate.rawValue == glowStored {
                            Label(candidate.label, systemImage: "checkmark")
                        } else {
                            Text(candidate.label)
                        }
                    }
                }
            } label: {
                SettingsUI.actionRow(
                    title: "Glow",
                    detail: "A soft light around the game picture. Currently \((BiasGlowLevel.level(fromStored: glowStored)).label.lowercased()).",
                    chevron: false
                )
            }
            .buttonStyle(RowFocusStyle())
        }
    }
}

// MARK: - Library

private struct TVLibrarySettingsView: View {
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    var body: some View {
        SettingsUI.page("Library") {
            // The same choice iOS offers, in this screen's own picker
            // idiom (the Menu + row pattern the Glow row established).
            // One key, so a choice made on either platform is only
            // cosmetic per device, never divergent data.
            Menu {
                ForEach(PlatformLabelSource.allCases, id: \.self) { source in
                    Button {
                        labelSourceRaw = source.rawValue
                    } label: {
                        if source.rawValue == labelSourceRaw {
                            Label(source.label, systemImage: "checkmark")
                        } else {
                            Text(source.label)
                        }
                    }
                }
            } label: {
                SettingsUI.actionRow(
                    title: "Names",
                    detail: "Sort by \((PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName).label.lowercased()).",
                    chevron: false
                )
            }
            .buttonStyle(RowFocusStyle())
        }
    }
}

// MARK: - Server

private struct TVServerSettingsView: View {
    @EnvironmentObject private var session: Session
    @State private var confirmingSignOut = false

    var body: some View {
        SettingsUI.page("Server") {
            if let host = session.serverURL?.host {
                SettingsUI.infoRow(label: "Connected to", value: host)
            }
            Button {
                confirmingSignOut = true
            } label: {
                SettingsUI.actionRow(title: "Sign out", detail: nil, chevron: false, destructive: true)
            }
            .buttonStyle(RowFocusStyle())
        }
        .alert("Sign out?", isPresented: $confirmingSignOut) {
            Button("Sign out", role: .destructive) {
                // Before forgetting the server, not after: the top
                // shelf outlives the app, so a signed-out Apple TV
                // that still lists somebody's games on the Home
                // screen is the one thing signing out has to stop.
                TVTopShelfWriter.wipe()
                session.forgetServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to pair this Apple TV with your server again.")
        }
    }
}

// MARK: - Shared pieces

/// The rows and page scaffold every settings page shares, pulled out
/// of the hub so the category pages read as one family.
private enum SettingsUI {
    /// A pushed page: plain large title in the scroll content, never
    /// .navigationTitle, which on tvOS paints over content instead of
    /// reserving space above it. Same pattern as every other pushed
    /// tvOS screen in this app.
    @ViewBuilder
    static func page(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .padding(.bottom, 8)
                content()
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 80)
            .padding(.vertical, 50)
        }
    }

    /// Real Liquid Glass on tvOS 26, not the flat `.ultraThinMaterial`
    /// this screen used before: the same "translucency standing in for
    /// glass" pattern used everywhere else in the app (the switcher
    /// pills, the Recent/Favorites chips, the save-state buttons, the
    /// pause menu). tvOS 18 keeps the flat material fallback, since
    /// `glassEffect` doesn't exist there.
    @ViewBuilder
    static func rowBackground() -> some View {
        if #available(tvOS 26.0, *) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
        }
    }

    static func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.title3)
            Spacer(minLength: 24)
            Text(value)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { rowBackground() }
    }

    static func actionRow(
        title: String, detail: String?, chevron: Bool, destructive: Bool = false
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { rowBackground() }
    }
}
#endif
