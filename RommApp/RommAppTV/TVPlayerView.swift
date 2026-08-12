#if os(tvOS)
import SwiftUI
import MetalKit
import GameController

/// tvOS's real play screen, the sibling of iOS's `NativePlayerView`.
/// Deliberately minimal for now: no pause menu, no touch overlay (nothing
/// to touch on a TV), no PS1 memory card sync. A controller is required,
/// there is no touch fallback the way iOS has one.
///
/// `NativeLauncher.prepare` has already activated the core and loaded the
/// game before this appears, same contract as iOS's screen. Reuses
/// `NativePlayerRenderer` exactly as-is, the shared render pipeline both
/// platforms have carried since the tvOS PS1 go/no-go spike.
struct TVPlayerView: View {
    let rom: Rom
    let core: NativeCore
    var initialState: Data?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var renderer = NativePlayerRenderer()
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var previousSend: ((Int, Int, Bool) -> Void)?
    @State private var previousStick: ((Int, Float, Float) -> Void)?
    @State private var previousMenu: (() -> Void)?

    var body: some View {
        TVGameSurface(renderer: renderer)
            .ignoresSafeArea()
            .onAppear {
                renderer.pendingState = initialState
                // Without this nothing is ever discovered and no handlers
                // are installed, so the pad reaches the core not at all,
                // while still driving menus perfectly (that is the focus
                // engine, which needs no app code). Exactly the shape of
                // "works in the menus, dead in game" seen on real hardware
                // 2026-08-11. Idempotent, guarded by its own `started`
                // flag, so calling it on every launch is free.
                controllers.start()
                // Claim Menu for the duration of the game only. Outside a
                // game the system needs it for back navigation; see
                // GameControllerManager.capturesMenuButton.
                controllers.capturesMenuButton = true
                previousSend = controllers.send
                previousStick = controllers.sendStick
                previousMenu = controllers.onMenu
                controllers.send = { player, id, down in
                    renderer.setButton(id, down: down, port: player)
                }
                controllers.sendStick = { player, x, y in
                    renderer.setStick(x: Double(x), y: Double(y), port: player)
                }
                controllers.onMenu = { dismiss() }
            }
            .onDisappear {
                controllers.capturesMenuButton = false
                controllers.send = previousSend
                controllers.sendStick = previousStick
                controllers.onMenu = previousMenu
            }
    }
}

/// The Metal surface, hosted inside a `GCEventViewController` rather than a
/// plain `UIViewRepresentable`, which is the entire point of this type.
///
/// tvOS routes controller input through the UIKit focus engine by default,
/// and this app opts into that at the Info.plist level
/// (GCSupportsControllerUserInteraction) because it is exactly what Home
/// and the library want: a real pad drives focus and selection with no
/// per-screen code. In a running game it is precisely wrong. The focus
/// engine keeps consuming presses for navigation, so B reads as "go back"
/// and dismisses the player instead of reaching the core as a face button
/// (reported on real hardware 2026-08-11: "controllers work on the
/// homescreen but in game b exits the game").
///
/// `controllerUserInteractionEnabled = false` is the documented way for a
/// game to take the pad exclusively for as long as this controller is on
/// screen: the focus engine stops seeing controller events, and
/// `GameControllerManager`'s own handlers become the only consumer. It
/// reverts the moment this view goes away, so the shelves get their focus
/// navigation back without anything having to restore it by hand.
private struct TVGameSurface: UIViewControllerRepresentable {
    let renderer: NativePlayerRenderer

    func makeUIViewController(context: Context) -> GCEventViewController {
        let controller = GCEventViewController()
        controller.controllerUserInteractionEnabled = false

        let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        metalView.delegate = renderer
        metalView.preferredFramesPerSecond = 60
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.translatesAutoresizingMaskIntoConstraints = false

        controller.view.backgroundColor = .black
        controller.view.addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            metalView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            metalView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
        ])

        renderer.attach(to: metalView)
        return controller
    }

    func updateUIViewController(_ controller: GCEventViewController, context: Context) {}
}
#endif
