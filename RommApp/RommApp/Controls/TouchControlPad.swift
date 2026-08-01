import SwiftUI
import UIKit

/// The native touch controls, drawn as vectors over the webview.
///
/// The touch model follows DeltaCore's approach (the approach, not the code;
/// Delta is AGPL and this project is MIT):
///
/// - Hit testing runs against each control's extended frame, which is larger
///   than what is drawn. Fingers are imprecise and games are frantic; the
///   forgiving target is what makes touch controls stop feeling like touch
///   controls.
/// - The d-pad is four overlapping rectangles, not a polar hit test. Up spans
///   the whole top band, left the whole left band, and so on, so the corners
///   belong to two directions at once and diagonals fall out of the overlap.
/// - A d-pad touch reports continuously while it moves. Sliding from up to
///   up-left is a stream of input changes, never a release and a new press.
/// - Haptics fire on every input change.
struct TouchControlPad: UIViewRepresentable {
    let layout: ControlLayout
    /// Called with a RetroArch input id and whether it is now down.
    let send: (Int, Bool) -> Void

    func makeUIView(context: Context) -> ControlPadView {
        let view = ControlPadView(layout: layout, send: send)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: ControlPadView, context: Context) {}
}

final class ControlPadView: UIView {
    private let layout: ControlLayout
    private let send: (Int, Bool) -> Void
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// Inputs currently held down, across all touches.
    private var pressed: Set<Int> = []
    /// What each live touch is contributing. A d-pad touch owns several.
    private var touchInputs: [UITouch: Set<Int>] = [:]

    init(layout: ControlLayout, send: @escaping (Int, Bool) -> Void) {
        self.layout = layout
        self.send = send
        super.init(frame: .zero)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchInputs[touch] = inputs(at: touch.location(in: self))
        }
        reconcile()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touchInputs[touch] != nil {
            touchInputs[touch] = inputs(at: touch.location(in: self))
        }
        reconcile()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchInputs[touch] = nil
        }
        reconcile()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// The inputs a touch at this point should be holding.
    private func inputs(at point: CGPoint) -> Set<Int> {
        var held: Set<Int> = []

        for item in layout.items {
            let extended = item.extended.resolved(in: bounds.size)
            guard extended.contains(point) else { continue }

            switch item.kind {
            case .dpad:
                guard let ids = item.inputs, ids.count == 4 else { break }
                let unit = CGPoint(
                    x: (point.x - extended.minX) / extended.width,
                    y: (point.y - extended.minY) / extended.height
                )

                if item.fourWay == true {
                    // Four way sticks report one direction only, whichever
                    // axis the thumb is furthest along. Pac-Man corners
                    // depend on never seeing a diagonal.
                    let dx = unit.x - 0.5
                    let dy = unit.y - 0.5
                    guard abs(dx) > 0.10 || abs(dy) > 0.10 else { break }
                    if abs(dx) > abs(dy) {
                        held.insert(dx < 0 ? ids[2] : ids[3])
                    } else {
                        held.insert(dy < 0 ? ids[0] : ids[1])
                    }
                } else {
                    // Four overlapping bands inside the extended frame. A
                    // point in a corner sits in two bands, which is exactly
                    // the diagonal.
                    if unit.y < 0.40 { held.insert(ids[0]) }   // up
                    if unit.y > 0.60 { held.insert(ids[1]) }   // down
                    if unit.x < 0.40 { held.insert(ids[2]) }   // left
                    if unit.x > 0.60 { held.insert(ids[3]) }   // right
                }
            case .button, .pill:
                if let id = item.input { held.insert(id) }
            }
        }
        return held
    }

    /// Diffs the union of all touches against what the emulator believes,
    /// sends only the changes, and pulses haptics when anything changed.
    private func reconcile() {
        let now = touchInputs.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let downs = now.subtracting(pressed)
        let ups = pressed.subtracting(now)
        guard !downs.isEmpty || !ups.isEmpty else { return }

        for id in downs { send(id, true) }
        for id in ups { send(id, false) }
        pressed = now

        haptic.impactOccurred(intensity: downs.isEmpty ? 0.6 : 1.0)
        setNeedsDisplay()
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        for item in layout.items {
            let frame = item.frame.resolved(in: bounds.size)
            switch item.kind {
            case .dpad:
                drawDpad(in: frame, inputs: item.inputs ?? [])
            case .button:
                drawRoundButton(in: frame, label: item.label, active: item.input.map(pressed.contains) ?? false)
            case .pill:
                drawPill(in: frame, label: item.label, active: item.input.map(pressed.contains) ?? false)
            }
        }
    }

    /// Every control gets a contrasting outline regardless of theme, or it
    /// vanishes over bright or dark game content.
    private func style(active: Bool) -> (fill: UIColor, stroke: UIColor) {
        (
            fill: UIColor.white.withAlphaComponent(active ? 0.45 : 0.14),
            stroke: UIColor.white.withAlphaComponent(0.55)
        )
    }

    private func drawDpad(in frame: CGRect, inputs: [Int]) {
        let armThickness = frame.width * 0.34
        let cross = UIBezierPath()

        // One cross path: horizontal bar plus vertical bar.
        let horizontal = CGRect(
            x: frame.minX,
            y: frame.midY - armThickness / 2,
            width: frame.width,
            height: armThickness
        )
        let vertical = CGRect(
            x: frame.midX - armThickness / 2,
            y: frame.minY,
            width: armThickness,
            height: frame.height
        )
        cross.append(UIBezierPath(roundedRect: horizontal, cornerRadius: 6))
        cross.append(UIBezierPath(roundedRect: vertical, cornerRadius: 6))

        let anyActive = inputs.contains(where: pressed.contains)
        let colors = style(active: anyActive)
        colors.fill.setFill()
        cross.fill()
        colors.stroke.setStroke()
        cross.lineWidth = 1.5
        cross.stroke()

        // A subtle nub on the pressed direction, so the pad reads as alive.
        guard inputs.count == 4 else { return }
        let nubs: [(Int, CGPoint)] = [
            (inputs[0], CGPoint(x: frame.midX, y: frame.minY + armThickness / 2)),
            (inputs[1], CGPoint(x: frame.midX, y: frame.maxY - armThickness / 2)),
            (inputs[2], CGPoint(x: frame.minX + armThickness / 2, y: frame.midY)),
            (inputs[3], CGPoint(x: frame.maxX - armThickness / 2, y: frame.midY)),
        ]
        for (id, center) in nubs where pressed.contains(id) {
            let nub = UIBezierPath(
                arcCenter: center, radius: armThickness * 0.22,
                startAngle: 0, endAngle: .pi * 2, clockwise: true
            )
            UIColor.white.withAlphaComponent(0.8).setFill()
            nub.fill()
        }
    }

    private func drawRoundButton(in frame: CGRect, label: String?, active: Bool) {
        let diameter = min(frame.width, frame.height)
        let circleRect = CGRect(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let circle = UIBezierPath(ovalIn: circleRect)
        let colors = style(active: active)
        colors.fill.setFill()
        circle.fill()
        colors.stroke.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        drawLabel(label, in: circleRect, fontSize: diameter * 0.34)
    }

    private func drawPill(in frame: CGRect, label: String?, active: Bool) {
        let pill = UIBezierPath(roundedRect: frame, cornerRadius: frame.height / 2)
        let colors = style(active: active)
        colors.fill.setFill()
        pill.fill()
        colors.stroke.setStroke()
        pill.lineWidth = 1.5
        pill.stroke()

        drawLabel(label, in: frame, fontSize: frame.height * 0.42)
    }

    private func drawLabel(_ label: String?, in rect: CGRect, fontSize: CGFloat) {
        guard let label else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.75),
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
