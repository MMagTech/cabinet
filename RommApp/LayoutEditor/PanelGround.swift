import SwiftUI
import CoreMotion
import UIKit

/// Candidate grounds for the controller-only panel, for looking at
/// rather than shipping. Lives in the editor on purpose: whichever one
/// survives real hands moves into the app, and the rest are deleted.
///
/// The problem being solved: a companion panel has no picture behind
/// it, so today it is flat black, and flat black is what a screen
/// shows when nothing has been drawn. Marcus asked for something more
/// deliberate, then made the point that decides the shape of it, that
/// a system with no colour of its own would look like the theme had
/// failed rather than like a choice.
///
/// So the two jobs are separated. STRUCTURE says the panel was
/// designed, and every system gets the same structure. HUE says which
/// machine you are holding, and a system without one simply stays
/// neutral, which now reads as a neutral controller rather than a
/// broken one.
enum PanelGroundStyle: String, CaseIterable, Identifiable {
    /// What ships today, kept so the others can be judged against it.
    case flat
    /// Two soft pools where thumbs actually rest, dark between them.
    case pools
    /// Deeper under the service pills, lifting toward the hands.
    case horizon
    /// Even ground, corners drawn down.
    case vignette

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .pools: return "Pools"
        case .horizon: return "Horizon"
        case .vignette: return "Vignette"
        }
    }
}

/// The hue a machine actually has, at panel strength.
///
/// Taken from the thing in your hands rather than the box on the
/// shelf, because the box is what tends to be black: the SNES pad's
/// lavender, the Mega Drive's red, PlayStation's grey-blue. Where even
/// the controller is plain, the next honest source is the logo or the
/// screen, which is why Vectrex is phosphor green and Virtual Boy is
/// red. A machine with no colour anywhere gets none, and lands on the
/// neutral charcoal every other panel is already built from.
enum PanelTint {
    static func color(forSystem system: String) -> Color {
        // Hue and saturation only; the ground decides brightness.
        switch system.hasPrefix("arcade") ? "arcade" : system {
        case "snes", "nds": return Color(hue: 0.72, saturation: 0.55, brightness: 1)
        case "gba": return Color(hue: 0.70, saturation: 0.50, brightness: 1)
        case "genesis", "genesis6", "sms", "atari7800": return Color(hue: 0.99, saturation: 0.70, brightness: 1)
        case "nes": return Color(hue: 0.02, saturation: 0.45, brightness: 1)
        case "n64": return Color(hue: 0.60, saturation: 0.55, brightness: 1)
        case "psx", "psp": return Color(hue: 0.58, saturation: 0.30, brightness: 1)
        case "gb": return Color(hue: 0.24, saturation: 0.45, brightness: 1)
        case "gamegear": return Color(hue: 0.55, saturation: 0.45, brightness: 1)
        case "dreamcast": return Color(hue: 0.07, saturation: 0.65, brightness: 1)
        case "pce", "pce6": return Color(hue: 0.09, saturation: 0.55, brightness: 1)
        case "ngpc": return Color(hue: 0.62, saturation: 0.50, brightness: 1)
        case "virtualboy": return Color(hue: 0.00, saturation: 0.80, brightness: 1)
        case "vectrex": return Color(hue: 0.33, saturation: 0.60, brightness: 1)
        case "atari2600": return Color(hue: 0.06, saturation: 0.60, brightness: 1)
        case "lynx": return Color(hue: 0.15, saturation: 0.55, brightness: 1)
        case "arcade": return Color(hue: 0.95, saturation: 0.50, brightness: 1)
        // 3DO, Saturn and anything unlisted: black box, black pad, no
        // colour to borrow. Neutral is the honest answer, and the
        // shared structure is what keeps it from reading as missing.
        default: return .white
        }
    }
}

struct PanelGround: View {
    let system: String
    let style: PanelGroundStyle
    /// Light that moves with the phone. Nil draws the ground flat lit,
    /// which is also what someone with Reduce Motion on will see.
    var light: PanelLight? = nil
    /// How far the machine's own colour is allowed to lean the ground.
    /// Deliberately small: at panel strength these are near-black, and
    /// the difference between two systems should be felt before it is
    /// noticed.
    var tintStrength: Double = 0.5

    // Deliberately overshot for judging. Marcus could not tell the
    // first pass from flat black, which is the same mistake the warp
    // haptics made: too polite to perceive. Easier to pull a visible
    // thing back than to argue about an invisible one.
    private var base: Color { Color(white: 0.11) }
    private var lit: Color {
        PanelTint.color(forSystem: system)
            .opacity(0.42 * tintStrength)
    }

    /// How far the sheen slides, as a fraction of the panel. Small on
    /// purpose: enough that turning the phone is felt, not enough to
    /// pull an eye off the game on the television.
    private var travel: CGFloat { 0.38 }

    var body: some View {
        ZStack {
            if style == .flat {
                Color.black
            } else {
                base
                if let light {
                    sheen(light.offset)
                }
                switch style {
                case .pools:
                    // Brightest where a thumb sits, which is also the
                    // only part of the panel anybody looks at.
                    GeometryReader { geo in
                        ZStack {
                            pool(at: CGPoint(x: geo.size.width * 0.18, y: geo.size.height * 0.62),
                                 radius: geo.size.height * 0.85)
                            pool(at: CGPoint(x: geo.size.width * 0.82, y: geo.size.height * 0.62),
                                 radius: geo.size.height * 0.85)
                        }
                    }
                case .horizon:
                    LinearGradient(
                        colors: [Color.black.opacity(0.55), .clear, lit],
                        startPoint: .top, endPoint: .bottom)
                case .vignette:
                    RadialGradient(
                        colors: [lit, .clear, Color.black.opacity(0.5)],
                        center: .center, startRadius: 0, endRadius: 620)
                case .flat:
                    EmptyView()
                }
            }
        }
        .ignoresSafeArea()
    }

    /// The moving highlight itself: a broad soft pool of the panel's
    /// own light, sliding opposite the tilt so the source appears to
    /// stay put in the room.
    private func sheen(_ offset: CGSize) -> some View {
        GeometryReader { geo in
            RadialGradient(
                colors: [Color.white.opacity(0.20), Color.white.opacity(0.05), .clear],
                center: .center, startRadius: 0, endRadius: geo.size.width * 0.55)
                .frame(width: geo.size.width * 1.1, height: geo.size.width * 1.1)
                .position(
                    x: geo.size.width * (0.5 - offset.width * travel),
                    y: geo.size.height * (0.5 - offset.height * travel))
                .allowsHitTesting(false)
        }
    }

    private func pool(at point: CGPoint, radius: CGFloat) -> some View {
        RadialGradient(colors: [lit, .clear], center: .center, startRadius: 0, endRadius: radius)
            .frame(width: radius * 2, height: radius * 2)
            .position(point)
    }
}

/// Where the light is, from how the phone is being held.
///
/// A real object tells you it is real by the way light moves across it
/// when you move. Gravity-referenced rather than integrated from
/// rotation rate, so the light stays fixed in the room and the panel
/// turns under it: the same lesson the tilt wheel and the light gun
/// both taught, that anything integrated drifts and anything absolute
/// does not.
@MainActor
final class PanelLight: ObservableObject {
    /// Where the highlight sits, -1 to 1 in each axis, 0 being flat on
    /// its back under a light directly above.
    @Published private(set) var offset = CGSize.zero

    private let motion = CMMotionManager()
    /// Honoured, not optional. Someone who has asked the system to
    /// stop things moving has asked for this too.
    private var allowed: Bool { !UIAccessibility.isReduceMotionEnabled }

    func start() {
        guard allowed, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self, let g = m?.gravity else { return }
            // Held in landscape, so the phone's x axis runs across the
            // room and z is how far it is tipped back. Smoothed hard:
            // this is a sheen, not a spirit level, and a highlight
            // that chases every tremor reads as noise.
            let targetX = min(max(-g.y * 1.6, -1), 1)
            let targetY = min(max((g.z + 0.5) * 1.6, -1), 1)
            let a = 0.14
            self.offset = CGSize(
                width: self.offset.width + a * (targetX - self.offset.width),
                height: self.offset.height + a * (targetY - self.offset.height))
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}
