import SwiftUI
import UIKit

/// Pins the app to one orientation while a game is on screen.
///
/// Rotation mid game was never safe to honour: resizing the webview makes
/// WebKit relay out everything over a wasm core that already fills most of
/// the process's memory allowance, and when the watchdog objects it kills
/// the process and the game with it. Recovery exists and works, but even a
/// graceful recovery interrupts a live run, and an interruption during a
/// boss is a lost run. So the player does not rotate at all: a game is
/// played in the orientation it was started in, and the rest of the app
/// rotates freely.
///
/// Locking to a family rather than one exact orientation keeps the 180
/// degree flip working in landscape, which changes nothing about the
/// layout and is how a phone gets its charging cable out of the way.
enum OrientationLock {
    /// What the whole app currently allows. UIKit asks the delegate on
    /// every rotation, so changing this and prodding the scene is enough.
    static var mask: UIInterfaceOrientationMask = .all

    static func lockToCurrent() {
        let orientation = activeScene?.interfaceOrientation ?? .portrait
        mask = orientation.isLandscape ? .landscape : .portrait
        apply()
    }

    static func unlock() {
        mask = .all
        apply()
    }

    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static func apply() {
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

/// Exists solely to answer UIKit's orientation question with the mask
/// above. SwiftUI has no view level equivalent of this delegate call.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        QuickAction.register()
        // @AppStorage only writes its default into UserDefaults the first
        // time the view holding it is instantiated, but rumbleSetState
        // reads this key directly from Objective-C++ before Settings has
        // necessarily ever been opened. Without this, `boolForKey:` on a
        // key that has never been set returns NO, Foundation's own
        // default, not this app's, so rumble is silently off until
        // someone happens to visit Settings once. Register it here
        // instead, before anything can read it.
        UserDefaults.standard.register(defaults: ["com.mmagtech.RommApp.rumbleEnabled": true])
        LibretroFrontend.setRumbleHandler { port, strong, strength in
            GameControllerManager.shared.fireRumble(port: port, strong: strong, strength: strength)
        }
        return true
    }

    /// Names the scene delegate that receives quick action taps; SwiftUI
    /// keeps driving the scene's content exactly as before, this only adds
    /// the delegate alongside it.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role
        )
        config.delegateClass = QuickActionSceneDelegate.self
        return config
    }
}
