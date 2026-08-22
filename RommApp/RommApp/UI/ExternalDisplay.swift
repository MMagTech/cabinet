#if os(iOS)
import SwiftUI
import UIKit

/// Gameplay on a television, with the phone as the control panel.
///
/// An iPhone can drive a second screen with content of its own rather than
/// a mirror of the phone, over AirPlay to any AirPlay 2 television or over
/// a wired adapter on the models that support DisplayPort. This is the
/// small version of that idea, deliberately: the game picture moves to the
/// television and nothing else does. There is no ten-foot interface here,
/// no focus navigation, no browsing on the big screen. The phone stays the
/// whole app and simply stops drawing the picture.
///
/// Everything here is iOS only. tvOS is already a television.
///
/// Note this is not the same feature as the phone-as-controller work in
/// `Lab/`: there a phone reaches across the network into an Apple TV, which
/// is why it needs pairing and authentication. Here one device does
/// everything and there is nothing to admit, which is what makes this the
/// cheaper half of the same idea.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    /// True while a television is attached and showing our own window.
    /// Set by the scene delegate below rather than polled, so it cannot
    /// disagree with what is actually on screen.
    @Published private(set) var isConnected = false

    /// The renderer for the game currently running, or nil when nothing
    /// is playing. The player sets this; the external window observes it.
    ///
    /// One renderer drives one MTKView at a time, never two: a second
    /// view would run a second draw loop and advance the core twice per
    /// frame, so the player stops drawing locally whenever this window
    /// takes over. See `NativePlayerView`.
    @Published var renderer: NativePlayerRenderer?

    /// Whether the picture should currently be on the television, which
    /// is both conditions at once and is the single thing the player
    /// branches on.
    var showsGameExternally: Bool { isConnected && renderer != nil }

    fileprivate func sceneConnected() { isConnected = true }

    fileprivate func sceneDisconnected() {
        isConnected = false
    }
}

/// What the television actually shows: the game, or a quiet placeholder
/// while nothing is running. Deliberately the same black as the player's
/// own background, so plugging in during a menu does not flash white.
private struct ExternalGameScreen: View {
    @ObservedObject private var external = ExternalDisplay.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer = external.renderer {
                MetalGameView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 64))
                        .foregroundStyle(.tertiary)
                    Text("Start a game on your iPhone")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The window on the television. Created by UIKit when a second screen
/// arrives, whether that is AirPlay or a cable, and torn down when it
/// leaves. `AppDelegate.application(_:configurationForConnecting:options:)`
/// routes external scene sessions here.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: ExternalGameScreen())
        window.isHidden = false
        self.window = window
        MainActor.assumeIsolated { ExternalDisplay.shared.sceneConnected() }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        // Clearing this is what hands the picture back to the phone. The
        // player observes it and starts drawing locally again on the next
        // layout pass, so unplugging mid-game continues the game rather
        // than stranding it on a screen that is gone.
        MainActor.assumeIsolated { ExternalDisplay.shared.sceneDisconnected() }
    }
}
#endif
