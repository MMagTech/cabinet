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
    let items: [ControlLayout.Item]
    /// Called with a RetroArch input id and whether it is now down.
    let send: (Int, Bool) -> Void
    /// A stick's live position. Called with its four `inputs` ids, in
    /// x-positive/x-negative/y-positive/y-negative order, and the current
    /// x/y each from -1 to 1. Defaults to a no-op for layouts with no stick.
    var sendStick: (_ ids: [Int], _ x: Double, _ y: Double) -> Void = { _, _, _ in }
    /// Relative counts from a spinner or trackball item, dx/dy. The
    /// native player wires this into the frontend's mouse channel; the
    /// webview player leaves the default no-op, so a layout carrying
    /// these kinds is inert there rather than wrong.
    var sendRelative: (_ dx: Int, _ dy: Int) -> Void = { _, _ in }
    /// Absolute aim on the picture, -1..1 each axis plus whether a
    /// finger is down. The native player wires this to the frontend's
    /// pointer channel; the webview leaves it inert.
    var sendPointer: (_ x: Double, _ y: Double, _ down: Bool) -> Void = { _, _, _ in }
    /// The layout's system, for theme colours. The webview player sets
    /// this on its pad directly; this wrapper carries it for hosts that
    /// use the SwiftUI view, so both players draw the same controls.
    var system: String = ""
    /// The visibility slider's value, applied as UIKit alpha on the view
    /// itself, exactly as the webview player's overlay does (`pad.alpha`).
    /// Never apply SwiftUI `.opacity()` to this view instead: on iOS 26 a
    /// partially transparent representable overlaying a Metal view gets
    /// flattened into the composited layer and stops receiving touches,
    /// which killed every landscape control in the native player while
    /// portrait, whose pad overlays nothing, kept working. UIKit alpha
    /// only stops touch delivery below 0.01, and the slider floors at 25%.
    var opacity: Double = 1

    func makeUIView(context: Context) -> ControlPadView {
        let view = ControlPadView(
            items: items, send: send, sendStick: sendStick,
            sendRelative: sendRelative, sendPointer: sendPointer)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: ControlPadView, context: Context) {
        view.items = items
        view.system = system
        view.theme = ControlTheme.current
        view.alpha = opacity
    }
}

final class ControlPadView: UIView {
    var items: [ControlLayout.Item] {
        didSet { setNeedsDisplay() }
    }
    /// The layout's system, which decides what colours the controls take:
    /// a Neo Geo panel and a Game Boy do not look alike.
    var system: String = "" {
        didSet { if system != oldValue { setNeedsDisplay() } }
    }
    var theme: ControlTheme = .system {
        didSet { if theme != oldValue { setNeedsDisplay() } }
    }

    private let send: (Int, Bool) -> Void
    private let sendStick: (_ ids: [Int], _ x: Double, _ y: Double) -> Void
    private let sendRelative: (_ dx: Int, _ dy: Int) -> Void
    private let sendPointer: (_ x: Double, _ y: Double, _ down: Bool) -> Void
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let detent = UIImpactFeedbackGenerator(style: .light)

    // Spinner state: one touch owns it, angle deltas accumulate into
    // counts with the fraction carried so slow precise spins are not
    // truncated away, and the visual angle drives the tick marks.
    private var spinnerTouch: UITouch?
    private var spinnerLastAngle: Double?
    private var spinnerRemainder = 0.0
    private var spinnerDetentAccum = 0.0
    private var spinnerVisual = 0.0

    // Trackball state: pan deltas stream as counts; on release the last
    // velocity decays through a display link, the coast a real ball's
    // mass gives it, until it falls below a count per frame.
    private var trackballTouch: UITouch?
    private var trackballLast: (point: CGPoint, time: TimeInterval)?
    private var trackballVelocity = CGVector.zero
    private var trackballRemainder = (x: 0.0, y: 0.0)
    private var momentum: CADisplayLink?

    // Wheel: a horizontal drag turns it, and the turn's CHANGE is what
    // reaches the game, because MAME's steering ports are positional and
    // the core integrates the relative counts back into a position. Same
    // path the spinner proved, different shape under the thumb.
    private var wheelTouch: UITouch?
    private var wheelLastX: CGFloat?
    private var wheelRemainder = 0.0
    private var wheelAngle = 0.0

    // Gun: one touch aims and fires, straight onto the picture.
    private var gunTouch: UITouch?

    /// Inputs currently held down, across all touches.
    private var pressed: Set<Int> = []
    /// What each live touch is contributing. A d-pad touch owns several.
    private var touchInputs: [UITouch: Set<Int>] = [:]
    /// The one touch currently dragging the stick, if any: only one stick
    /// ever appears in a layout, so only one touch can own it.
    private var stickTouch: UITouch?
    /// The stick's current position, -1 to 1 on each axis, for drawing the
    /// knob and for zeroing on release.
    private var stickPosition: CGPoint = .zero

    init(
        items: [ControlLayout.Item], send: @escaping (Int, Bool) -> Void,
        sendStick: @escaping (_ ids: [Int], _ x: Double, _ y: Double) -> Void = { _, _, _ in },
        sendRelative: @escaping (_ dx: Int, _ dy: Int) -> Void = { _, _ in },
        sendPointer: @escaping (_ x: Double, _ y: Double, _ down: Bool) -> Void = { _, _, _ in }
    ) {
        self.items = items
        self.send = send
        self.sendStick = sendStick
        self.sendRelative = sendRelative
        self.sendPointer = sendPointer
        super.init(frame: .zero)
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Redraw whenever the view is resized. Without this the controls keep
    /// the geometry they were first laid out with, so a rotation moves the
    /// view but not the controls inside it.
    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    /// Touches land here only inside a control's extended frame. Everything
    /// else passes through to the webview underneath, which matters in
    /// landscape where this view overlays the whole screen: taps on the game
    /// canvas still wake the overlay and reach EmulatorJS's menu button.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        items.contains { $0.extended.resolved(in: bounds.size).contains(point) }
    }

    // MARK: Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            if stickTouch == nil, let stick = stickItem(at: point) {
                stickTouch = touch
                updateStick(stick, at: point)
                continue
            }
            if spinnerTouch == nil, item(of: .spinner, at: point) != nil {
                spinnerTouch = touch
                spinnerLastAngle = nil
                continue
            }
            if wheelTouch == nil, item(of: .wheel, at: point) != nil {
                wheelTouch = touch
                wheelLastX = point.x
                continue
            }
            if gunTouch == nil, let gun = item(of: .gun, at: point) {
                gunTouch = touch
                updateGun(gun, at: point, down: true)
                continue
            }
            if trackballTouch == nil, item(of: .trackball, at: point) != nil {
                // A finger on the ball stops the coast, exactly like a
                // hand on a real one.
                momentum?.invalidate(); momentum = nil
                trackballTouch = touch
                trackballLast = (point, touch.timestamp)
                trackballVelocity = .zero
                continue
            }
            touchInputs[touch] = inputs(at: point)
        }
        reconcile()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == stickTouch, let stick = items.first(where: { $0.kind == .stick }) {
                updateStick(stick, at: touch.location(in: self))
                continue
            }
            if touch == spinnerTouch, let item = items.first(where: { $0.kind == .spinner }) {
                updateSpinner(item, at: touch.location(in: self))
                continue
            }
            if touch == wheelTouch, let item = items.first(where: { $0.kind == .wheel }) {
                updateWheel(item, at: touch.location(in: self))
                continue
            }
            if touch == gunTouch, let gun = items.first(where: { $0.kind == .gun }) {
                updateGun(gun, at: touch.location(in: self), down: true)
                continue
            }
            if touch == trackballTouch, let item = items.first(where: { $0.kind == .trackball }) {
                updateTrackball(item, touch: touch)
                continue
            }
            if touchInputs[touch] != nil {
                touchInputs[touch] = inputs(at: touch.location(in: self))
            }
        }
        reconcile()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == stickTouch {
                stickTouch = nil
                stickPosition = .zero
                if let stick = items.first(where: { $0.kind == .stick }), let ids = stick.inputs, ids.count == 4 {
                    sendStick(ids, 0, 0)
                }
                setNeedsDisplay()
                continue
            }
            if touch == spinnerTouch {
                spinnerTouch = nil
                spinnerLastAngle = nil
                spinnerDetentAccum = 0
                continue
            }
            if touch == wheelTouch {
                wheelTouch = nil
                wheelLastX = nil
                // The wheel self-centres, as a sprung cabinet wheel does.
                if let item = items.first(where: { $0.kind == .wheel }) {
                    let counts = -wheelAngle * ((item.sensitivity ?? 500) / 100)
                    let whole = counts.rounded(.towardZero)
                    if whole != 0 { sendRelative(Int(whole), 0) }
                    wheelAngle = 0
                    wheelRemainder = 0
                    setNeedsDisplay(item.frame.resolved(in: bounds.size).insetBy(dx: -8, dy: -8))
                }
                continue
            }
            if touch == gunTouch {
                gunTouch = nil
                if let gun = items.first(where: { $0.kind == .gun }) {
                    // Released: aim holds, trigger lifts.
                    let frame = gun.frame.resolved(in: bounds.size)
                    _ = frame
                    sendPointer(0, 0, false)
                }
                continue
            }
            if touch == trackballTouch {
                trackballTouch = nil
                trackballLast = nil
                startTrackballMomentum()
                continue
            }
            touchInputs[touch] = nil
        }
        reconcile()
    }

    /// The stick item whose extended frame contains this point, if any.
    private func stickItem(at point: CGPoint) -> ControlLayout.Item? {
        items.first { $0.kind == .stick && $0.extended.resolved(in: bounds.size).contains(point) }
    }

    private func item(of kind: ControlLayout.Item.Kind, at point: CGPoint) -> ControlLayout.Item? {
        items.first { $0.kind == kind && $0.extended.resolved(in: bounds.size).contains(point) }
    }

    /// The lab's proven spinner mechanism, in the pad's own idiom: thumb
    /// angle about the item's centre, lift jumps rejected, fractions
    /// carried, a detent tick every few degrees for the bearing feel.
    private func updateSpinner(_ item: ControlLayout.Item, at point: CGPoint) {
        let frame = item.frame.resolved(in: bounds.size)
        let angle = Double(atan2(point.y - frame.midY, point.x - frame.midX))
        defer { spinnerLastAngle = angle }
        guard let last = spinnerLastAngle else { return }
        var d = angle - last
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        guard abs(d) < 1.0 else { return }
        spinnerVisual += d
        let perTurn = item.sensitivity ?? 768
        let counts = (d / (2 * .pi)) * perTurn + spinnerRemainder
        let whole = counts.rounded(.towardZero)
        spinnerRemainder = counts - whole
        if whole != 0 { sendRelative(Int(whole), 0) }
        spinnerDetentAccum += abs(d)
        if spinnerDetentAccum >= 12.0 * .pi / 180 {
            spinnerDetentAccum = 0
            detent.impactOccurred(intensity: 0.6)
        }
        setNeedsDisplay(frame.insetBy(dx: -8, dy: -8))
    }

    private func updateTrackball(_ item: ControlLayout.Item, touch: UITouch) {
        let point = touch.location(in: self)
        guard let last = trackballLast else {
            trackballLast = (point, touch.timestamp)
            return
        }
        let dt = max(touch.timestamp - last.time, 0.001)
        let scale = (item.sensitivity ?? 300) / 100
        let dx = Double(point.x - last.point.x) * scale + trackballRemainder.x
        let dy = Double(point.y - last.point.y) * scale + trackballRemainder.y
        let wx = dx.rounded(.towardZero), wy = dy.rounded(.towardZero)
        trackballRemainder = (dx - wx, dy - wy)
        if wx != 0 || wy != 0 { sendRelative(Int(wx), Int(wy)) }
        trackballVelocity = CGVector(
            dx: (point.x - last.point.x) / dt, dy: (point.y - last.point.y) / dt)
        trackballLast = (point, touch.timestamp)
    }

    /// A wheel's travel is horizontal: how far the thumb has dragged
    /// from where it grabbed, capped at full lock, with the CHANGE in
    /// that angle sent as counts. Holding the wheel turned therefore
    /// holds a steering position rather than spinning forever.
    private func updateWheel(_ item: ControlLayout.Item, at point: CGPoint) {
        let frame = item.frame.resolved(in: bounds.size)
        guard let lastX = wheelLastX else { wheelLastX = point.x; return }
        let travel = frame.width / 2
        let previous = wheelAngle
        wheelAngle = max(-1, min(1, wheelAngle + Double((point.x - lastX) / travel)))
        wheelLastX = point.x
        let scale = (item.sensitivity ?? 500) / 100
        let counts = (wheelAngle - previous) * scale + wheelRemainder
        let whole = counts.rounded(.towardZero)
        wheelRemainder = counts - whole
        if whole != 0 { sendRelative(Int(whole), 0) }
        setNeedsDisplay(frame.insetBy(dx: -8, dy: -8))
    }

    /// Aim is where the finger is, expressed against the gun item's own
    /// frame, which the layout places over the picture.
    private func updateGun(_ gun: ControlLayout.Item, at point: CGPoint, down: Bool) {
        let frame = gun.frame.resolved(in: bounds.size)
        guard frame.width > 0, frame.height > 0 else { return }
        let x = Double((point.x - frame.midX) / (frame.width / 2))
        let y = Double((point.y - frame.midY) / (frame.height / 2))
        sendPointer(max(-1, min(1, x)), max(-1, min(1, y)), down)
    }

    private func startTrackballMomentum() {
        let speed = (trackballVelocity.dx * trackballVelocity.dx
                     + trackballVelocity.dy * trackballVelocity.dy).squareRoot()
        guard speed > 40 else { return }
        momentum?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(momentumTick))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func momentumTick(_ link: CADisplayLink) {
        guard let item = items.first(where: { $0.kind == .trackball }) else {
            link.invalidate(); momentum = nil; return
        }
        let dt = link.duration
        let scale = (item.sensitivity ?? 300) / 100
        let dx = Double(trackballVelocity.dx) * dt * scale + trackballRemainder.x
        let dy = Double(trackballVelocity.dy) * dt * scale + trackballRemainder.y
        let wx = dx.rounded(.towardZero), wy = dy.rounded(.towardZero)
        trackballRemainder = (dx - wx, dy - wy)
        if wx != 0 || wy != 0 { sendRelative(Int(wx), Int(wy)) }
        // The coast: a shade over a second from a hard flick to rest,
        // tuned against the feel of a real ball's bearing, or as close
        // as arithmetic gets before thumbs weigh in.
        trackballVelocity.dx *= 0.94
        trackballVelocity.dy *= 0.94
        let speed = (trackballVelocity.dx * trackballVelocity.dx
                     + trackballVelocity.dy * trackballVelocity.dy).squareRoot()
        if speed < 8 { link.invalidate(); momentum = nil }
    }

    /// A stick's position is its offset from its own frame's center, capped
    /// to the frame's half-extent so it cannot report beyond fully deflected,
    /// then sent through as a magnitude the way EmulatorJS's own stick does.
    private func updateStick(_ stick: ControlLayout.Item, at point: CGPoint) {
        guard let ids = stick.inputs, ids.count == 4 else { return }
        let frame = stick.frame.resolved(in: bounds.size)
        let dx = (point.x - frame.midX) / (frame.width / 2)
        let dy = (point.y - frame.midY) / (frame.height / 2)
        let magnitude = min(1, (dx * dx + dy * dy).squareRoot())
        let angle = atan2(dy, dx)
        let x = magnitude == 0 ? 0 : cos(angle) * magnitude
        let y = magnitude == 0 ? 0 : sin(angle) * magnitude
        // touchesMoved arrives per display refresh, up to 120Hz, and a
        // thumb held "still" jitters by fractions of a point. Below 1.5%
        // of full deflection the game cannot tell the difference, so skip
        // the JS call and the redraw both, or a held stick streams
        // identical messages into the webview for as long as it is held.
        let previous = stickPosition
        guard abs(x - previous.x) > 0.015 || abs(y - previous.y) > 0.015 else { return }
        stickPosition = CGPoint(x: x, y: y)
        // No sign flip: EmulatorJS's own y-positive slot is confirmed to
        // mean "down", not "up", by N64's C-buttons, whose analog indices
        // follow the same four slot pattern and are independently confirmed
        // against source (C-Down sits in the y-positive slot). That matches
        // screen y, which already grows downward, so the raw touch delta is
        // exactly the value to send, no conversion needed.
        sendStick(ids, Double(x), Double(y))
        // Only the stick's own frame needs repainting, not every control
        // on the pad: in landscape this view spans the whole screen, and
        // a full-view redraw per touch sample repainted all of it.
        setNeedsDisplay(stick.frame.resolved(in: bounds.size).insetBy(dx: -20, dy: -20))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    /// The inputs a touch at this point should be holding.
    ///
    /// A d-pad's four bands are meant to overlap: a corner touch reporting
    /// both an up and a right is the diagonal, not a mistake. Two separate
    /// buttons overlapping is a different situation, an accident of two
    /// generous extended frames sitting close together, and reporting both
    /// is exactly the double press this was built to prevent. So buttons
    /// and pills resolve to whichever one's center is nearest, one winner
    /// only, while the d-pad keeps its own overlap untouched.
    private func inputs(at point: CGPoint) -> Set<Int> {
        var held: Set<Int> = []
        var nearestButton: (id: Int, distance: CGFloat)?

        for item in items {
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
            case .pedal:
                // A pedal presses like a button; MAME's analog pedal
                // ports accept a full press, which is how anyone plays
                // a driving game on anything but a real cabinet.
                guard let id = item.input else { break }
                held.insert(id)
            case .button, .pill:
                guard let id = item.input else { break }
                let frame = item.frame.resolved(in: bounds.size)
                let dx = point.x - frame.midX
                let dy = point.y - frame.midY
                let distance = dx * dx + dy * dy
                if nearestButton == nil || distance < nearestButton!.distance {
                    nearestButton = (id, distance)
                }
            case .stick, .spinner, .trackball, .wheel, .gun:
                // Handled separately: each is claimed by a touch in
                // touchesBegan and tracked through its own update path,
                // not through this digital held-id path.
                break
            }
        }
        if let nearestButton {
            held.insert(nearestButton.id)
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
        for item in items {
            let frame = item.frame.resolved(in: bounds.size)
            let tint = theme.tint(system: system, input: item.input)
            switch item.kind {
            case .dpad:
                let dpadTint = theme.tint(system: system, input: item.inputs?.first)
                drawDpad(in: frame, inputs: item.inputs ?? [], label: item.label, tint: dpadTint)
            case .button:
                drawRoundButton(
                    in: frame, label: item.label, tint: tint,
                    active: item.input.map(pressed.contains) ?? false
                )
            case .pill:
                drawPill(
                    in: frame, label: item.label, tint: tint,
                    active: item.input.map(pressed.contains) ?? false
                )
            case .stick:
                drawStick(in: frame)
            case .spinner:
                drawSpinner(in: frame)
            case .trackball:
                drawTrackball(in: frame)
            case .wheel:
                drawWheel(in: frame)
            case .pedal:
                drawPedal(
                    in: frame, label: item.label, tint: tint,
                    active: item.input.map(pressed.contains) ?? false)
            case .gun:
                // Nothing drawn: the picture is the sight, and a frame
                // over the game would only hide it.
                break
            }
        }
    }

    /// A ring with tick marks that rotate with the accumulated spin, so
    /// the control visibly turns under the thumb the way the knob did.
    private func drawSpinner(in frame: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(frame.width, frame.height) / 2 - 4
        let center = CGPoint(x: frame.midX, y: frame.midY)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(7)
        ctx.strokeEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        ctx.setLineWidth(2.5)
        for i in 0..<12 {
            let a = spinnerVisual + Double(i) * .pi / 6
            let inner = CGPoint(
                x: center.x + cos(a) * (radius - 12), y: center.y + sin(a) * (radius - 12))
            let outer = CGPoint(
                x: center.x + cos(a) * (radius - 3), y: center.y + sin(a) * (radius - 3))
            ctx.move(to: inner); ctx.addLine(to: outer)
        }
        ctx.strokePath()
    }

    /// A tall pedal with its label laid out to fit the width it has:
    /// the pill renderer centres a fixed-size string and let "Brake"
    /// truncate to an initial.
    private func drawPedal(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let path = UIBezierPath(roundedRect: frame, cornerRadius: min(frame.width, frame.height) * 0.28)
        let fill = tint ?? UIColor.white
        ctx.setFillColor(fill.withAlphaComponent(active ? 0.55 : 0.22).cgColor)
        ctx.addPath(path.cgPath); ctx.fillPath()
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(path.cgPath); ctx.strokePath()
        guard let label, !label.isEmpty else { return }
        var size: CGFloat = min(frame.height * 0.26, 20)
        var attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
        ]
        // Shrink until it fits rather than truncating, which is the whole
        // point of drawing this separately from a pill.
        var text = label.size(withAttributes: attrs)
        while text.width > frame.width - 8 && size > 8 {
            size -= 1
            attrs[.font] = UIFont.systemFont(ofSize: size, weight: .semibold)
            text = label.size(withAttributes: attrs)
        }
        label.draw(at: CGPoint(
            x: frame.midX - text.width / 2, y: frame.midY - text.height / 2), withAttributes: attrs)
    }

    /// An arc that tilts with the wheel's travel, so the control shows
    /// its own steering angle the way a wheel's spokes do.
    private func drawWheel(in frame: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(frame.width, frame.height * 2) / 2 - 6
        let center = CGPoint(x: frame.midX, y: frame.maxY)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(9)
        ctx.addArc(center: center, radius: radius,
                   startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        ctx.strokePath()
        // The grip mark, showing how far the wheel is turned.
        let a = .pi * 1.5 + wheelAngle * (.pi * 0.35)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(5)
        ctx.move(to: CGPoint(x: center.x + cos(a) * (radius - 14),
                             y: center.y + sin(a) * (radius - 14)))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * (radius + 5),
                                y: center.y + sin(a) * (radius + 5)))
        ctx.strokePath()
    }

    /// A filled ball in a shallow well. Deliberately plain: the picture
    /// is the game's, this only has to read as "roll me".
    private func drawTrackball(in frame: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(frame.width, frame.height) / 2 - 4
        let center = CGPoint(x: frame.midX, y: frame.midY)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(4)
        ctx.strokeEllipse(in: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2))
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.14).cgColor)
        let ball = radius * 0.72
        ctx.fillEllipse(in: CGRect(
            x: center.x - ball, y: center.y - ball, width: ball * 2, height: ball * 2))
    }

    private func drawStick(in frame: CGRect) {
        let radius = min(frame.width, frame.height) / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let active = stickTouch != nil
        let colors = style(active: active)

        let base = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        colors.fill.setFill()
        base.fill()
        colors.stroke.setStroke()
        base.lineWidth = 1.5
        base.stroke()

        let knobRadius = radius * 0.42
        let knobCenter = CGPoint(
            x: center.x + stickPosition.x * (radius - knobRadius),
            y: center.y + stickPosition.y * (radius - knobRadius)
        )
        let knob = UIBezierPath(arcCenter: knobCenter, radius: knobRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor.white.withAlphaComponent(active ? 0.85 : 0.55).setFill()
        knob.fill()
    }

    /// Labels sit on colour rather than on the game, so they need to be
    /// solid: the translucent white that reads well over dark art disappears
    /// against a yellow button.
    private func labelColor(tint: UIColor?) -> UIColor {
        tint == nil ? UIColor.white.withAlphaComponent(0.75) : UIColor.white
    }

    /// Every control gets a contrasting outline regardless of theme, or it
    /// vanishes over bright or dark game content. A tinted control keeps the
    /// white outline for exactly that reason and carries its colour in the
    /// fill, which is what a glance reads anyway.
    private func style(active: Bool, tint: UIColor? = nil) -> (fill: UIColor, stroke: UIColor) {
        guard let tint else {
            return (
                fill: UIColor.white.withAlphaComponent(active ? 0.45 : 0.14),
                stroke: UIColor.white.withAlphaComponent(0.55)
            )
        }
        // Colour needs far more presence than white to survive: the whole
        // pad carries the visibility slider's alpha on top of this, so a
        // third of a colour under a further 70 percent reads as mud rather
        // than as red. Nearly solid when held, so a press is unmistakable in
        // peripheral vision.
        return (
            fill: tint.withAlphaComponent(active ? 0.95 : 0.62),
            stroke: UIColor.white.withAlphaComponent(0.55)
        )
    }

    private func drawDpad(in frame: CGRect, inputs: [Int], label: String? = nil, tint: UIColor? = nil) {
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
        let colors = style(active: anyActive, tint: tint)
        colors.fill.setFill()
        cross.fill()
        colors.stroke.setStroke()
        cross.lineWidth = 1.5
        cross.stroke()

        // A cluster distinct enough from the real d-pad to name (N64's C
        // buttons, tinted yellow) gets its label centred over the cross,
        // rather than one arm, since no single direction owns it.
        if let label {
            drawLabel(
                label, in: frame, fontSize: armThickness * 0.55,
                color: labelColor(tint: tint)
            )
        }

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

    private func drawRoundButton(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        let diameter = min(frame.width, frame.height)
        let circleRect = CGRect(
            x: frame.midX - diameter / 2,
            y: frame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        let circle = UIBezierPath(ovalIn: circleRect)
        let colors = style(active: active, tint: tint)
        colors.fill.setFill()
        circle.fill()
        colors.stroke.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()

        drawLabel(label, in: circleRect, fontSize: diameter * 0.34, color: labelColor(tint: tint))
    }

    private func drawPill(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        let pill = UIBezierPath(roundedRect: frame, cornerRadius: frame.height / 2)
        let colors = style(active: active, tint: tint)
        colors.fill.setFill()
        pill.fill()
        colors.stroke.setStroke()
        pill.lineWidth = 1.5
        pill.stroke()

        drawLabel(label, in: frame, fontSize: frame.height * 0.42, color: labelColor(tint: tint))
    }

    private func drawLabel(
        _ label: String?, in rect: CGRect, fontSize: CGFloat, color: UIColor
    ) {
        guard let label else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }
}
