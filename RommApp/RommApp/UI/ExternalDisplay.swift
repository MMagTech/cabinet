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

    /// Whether the game is paused, so the television can say so. The
    /// pause menu itself deliberately stays on the phone: a console puts
    /// it on the screen because the controller has none, and this
    /// controller has one you are already looking at. But a frozen frame
    /// with no explanation reads as a crash to anyone else in the room.
    @Published var isPaused = false

    /// Whether the picture should currently be on the television, which
    /// is both conditions at once and is the single thing the player
    /// branches on.
    var showsGameExternally: Bool { isConnected && renderer != nil }

    /// The television's size in points, published so a wrong one is
    /// visible in the app rather than something to squint at across a
    /// room. A phone-shaped size here means the external window did not
    /// take the screen's geometry.
    @Published private(set) var screenSize: CGSize = .zero

    fileprivate func sceneConnected(size: CGSize) {
        screenSize = size
        isConnected = true
    }

    fileprivate func sceneDisconnected() {
        isConnected = false
        screenSize = .zero
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
                if external.isPaused {
                    // The draw loop keeps presenting the last frame while
                    // paused, so the game stays visibly there, waiting,
                    // rather than being covered up.
                    //
                    // Built from the same vocabulary the Apple TV app uses
                    // for its own overlays, glass on tvOS 26 and a
                    // material below it, rather than plain white text over
                    // the picture, which reads as a debug label from across
                    // a room. Restrained on purpose: at ten feet the job
                    // is to answer "did it crash" at a glance, not to
                    // announce itself.
                    Color.black.opacity(0.35).ignoresSafeArea()
                    Label("Paused", systemImage: "pause.fill")
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 26)
                        .background {
                            if #available(iOS 26.0, *) {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(.regular, in: Capsule())
                            } else {
                                Capsule().fill(.regularMaterial)
                            }
                        }
                }
            } else {
                // Sized for the room, not the hand: this renders on
                // the television, where title3 and caption read as
                // specks from a couch. Same rounded vocabulary as the
                // Paused pill above, which already learned this.
                VStack(spacing: 28) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 140))
                        .foregroundStyle(.tertiary)
                    Text("Start a game on your iPhone")
                        .font(.system(size: 46, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("\(Int(external.screenSize.width)) x \(Int(external.screenSize.height))")
                        .font(.system(size: 22, design: .rounded))
                        .foregroundStyle(.tertiary)
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
        // Sized from the scene's own coordinate space rather than left to
        // adopt a default. A window that comes up phone-shaped on a
        // television is the failure this guards against: the renderer
        // aspect-fits the picture into whatever drawable size it is given,
        // so a phone-shaped view produces a phone-shaped picture on a
        // 16:9 panel no matter how large the panel is.
        window.frame = windowScene.coordinateSpace.bounds
        let host = UIHostingController(rootView: ExternalGameScreen())
        // The television is not a phone: no notch, no home indicator, and
        // any inset here would letterbox the picture a second time on top
        // of the aspect fit the renderer already does.
        host.view.frame = window.bounds
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        MainActor.assumeIsolated {
            ExternalDisplay.shared.sceneConnected(size: window.bounds.size)
        }
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
