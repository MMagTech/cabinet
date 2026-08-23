import Foundation

/// Pairing a phone to a television, so the phone may drive a game.
///
/// The design is docs/scope-phone-controller-pairing.md: pair once with a
/// short code shown on the television, store a shared secret on both
/// sides, and from then on every packet carries proof of that secret.
/// This file is the shared half, compiled into both apps. The television
/// and the phone each keep their own UI and wiring.
enum ControllerPairing {
    /// The television's master switch, "Allow a phone as a controller".
    /// Off by default, and while it is off the television never binds a
    /// socket: to the network the feature does not exist. Only the tvOS
    /// app reads this; it lives here because the rest of pairing does.
    static let allowKey = "com.mmagtech.RommAppTV.allowPhoneController"
}
