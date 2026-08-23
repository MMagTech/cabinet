#if os(tvOS)
import SwiftUI

/// The pairing listener and the player's game receiver must never
/// advertise at once; the player posts these so this screen can yield
/// even when a fullScreenCover launch leaves it alive underneath.
extension Notification.Name {
    static let cabinetGameLinkStarted = Notification.Name("com.mmagtech.RommAppTV.gameLinkStarted")
    static let cabinetGameLinkEnded = Notification.Name("com.mmagtech.RommAppTV.gameLinkEnded")
}

/// tvOS's settings screen, the scoped-down sibling of iOS's
/// `SettingsView`. That one is a long `Form` because it also owns Storage
/// (kept games), the EmulatorJS cache bridge, native core options and the
/// debug screen. Most of it is either iOS-only by design (kept games do
/// not exist here, tvOS's storage is a transient same-network cache) or
/// not yet ported.
///
/// Laid out as real cards rather than a `List`: a plain List on tvOS gives
/// every row the full width of a 1920pt canvas with a focus plate to
/// match, so four short rows read as four enormous grey bands. Cards in a
/// bounded column look like the rest of this app and leave the focus
/// effect something sensibly sized to land on.
struct TVSettingsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var confirmingSignOut = false
    @State private var showingAccountSwitcher = false
    @State private var settingPIN = false

    @AppStorage("com.mmagtech.RommAppTV.requirePINToSwitch") private var requirePIN = false
    @AppStorage("com.mmagtech.RommAppTV.switchPIN") private var storedPIN = ""
    @AppStorage(BiasGlowLevel.storageKey) private var glowStored = BiasGlowLevel.subtle.rawValue
    /// Deliberately the iOS key, not a tvOS one: the core reads this exact
    /// name from Objective-C++, and it means the same thing on both.
    @AppStorage("com.mmagtech.RommApp.rumbleEnabled") private var rumbleEnabled = true
    /// Off by default, and the whole feature hangs from it: while this is
    /// off the television never binds a socket, so to the network the
    /// feature does not exist. See docs/scope-phone-controller-pairing.md.
    @AppStorage(ControllerPairing.allowKey) private var allowPhoneController = false
    /// The lobby: while this screen is visible with the switch on, the
    /// television listens so a phone can pair with no game running.
    /// Marcus's call on the first device run: a person turning the
    /// switch on and picking up their phone expects pairing to happen
    /// right here, not to first know that a game must be started. The
    /// socket stays bounded by presence, this screen or a running
    /// game, nothing else.
    @State private var pairingLink: ControllerLinkReceiver?
    @State private var phonePairingCode: String?
    @State private var phoneLinkConnected = false
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    var body: some View {
        NavigationStack {
            ScrollView {
                // No "Settings" heading: the tab bar already says it, and
                // repeating it directly underneath is an iOS habit that
                // buys nothing on a TV. Same reasoning as TVLibraryView.
                VStack(alignment: .leading, spacing: 40) {
                    section("Accounts") {
                        if let label = TVProfileStore.activeProfile?.label {
                            infoRow(label: "Current profile", value: label)
                        }
                        Button {
                            showingAccountSwitcher = true
                        } label: {
                            actionRow(title: "Switch or add a profile", detail: nil, chevron: true)
                        }
                        .buttonStyle(RowFocusStyle())
                        Toggle(isOn: $requirePIN) {
                            actionRow(
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
                            actionRow(
                                title: storedPIN.isEmpty ? "Set a PIN" : "Change PIN",
                                detail: nil, chevron: true
                            )
                        }
                        .buttonStyle(RowFocusStyle())
                    }

                    section("Controllers") {
                        ForEach(Array(controllers.connectedNames.enumerated()), id: \.offset) { index, name in
                            if let name {
                                infoRow(label: "Player \(index + 1)", value: name)
                            }
                        }
                        if controllers.connectedNames.allSatisfy({ $0 == nil }) {
                            infoRow(label: "No controller connected", value: "")
                        }
                        // An Apple TV has no Taptic Engine of its own, so
                        // unlike iOS there is nothing to fall back to when a
                        // pad has no motors of its own: the rumble is simply
                        // dropped rather than coming out of the device.
                        Toggle(isOn: $rumbleEnabled) {
                            actionRow(title: "Rumble", detail: nil, chevron: false)
                        }
                        .toggleStyle(.switch)
                        NavigationLink {
                            ControllerRemapView()
                        } label: {
                            actionRow(title: "Buttons", detail: "Map any button to any input", chevron: true)
                        }
                        .buttonStyle(RowFocusStyle())
                        // The phone-as-controller master switch. While
                        // this is off the television never opens a
                        // socket, so the feature is invisible to the
                        // network, not merely refusing connections.
                        // No detail line on purpose: flipping the
                        // switch on makes a live "Ready to pair" row
                        // appear right below, which answers where and
                        // when better than a sentence could. The title
                        // must not be reworded casually: the phone's
                        // Settings footer quotes it verbatim.
                        Toggle(isOn: $allowPhoneController) {
                            actionRow(
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
                                infoRow(
                                    label: phoneLinkConnected ? "Phone connected" : "Ready to pair",
                                    value: ""
                                )
                            }
                        }
                    }

                    section("Emulation") {
                        NavigationLink {
                            TVNativeCoresView()
                        } label: {
                            actionRow(
                                title: "Cores",
                                // "run natively" contrasted with the
                                // webview player, which exists on iOS
                                // and not here: on this platform every
                                // core is native, so the qualifier only
                                // raised the question it answered.
                                detail: "Speed and accuracy options for each emulator",
                                chevron: true
                            )
                        }
                        .buttonStyle(RowFocusStyle())
                        // Mirror of the pause menu's Glow row, the
                        // primary home; now that Off/Subtle/Strong are
                        // settled values rather than something to tune
                        // live, a plain picker here is enough.
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
                            actionRow(
                                title: "Glow",
                                detail: "A soft light around the game picture. Currently \((BiasGlowLevel.level(fromStored: glowStored)).label.lowercased()).",
                                chevron: false
                            )
                        }
                        .buttonStyle(RowFocusStyle())
                    }

                    section("Library") {
                        // The same choice iOS offers, in this screen's
                        // own picker idiom (the Menu + row pattern the
                        // Glow row established). One key, so a choice
                        // made on either platform is only cosmetic per
                        // device, never divergent data.
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
                            actionRow(
                                title: "Names",
                                detail: "Sort by \((PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName).label.lowercased()).",
                                chevron: false
                            )
                        }
                        .buttonStyle(RowFocusStyle())
                    }

                    section("Server") {
                        if let host = session.serverURL?.host {
                            infoRow(label: "Connected to", value: host)
                        }
                        Button {
                            confirmingSignOut = true
                        } label: {
                            actionRow(title: "Sign out", detail: nil, chevron: false, destructive: true)
                        }
                        .buttonStyle(RowFocusStyle())
                    }
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
            // The lobby's whole lifecycle: alive while this screen is
            // in front with the switch on and the app active, gone the
            // moment any of that stops being true, and yielding to a
            // game's own receiver when one starts over this screen.
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

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Real Liquid Glass on tvOS 26, not the flat `.ultraThinMaterial`
    /// this screen used before: the same "translucency standing in for
    /// glass" pattern replaced everywhere else in the app today (the
    /// switcher pills, the Recent/Favorites chips, the save-state
    /// buttons, the pause menu), just missed here since this screen
    /// hadn't been touched yet. tvOS 18 keeps the flat material fall
    /// back, since `glassEffect` doesn't exist there.
    @ViewBuilder
    static func rowGlassBackground() -> some View {
        if #available(tvOS 26.0, *) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
        }
    }
    private func rowBackground() -> some View { Self.rowGlassBackground() }

    /// The settings screen listening as a pairing lobby: the same
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

    private func infoRow(label: String, value: String) -> some View {
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

    private func actionRow(
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
