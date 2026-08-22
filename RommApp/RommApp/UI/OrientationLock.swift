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

    /// Landscape regardless of how the phone is held right now: the
    /// phone-as-controller panel is a cabinet control panel, and a
    /// cabinet has one orientation. Accepting the offer in portrait
    /// rotates the panel in rather than drawing a portrait one.
    static func lockToLandscape() {
        mask = .landscape
        apply()
    }

    /// The pistol grip: the phone stands upright when it is the gun, so
    /// air mode's interface is portrait and locks there.
    static func lockToPortrait() {
        mask = .portrait
        apply()
    }

    /// One exact landscape orientation, not the family. The family lock
    /// keeps the 180 flip, which is right for a phone lying in front of
    /// someone, and wrong for one being rolled as a steering wheel:
    /// tilt steering sweeps through exactly the angle iOS reads as
    /// "turned around", the UI flipped mid-corner, and the Gas pedal
    /// changed sides under Marcus's thumb. Called once the orientation
    /// has settled, it pins whichever landscape the panel opened in.
    static func pinCurrentLandscape() {
        guard let orientation = activeScene?.interfaceOrientation,
              orientation.isLandscape else { return }
        mask = orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
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
        // Both halves of this live in GameControllerManager now, so tvOS
        // can run them too: this file is not in that target, which is
        // exactly why rumble never worked there.
        GameControllerManager.installRumbleRouting()
        // Cartridge motion sensors, iOS only. Installed here rather than
        // alongside rumble in GameControllerManager precisely because
        // this file is not in the tvOS target: a Siri Remote has had no
        // motion sensors since the 2021 redesign, so there is nothing
        // for this to route to there.
        //
        // Only wires the route. Nothing starts until a core actually
        // enables a sensor, which today means mGBA and a handful of
        // Game Boy Advance carts.
        LibretroFrontend.setMotionSensingHandler { accelerometer, gyroscope in
            MainActor.assumeIsolated {
                MotionSensor.shared.setEnabled(
                    accelerometer: accelerometer, gyroscope: gyroscope
                )
            }
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
