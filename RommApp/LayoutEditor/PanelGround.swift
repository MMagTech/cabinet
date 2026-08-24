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
/// The answer is structure, not hue. Every system gets the SAME
/// deliberate surface, so nothing can look forgotten because nothing
/// is ever missing. An earlier version leaned each ground toward its
/// machine's colour; Marcus cut that, and rightly: a controller is
/// one object and should not redecorate itself per console. Colour
/// belongs to the buttons, where ControlTheme already gives it real
/// hardware meaning.
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

struct PanelGround: View {
    let system: String
    let style: PanelGroundStyle
    /// Light that moves with the phone. Nil draws the ground flat lit,
    /// which is also what someone with Reduce Motion on will see.
    var light: PanelLight? = nil
    private var base: Color { Color(white: 0.11) }
    /// The panel's own light, the same on every machine. A per-system
    /// tint lived here and Marcus cut it: a controller is one object
    /// and should not redecorate itself per console. Colour lives in
    /// the BUTTONS, where ControlTheme already gives it real hardware
    /// meaning rather than a hue invented for a background.
    private var lit: Color { Color.white.opacity(0.10) }

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
