import UIKit

/// What colour each control is drawn in.
///
/// Arcade muscle memory is colour based: people remember the red button, not
/// button one, and a Neo Geo player's hand goes to red for A without
/// consulting anything. Colours are computed from the layout's system and the
/// input id rather than stored in the layout files, so they apply to arcade
/// layouts built at runtime as readily as to bundled console ones, and
/// nothing needs redrawing when a profile resolves differently.
///
/// Only action buttons take colour. Coin, Start, Menu, the shoulders and the
/// stick stay neutral: they are not what a hand reaches for mid game, and
/// colouring everything would leave nothing to distinguish.
enum ControlTheme: String, CaseIterable {
    /// The colours the real hardware had, where the hardware had opinions.
    case system
    /// Every control the same neutral white, for anyone who finds colour
    /// noisy over game art.
    case monochrome

    static let key = "com.mmagtech.RommApp.controlTheme"

    static var current: ControlTheme {
        UserDefaults.standard.string(forKey: key).flatMap(ControlTheme.init) ?? .system
    }

    var label: String {
        switch self {
        case .system: return "System colours"
        case .monochrome: return "Monochrome"
        }
    }

    var detail: String {
        switch self {
        case .system: return "Neo Geo red, yellow, green, blue and friends, matching the hardware each game came from."
        case .monochrome: return "Every control the same neutral white."
        }
    }

    /// The tint for one control, or nil when it should stay neutral.
    ///
    /// Hues are chosen to survive the low fill opacity these controls are
    /// drawn at: saturated and mid bright, since a pale colour at 30 percent
    /// over bright game art is indistinguishable from white.
    func tint(system: String, input: Int?) -> UIColor? {
        guard self == .system, let input else { return nil }

        if system.hasPrefix("arcade:") {
            return Self.arcadeTint(system: system, input: input)
        }
        switch system {
        // Super Famicom's four colours, which the American SNES dropped and
        // most people picture anyway.
        case "default":
            switch input {
            case RetroPad.a: return .neoRed
            case RetroPad.b: return .neoYellow
            case RetroPad.x: return .neoBlue
            case RetroPad.y: return .neoGreen
            default: return nil
            }
        // The DMG's two buttons were the same magenta, so they stay the same
        // here: telling them apart was never the colour's job.
        case "gb":
            switch input {
            case RetroPad.a, RetroPad.b: return .dmgMagenta
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Arcade colouring follows the panel the game shipped on.
    ///
    /// Up to four buttons is the Neo Geo layout, A B C D in red, yellow,
    /// green, blue, which is both authentic and the strongest colour memory
    /// in the whole library. Five and six button games are Capcom style
    /// panels where the row matters more than any individual colour: punches
    /// warm across the top, kicks cool across the bottom, deepening left to
    /// right so light, medium and heavy read as a progression. That is a
    /// convention rather than a replica; cabinets varied, hands did not.
    ///
    /// The count comes from the layout name rather than the profile name,
    /// because the two disagree the moment someone overrides a game's
    /// controls, and it is the count that decides which ids are on the
    /// panel at all.
    private static func arcadeTint(system: String, input: Int) -> UIColor? {
        let count = system.split(separator: ":").last.flatMap { Int($0) } ?? 6
        if count >= 5 {
            switch input {
            case RetroPad.y: return .punchLight
            case RetroPad.x: return .punchMedium
            case RetroPad.l: return .punchHeavy
            case RetroPad.b: return .kickLight
            case RetroPad.a: return .kickMedium
            case RetroPad.r: return .kickHeavy
            default: return nil
            }
        }
        switch input {
        case RetroPad.b: return .neoRed        // arcade 1, Neo Geo A
        case RetroPad.a: return .neoYellow     // arcade 2, Neo Geo B
        case RetroPad.y: return .neoGreen      // arcade 3, Neo Geo C
        case RetroPad.x: return .neoBlue       // arcade 4, Neo Geo D
        default: return nil
        }
    }
}

private extension UIColor {
    static let neoRed = UIColor(red: 0.93, green: 0.24, blue: 0.24, alpha: 1)
    static let neoYellow = UIColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 1)
    static let neoGreen = UIColor(red: 0.30, green: 0.82, blue: 0.42, alpha: 1)
    static let neoBlue = UIColor(red: 0.29, green: 0.56, blue: 0.98, alpha: 1)
    static let dmgMagenta = UIColor(red: 0.80, green: 0.31, blue: 0.55, alpha: 1)

    static let punchLight = UIColor(red: 0.98, green: 0.76, blue: 0.30, alpha: 1)
    static let punchMedium = UIColor(red: 0.96, green: 0.52, blue: 0.22, alpha: 1)
    static let punchHeavy = UIColor(red: 0.91, green: 0.27, blue: 0.25, alpha: 1)
    static let kickLight = UIColor(red: 0.38, green: 0.82, blue: 0.78, alpha: 1)
    static let kickMedium = UIColor(red: 0.31, green: 0.60, blue: 0.96, alpha: 1)
    static let kickHeavy = UIColor(red: 0.53, green: 0.42, blue: 0.94, alpha: 1)
}
