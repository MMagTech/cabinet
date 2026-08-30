#if targetEnvironment(macCatalyst)
import SwiftUI

/// Pairing a phone to this Mac as a controller.
///
/// The Apple TV has had this since the pairing work landed; the Mac
/// shipped without it because nothing on this target ever started a
/// receiver, not because anything was missing. `ControllerLinkReceiver`
/// and the whole pairing protocol are shared code and already compile
/// here, so this screen and the one in `NativePlayerView` are the only
/// two places the Mac needed.
///
/// The lobby follows the television's rule exactly: while this screen is
/// open with the switch on, the Mac listens so a phone can pair with no
/// game running, because someone who turns the switch on and picks up
/// their phone expects pairing to happen right there rather than having
/// to learn that a game must be started first. The socket stays bounded
/// by presence, this screen or a running game, and nothing else.
///
/// Laid out as an ordinary Mac list rather than the television's focus
/// rows or the phone's cards: a labelled switch, the code at a size you
/// can read across a desk, and a destructive action behind a
/// confirmation.
struct MacPhonePairingView: View {
    @AppStorage(ControllerPairing.allowKey) private var allowPhoneController = false
    @Environment(\.scenePhase) private var scenePhase

    @State private var pairingLink: ControllerLinkReceiver?
    @State private var pairingCode: String?
    @State private var phoneConnected = false
    @State private var confirmingForget = false

    var body: some View {
        List {
            Section {
                Toggle("Use a phone as a controller", isOn: $allowPhoneController)
            } footer: {
                Text("Your iPhone becomes a controller for this Mac over Wi-Fi. Both need to be on the same network.")
            }
            .tvRow()

            if allowPhoneController {
                Section {
                    if let pairingCode {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Enter this code on the phone")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(ControllerPairing.displayCode(pairingCode))
                                .font(.system(size: 40, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 6)
                    } else {
                        LabeledContent("Status", value: phoneConnected ? "Phone connected" : "Ready to pair")
                    }
                } header: {
                    Text("Pairing")
                }
                .tvRow()

                Section {
                    Button("Forget paired phones", role: .destructive) {
                        confirmingForget = true
                    }
                } footer: {
                    Text("Each phone pairs to this Mac on its own, so forgetting them here does not affect your Apple TV.")
                }
                .tvRow()
            }
        }
        .macTransparentList()
        .navigationTitle("Phone controller")
        .animation(.easeInOut(duration: 0.25), value: pairingCode)
        .confirmationDialog(
            "Forget paired phones?", isPresented: $confirmingForget, titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                ControllerPairing.forgetAllPairings()
                restartLobby()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each phone will have to enter a new code the next time it connects.")
        }
        .onAppear { startLobby() }
        .onDisappear { stopLobby() }
        .onChange(of: allowPhoneController) { _, on in
            on ? startLobby() : stopLobby()
        }
        // A listener left running behind a hidden window is a socket
        // nobody is watching, the same reason the television binds this
        // to presence.
        .onChange(of: scenePhase) { _, phase in
            phase == .active ? startLobby() : stopLobby()
        }
    }

    /// The lobby receiver: no game name, so a phone that joins is told
    /// to wait for a game, and every in-game verb is a no-op. Seats are
    /// still claimed through the same manager the pads use, so a phone
    /// that pairs here already holds its player number when a game
    /// starts.
    private func startLobby() {
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
                Task { @MainActor in phoneConnected = joined }
            },
            onPairingCode: { code in
                Task { @MainActor in pairingCode = code }
            },
            onDrop: {}
        )
        link.start()
        pairingLink = link
    }

    private func stopLobby() {
        pairingLink?.stop()
        pairingLink = nil
        pairingCode = nil
        phoneConnected = false
    }

    private func restartLobby() {
        stopLobby()
        startLobby()
    }
}
#endif
