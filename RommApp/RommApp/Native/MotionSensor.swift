#if os(iOS)
import CoreMotion
import UIKit

/// The phone standing in for the sensors that lived inside a few Game Boy
/// Advance cartridges.
///
/// WarioWare: Twisted! had a gyroscope in the cart and is played by
/// physically turning the thing in your hands. Yoshi's Universal
/// Gravitation and Koro Koro Puzzle had a tilt sensor. mGBA is the only
/// core in this app that asks for any of it, and it asks through
/// libretro's sensor interface, which `LibretroFrontend` now answers.
///
/// iOS only, and that is a decision rather than an omission. Apple
/// removed the motion sensors from the Siri Remote in the 2021
/// redesign, so on tvOS this would work or not depending on which
/// controller happened to be in someone's hand, which is the kind of
/// conditional feature that only generates confused bug reports. A
/// phone, meanwhile, is better hardware for this than the cartridge
/// ever was.
@MainActor
final class MotionSensor {
    static let shared = MotionSensor()

    private let manager = CMMotionManager()
    private var running = false

    /// 60Hz, matching the frame rate the games themselves run at. mGBA
    /// asks for a rate and this deliberately ignores it, the same thing
    /// RetroArch does: CoreMotion delivers at the interval it was
    /// configured with, not one negotiated per read.
    private static let updateInterval = 1.0 / 60.0

    private init() {}

    /// Driven entirely by what the core asks for, through
    /// `LibretroFrontend.setMotionSensingHandler`. Nothing starts the
    /// gyroscope speculatively: thirteen of the fourteen cores never ask,
    /// and neither do the overwhelming majority of GBA games, so a game
    /// that does not need this pays nothing for it.
    func setEnabled(accelerometer: Bool, gyroscope: Bool) {
        let wanted = accelerometer || gyroscope
        guard wanted != running else { return }
        running = wanted
        wanted ? start() : stop()
    }

    private func start() {
        // deviceMotion rather than the raw accelerometer and gyroscope,
        // because it separates gravity from the acceleration of the
        // phone being moved around. A cartridge tilt sensor measures
        // which way is down, so gravity is the signal here and the rest
        // is noise from someone shifting on the sofa.
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = Self.updateInterval
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.deliver(motion)
        }
    }

    private func stop() {
        manager.stopDeviceMotionUpdates()
        // Zeroed on the way out so a game that re-enables the sensor
        // mid-session does not read whatever angle the phone was at when
        // it was last switched off.
        LibretroFrontend.shared.setAccelerationX(0, y: 0, z: 0)
        LibretroFrontend.shared.setRotationRateZ(0)
    }

    private func deliver(_ motion: CMDeviceMotion) {
        // CoreMotion reports in the device's own frame, where +y points
        // out of the top of the phone as held upright. The player is
        // holding a game that is locked to the orientation it started
        // in (see OrientationLock), so in landscape the device's x and y
        // are ninety degrees off what the game means by tilting left or
        // down, and unrotated values would send Yoshi sideways.
        //
        // Gravity, not userAcceleration: a tilt sensor answers "which
        // way is down", and the sign matches libretro's convention of
        // reporting acceleration in g.
        let gravity = motion.gravity
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait

        let x: Double
        let y: Double
        switch orientation {
        case .landscapeLeft:
            x = -gravity.y
            y = gravity.x
        case .landscapeRight:
            x = gravity.y
            y = -gravity.x
        case .portraitUpsideDown:
            x = -gravity.x
            y = -gravity.y
        default:
            x = gravity.x
            y = gravity.y
        }

        LibretroFrontend.shared.setAccelerationX(Float(x), y: Float(y), z: Float(gravity.z))

        // Rotation about the axis coming out of the screen, which is the
        // one motion a cartridge gyroscope ever measured: the plane of
        // the cartridge is the plane of the screen. That axis is the
        // same physical spin whichever way up the phone is held, so
        // unlike gravity above it needs no remapping.
        //
        // rotationRate is radians per second, already what mGBA expects
        // before its own scaling.
        LibretroFrontend.shared.setRotationRateZ(Float(motion.rotationRate.z))
    }
}
#endif
