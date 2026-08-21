#if os(iOS)
import SwiftUI

/// The on-screen spinner: a dial you roll with a thumb, for the arcade
/// games whose cabinet control was a spinner, dial or paddle knob.
///
/// The mechanism is the one the control lab proved out on hardware:
/// thumb angle around the control's centre, per-move deltas with lift
/// jumps rejected, and a light haptic every few degrees of travel, which
/// is what gives glass the notched, massy feel of a real spinner
/// bearing. Output is relative counts into the frontend's mouse channel,
/// the same units a real spinner's quadrature encoder produces; each
/// game's own sensitivity is applied by the core on top, from the
/// driver's per-game data, so one control serves Tempest and Arkanoid
/// without per-game tuning here.
struct TouchSpinner: View {
    /// Relative counts to feed onward. Sign follows the device the games
    /// were dumped against: clockwise is positive.
    let onSpin: (Int) -> Void
    let opacity: Double

    @State private var lastAngle: Double?
    @State private var visual = 0.0
    @State private var detentAccum = 0.0
    /// Fractional counts carried between move events. A slow precise
    /// spin arrives as many sub-count moves; truncating each one throws
    /// most of the motion away and the game barely turns.
    @State private var countRemainder = 0.0
    private let detent = UIImpactFeedbackGenerator(style: .light)
    /// Full thumb revolution in counts. 512 matches the class of encoder
    /// these cabinets used and lands Cameltry and Arkanoid in a sane
    /// range at their drivers' default sensitivities; revisit with
    /// thumbs on glass rather than by arithmetic.
    private static let countsPerTurn = 512.0
    private static let detentStep = 12.0 * .pi / 180

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 10)
                ForEach(0..<12, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.4))
                        .frame(width: 2.5, height: 8)
                        .offset(y: -(min(geo.size.width, geo.size.height) / 2 - 9))
                        .rotationEffect(.radians(visual + Double(i) * .pi / 6))
                }
                Circle().fill(Color.white.opacity(0.12))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let a = atan2(Double(v.location.y - c.y), Double(v.location.x - c.x))
                        defer { lastAngle = a }
                        guard let last = lastAngle else { return }
                        var d = a - last
                        while d > .pi { d -= 2 * .pi }
                        while d < -.pi { d += 2 * .pi }
                        // A jump this big is a lifted and replaced thumb,
                        // not a spin; feeding it would fling the game.
                        guard abs(d) < 1.0 else { return }
                        visual += d
                        let counts = (d / (2 * .pi)) * Self.countsPerTurn + countRemainder
                        let whole = counts.rounded(.towardZero)
                        countRemainder = counts - whole
                        if whole != 0 { onSpin(Int(whole)) }
                        detentAccum += abs(d)
                        if detentAccum >= Self.detentStep {
                            detentAccum = 0
                            detent.impactOccurred(intensity: 0.6)
                        }
                    }
                    .onEnded { _ in lastAngle = nil; detentAccum = 0 }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .opacity(opacity)
    }
}
#endif
