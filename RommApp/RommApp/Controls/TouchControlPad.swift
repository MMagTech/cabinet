import SwiftUI
import UIKit
import CoreMotion
import QuartzCore


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
    /// Off the picture: the cabinet's reload gesture.
    var sendOffscreen: (_ offscreen: Bool) -> Void = { _ in }
    /// The running game's picture shape. A 4:3 board on a widescreen
    /// phone leaves real black bars, and touching those is genuinely
    /// pointing off the screen, which is how a gun game reloads.
    var pictureAspect: Double = 0
    /// The layout's system, for theme colours. The webview player sets
    /// this on its pad directly; this wrapper carries it for hosts that
    /// use the SwiftUI view, so both players draw the same controls.
    var system: String = ""
    /// Draw controls as moulded objects rather than flat shapes: a
    /// shadow beneath, light falling from above, a specular edge.
    /// Off by default, so every existing caller, and the local player
    /// in particular, draws byte-identically to before. Only the
    /// phone-as-controller panel turns it on, where the controls ARE
    /// the screen and there is no game for them to sit politely
    /// beside.
    var material: Bool = false
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
            sendRelative: sendRelative, sendPointer: sendPointer,
            sendOffscreen: sendOffscreen)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }

    func updateUIView(_ view: ControlPadView, context: Context) {
        view.items = items
        view.pictureAspect = pictureAspect
        view.material = material
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
    var material: Bool = false { didSet { setNeedsDisplay() } }
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
    private let sendOffscreen: (_ offscreen: Bool) -> Void
    var pictureAspect: Double = 0
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private let detent = UIImpactFeedbackGenerator(style: .light)
    /// The ball's grain. Soft rather than light: this is meant to be
    /// felt as texture under a moving thumb, not heard as a click.
    private let grain = UIImpactFeedbackGenerator(style: .soft)

    /// Whether the ball's grain is allowed to fire.
    ///
    /// The same Settings toggle every other controller's rumble obeys,
    /// read here rather than threaded through as a property because
    /// this view is built by three different hosts (both players and
    /// the Layout Editor) and a new initialiser argument would have to
    /// be right in all of them to be right anywhere.
    ///
    /// Registered on first read: the Layout Editor is its own app with
    /// its own defaults domain, so the value Cabinet's launch registers
    /// does not exist over there, and an unregistered bool reads false.
    /// Without this the grain would simply never fire in the editor,
    /// which is where it gets looked at.
    private static let rumbleKey = "com.mmagtech.RommApp.rumbleEnabled"
    private static let registerRumbleDefault: Void = {
        UserDefaults.standard.register(defaults: [rumbleKey: true])
    }()
    private var rumbleAllowed: Bool {
        _ = Self.registerRumbleDefault
        return UserDefaults.standard.bool(forKey: Self.rumbleKey)
    }

    /// Which marks are under the thumb right now, so each one bumps
    /// once as it passes rather than every frame it stays in the zone.
    private var ballContact = Set<Int>()
    private var lastGrainBump: TimeInterval = 0

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
    /// The ball's actual orientation, as a 3x3 rotation, so the marks on
    /// its surface go where a rolled ball's marks would go. Rows are the
    /// rotated basis vectors; see `rollTrackball`.
    private var trackballSpin: [[Double]] = [[1,0,0],[0,1,0],[0,0,1]]
    /// Fixed marks on the unit sphere: x, y, z, then a size multiplier
    /// and a darkness multiplier. Computed once, so the ball turns and
    /// the marks stay put on it.
    ///
    /// Laid out by the Fibonacci method and then DELIBERATELY SPOILED.
    /// Even spacing is what that method is for, and even spacing is
    /// exactly wrong here: Marcus, 2026-08-25, "speckles look too
    /// perfect if that makes sense." It does. Evenly spread dots of one
    /// size read as a printed pattern, because nothing in a moulded
    /// plastic ball is regular. So each mark is pushed off its lattice
    /// point by up to most of the gap to its neighbour, and given its
    /// own size and weight, which is what turns a texture into flecks.
    ///
    /// The randomness is from a fixed seed, so the ball has ONE face
    /// that stays its face. Re-rolling per draw would make it crawl.
    private static let ballSpeckle: [[Double]] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double {                       // xorshift, deterministic
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 100_000) / 100_000
        }
        let n = 34
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y0 = 1 - (Double(i) / Double(n - 1)) * 2
            let a0 = golden * Double(i)
            // Off the lattice, by a good fraction of the spacing.
            let y = max(-0.98, min(0.98, y0 + (rnd() - 0.5) * 1.6 / Double(n)))
            let a = a0 + (rnd() - 0.5) * 1.9
            let r = max(0, 1 - y * y).squareRoot()
            // Sizes over better than a 3:1 range, and weights that let
            // some marks sit almost invisibly under the gloss.
            let size = 0.45 + rnd() * 1.25
            // Weighted toward the faint end. Dirt in a surface is
            // mostly barely-there, with the occasional bit that
            // actually caught: squaring a uniform gives that shape, so
            // most marks sit under the gloss and a few read.
            let u = rnd()
            let weight = 0.10 + u * u * 1.15
            // Shape, so no two marks are the same blob: how oblong it
            // is, which way it lies, and where its second lobe sits.
            let squash = 0.55 + rnd() * 0.85
            let lean = rnd() * Double.pi
            let lobeA = rnd() * Double.pi * 2
            let lobeR = 0.25 + rnd() * 0.75
            let lobeS = 0.30 + rnd() * 0.55
            return [cos(a) * r, y, sin(a) * r, size, weight,
                    squash, lean, lobeA, lobeR, lobeS]
        }
    }()
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

    /// A rotary stick's twist touch, tracked separately from whatever
    /// finger is pushing the stick, so a player can hold a direction and
    /// twist at the same time, which is the whole point of the control.
    private var rotaryTwistTouch: UITouch?

    /// Tilt-to-turn, for the rotary joystick cabinets. Those machines
    /// gave one hand both movement and aim while the other fired, three
    /// things at once from two hands; two thumbs cannot cover that, so
    /// the aim moves off the glass entirely and onto the phone. Tilting
    /// turns the aim at a rate, the same rate-control the wheel uses, so
    /// a small steady tilt sweeps the ring and level holds it. Both
    /// thumbs stay free for the stick and the buttons.
    private let motion = CMMotionManager()
    private var tiltActive = false
    /// Where "level" is, in screen space, captured from how the phone is
    /// actually being held rather than assumed. Cleared on an
    /// orientation change so the next sample recalibrates: the same
    /// physical hold is a different gravity vector once the screen
    /// rotates, which is what made landscape go funky.
    private var tiltNeutral: (x: Double, y: Double)?
    /// Directions the tilt is currently asserting, kept apart from touch
    /// state so a thumb on the ring and a tilted phone never fight over
    /// the same set.
    private var tiltHeld: Set<Int> = []
    private var tiltDirectionIDs: [Int]? {
        items.first { $0.kind == .rotary }?.inputs
    }

    /// Device gravity rotated into the screen's own axes, so "tilt left"
    /// means the same thing however the phone is held.
    private func screenSpaceGravity(_ g: (x: Double, y: Double)) -> (x: Double, y: Double) {
        switch window?.windowScene?.interfaceOrientation {
        case .landscapeLeft:      return (x: -g.y, y: g.x)
        case .landscapeRight:     return (x: g.y, y: -g.x)
        case .portraitUpsideDown: return (x: -g.x, y: g.y)
        default:                  return (x: g.x, y: -g.y)
        }
    }

    private func reconcileTilt() {
        touchInputs[tiltKey] = tiltHeld
        reconcile()
    }
    /// A stand-in touch object so tilt can live in the same held-inputs
    /// map every real touch uses, and reconcile stays the one place
    /// presses are diffed and sent.
    private let tiltKey = UITouch()

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
        sendPointer: @escaping (_ x: Double, _ y: Double, _ down: Bool) -> Void = { _, _, _ in },
        sendOffscreen: @escaping (_ offscreen: Bool) -> Void = { _ in }
    ) {
        self.items = items
        self.send = send
        self.sendStick = sendStick
        self.sendRelative = sendRelative
        self.sendPointer = sendPointer
        self.sendOffscreen = sendOffscreen
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
        updateTiltTracking()
        // A rotation lands here, and the hold that was level before is a
        // different vector now, so level is measured again.
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            recalibrateTilt()
        }
    }

    private var lastLaidOutSize: CGSize = .zero

    /// Forgets where level was, so the next sample captures it fresh.
    /// Also clears any direction the old calibration was asserting, or a
    /// stale press would stick through the rotation.
    func recalibrateTilt() {
        tiltNeutral = nil
        if !tiltHeld.isEmpty {
            tiltHeld.removeAll()
            reconcileTilt()
        }
    }

    /// Runs only while a layout actually asks for tilt, so no other game
    /// pays for the sensor.
    private func updateTiltTracking() {
        let wants = items.contains { $0.kind == .rotary }
        if wants, !tiltActive, motion.isDeviceMotionAvailable {
            tiltActive = true
            motion.deviceMotionUpdateInterval = 1.0 / 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] m, _ in
                guard let self, let m else { return }
                // Gravity is absolute, so this never drifts: level is
                // always level however long the game runs. Movement is
                // eight coarse directions, so the tilt resolves to
                // digital presses with a dead zone that keeps a resting
                // hand still and a hysteresis gap so a direction does not
                // chatter at its own threshold.
                let g = (x: m.gravity.x, y: m.gravity.y)
                DispatchQueue.main.async {
                    guard let ids = self.tiltDirectionIDs, ids.count == 4 else { return }
                    // Gravity arrives in the device's own axes, which
                    // rotate away from the screen's the moment the phone
                    // does. Rotating it into screen space first is what
                    // makes one set of thresholds work in every
                    // orientation.
                    let screen = self.screenSpaceGravity(g)
                    guard let neutral = self.tiltNeutral else {
                        self.tiltNeutral = screen
                        return
                    }
                    let dx = screen.x - neutral.x
                    let dy = screen.y - neutral.y
                    let on = 0.20, off = 0.13
                    func decide(_ v: Double, _ negID: Int, _ posID: Int) {
                        if v < -on { self.tiltHeld.insert(negID); self.tiltHeld.remove(posID) }
                        else if v > on { self.tiltHeld.insert(posID); self.tiltHeld.remove(negID) }
                        else if abs(v) < off { self.tiltHeld.remove(negID); self.tiltHeld.remove(posID) }
                    }
                    decide(dx, ids[2], ids[3])   // left, right
                    decide(dy, ids[0], ids[1])   // up, down
                    self.reconcileTilt()
                }
            }
        } else if !wants, tiltActive {
            tiltActive = false
            motion.stopDeviceMotionUpdates()
        }
    }

    deinit { motion.stopDeviceMotionUpdates() }

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
            // A rotary stick: the collar twists, the middle pushes. Which
            // one this touch owns depends on how far out it landed.
            if rotaryTwistTouch == nil, item(of: .rotary, at: point) != nil {
                rotaryTwistTouch = touch
                spinnerLastAngle = nil
                continue
            }
            if wheelTouch == nil, item(of: .wheel, at: point) != nil {
                wheelTouch = touch
                wheelLastX = point.x
                continue
            }
            // A gun cabinet's surface is the whole picture, which means it
            // sits under every other control on the panel. Claimed first,
            // it took the first finger down wherever it landed, so Coin,
            // Start, Menu and the grenade button only worked as a second
            // finger while another was already held: on Op Wolf they read
            // as dead. A touch that lands on a real control belongs to
            // that control; only the bare picture is the gun.
            if gunTouch == nil, let gun = item(of: .gun, at: point),
               !touchesAControl(at: point) {
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
                if rumbleAllowed { grain.prepare() }
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
            if touch == rotaryTwistTouch, let rot = items.first(where: { $0.kind == .rotary }) {
                updateSpinner(rot, at: touch.location(in: self))
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
            if touch == rotaryTwistTouch {
                rotaryTwistTouch = nil
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
                // Released: the trigger lifts and the gun comes back on
                // screen, so a reload does not latch.
                sendPointer(0, 0, false)
                sendOffscreen(false)
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

    /// Whether this point is on a drawn control rather than on the bare
    /// picture behind them. The gun's surface spans everything, so it has
    /// to ask before claiming a touch.
    private func touchesAControl(at point: CGPoint) -> Bool {
        items.contains { item in
            guard item.kind != .gun else { return false }
            return item.extended.resolved(in: bounds.size).contains(point)
        }
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
        // The ball turns by what the finger actually moved, not by the
        // scaled count sent to the game: those are the same gesture but
        // the second carries a sensitivity multiplier, and a ball that
        // spins faster than the hand looks wrong.
        let f = item.frame.resolved(in: bounds.size)
        rollTrackball(dx: Double(point.x - last.point.x),
                      dy: Double(point.y - last.point.y),
                      radius: Double(min(f.width, f.height) / 2) * 0.95)
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
    /// Where the game's picture actually sits inside the gun's surface,
    /// aspect-fitted the way the renderer draws it. Everything outside
    /// is the letterbox, which is off-screen in the cabinet's sense.
    private func pictureRect(in surface: CGRect) -> CGRect {
        guard pictureAspect > 0, surface.width > 0, surface.height > 0 else { return surface }
        let surfaceAspect = surface.width / surface.height
        if surfaceAspect > pictureAspect {
            let w = surface.height * pictureAspect
            return CGRect(x: surface.midX - w / 2, y: surface.minY, width: w, height: surface.height)
        }
        let h = surface.width / pictureAspect
        return CGRect(x: surface.minX, y: surface.midY - h / 2, width: surface.width, height: h)
    }

    private func updateGun(_ gun: ControlLayout.Item, at point: CGPoint, down: Bool) {
        let picture = pictureRect(in: gun.frame.resolved(in: bounds.size))
        guard picture.width > 0, picture.height > 0 else { return }
        // Beside the picture is past the edge of the cabinet's screen,
        // which is the reload gesture rather than a missed shot.
        let offscreen = !picture.contains(point)
        sendOffscreen(offscreen)
        guard !offscreen else {
            sendPointer(0, 0, down)
            return
        }
        let x = Double((point.x - picture.midX) / (picture.width / 2))
        let y = Double((point.y - picture.midY) / (picture.height / 2))
        sendPointer(max(-1, min(1, x)), max(-1, min(1, y)), down)
    }

    /// Turns the ball by a surface displacement, in points.
    ///
    /// A ball dragged under a finger turns about the axis perpendicular
    /// to the drag, by the distance travelled over its radius, which is
    /// the whole of the physics and is why this needs no tuning
    /// constant. The axis works out as (-dy, dx, 0) normalised: drag
    /// right and the ball rolls about its vertical-screen axis, drag
    /// down and it rolls about the horizontal one.
    private func rollTrackball(dx: Double, dy: Double, radius: Double) {
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist > 0.0001, radius > 0 else { return }
        let theta = dist / radius
        let ax = -dy / dist, ay = dx / dist, az = 0.0
        let c = cos(theta), s1 = sin(theta), t = 1 - c
        // Rodrigues, written out rather than pulled in from anywhere.
        let r = [
            [t*ax*ax + c,     t*ax*ay - s1*az, t*ax*az + s1*ay],
            [t*ax*ay + s1*az, t*ay*ay + c,     t*ay*az - s1*ax],
            [t*ax*az - s1*ay, t*ay*az + s1*ax, t*az*az + c],
        ]
        var out = [[0.0,0,0],[0.0,0,0],[0.0,0,0]]
        for i in 0..<3 {
            for j in 0..<3 {
                out[i][j] = r[i][0]*trackballSpin[0][j]
                          + r[i][1]*trackballSpin[1][j]
                          + r[i][2]*trackballSpin[2][j]
            }
        }
        trackballSpin = out
        grainBump(speed: theta)
    }

    /// A real trackball is not smooth to push. It is a heavy plastic
    /// ball with a lifetime of grime worn into it, riding on rollers,
    /// and what a hand feels is that texture passing underneath.
    ///
    /// So the grain is not a metronome. The marks already drawn on the
    /// ball ARE the imperfections: each one is a fixed point on the
    /// sphere, and a bump fires when the ball's turning carries it
    /// under the thumb, at a strength taken from how heavy that
    /// particular mark is. The same flick therefore feels the same way
    /// twice, and a different one does not, because the ball has one
    /// face and it keeps it.
    ///
    /// It fires from the coast as well as the drag, since the ball is
    /// still turning after the thumb lifts.
    private func grainBump(speed theta: Double) {
        guard rumbleAllowed else {
            if !ballContact.isEmpty { ballContact.removeAll() }
            return
        }
        let now = CACurrentMediaTime()
        for (i, p) in Self.ballSpeckle.enumerated() {
            let z = trackballSpin[2][0]*p[0] + trackballSpin[2][1]*p[1] + trackballSpin[2][2]*p[2]
            if z > 0.97 {                                   // under the thumb
                guard ballContact.insert(i).inserted else { continue }
                // The haptic engine saturates if fed faster than this,
                // and a saturated engine feels like a buzz rather than
                // like grain. A mark suppressed here is simply skipped,
                // which is the honest outcome: at that speed a hand
                // cannot tell two marks apart anyway.
                guard now - lastGrainBump > 0.028 else { continue }
                lastGrainBump = now
                // Weight is the mark's own darkness, so the bits of
                // dirt that read on the eye are the bits felt in the
                // hand. Speed lifts it a little, the way pushing a ball
                // harder makes its texture more obvious, and the cap
                // keeps the whole thing at a graze.
                let pace = min(1.0, theta / 0.10)
                let strength = min(0.34, (0.05 + p[4] * 0.13) * (0.5 + pace))
                grain.impactOccurred(intensity: CGFloat(strength))
            } else if z < 0.94 {                            // hysteresis
                ballContact.remove(i)
            }
        }
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
        // Keep turning while it coasts, and repaint: the whole point of
        // a coast is that the ball is still moving, which nobody can
        // see unless it is redrawn. One small dirty rect per frame for
        // about a second after a flick, on a display link that was
        // already running.
        let f = item.frame.resolved(in: bounds.size)
        rollTrackball(dx: Double(trackballVelocity.dx) * dt,
                      dy: Double(trackballVelocity.dy) * dt,
                      radius: Double(min(f.width, f.height) / 2) * 0.95)
        setNeedsDisplay(f.insetBy(dx: -8, dy: -8))

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
            case .rotary:
                // Directions come from tilt, never from this touch: the
                // finger here is turning the aim.
                break
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
            // Coin's brass rides outside the per-input map: the label is
            // the lookup because Coin shares its input id with Select.
            let tint = item.label == "Coin"
                ? (ControlTheme.arcadeCoinTint(system: system) ?? theme.tint(system: system, input: item.input))
                : theme.tint(system: system, input: item.input)
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
            case .rotary:
                // The aim ring, under a thumb. Movement is the phone's
                // own tilt, so there is no stick to draw.
                drawSpinner(in: frame)
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
    /// A knurled dial standing in its housing. See drawTrackball for why
    /// these two were flat until now.
    ///
    /// The knurling is the part that has to survive the material
    /// treatment rather than be replaced by it: the marks are how a
    /// spinner shows it is turning, and a smooth disc would take that
    /// away to gain a highlight. So the dial is moulded like any other
    /// raised part, and the grip lines are cut INTO its lit face,
    /// darker toward the middle of the disc the way a groove in a real
    /// knob is.
    private func drawSpinner(in frame: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(frame.width, frame.height) / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let active = spinnerTouch != nil
        let colors = style(active: active)

        let plate = UIBezierPath(arcCenter: center, radius: radius,
                                 startAngle: 0, endAngle: .pi * 2, clockwise: true)
        let dialRadius = radius * 0.78
        let dial = UIBezierPath(arcCenter: center, radius: dialRadius,
                                startAngle: 0, endAngle: .pi * 2, clockwise: true)

        if material {
            fillSunken(plate, fill: colors.fill)
            fillMoulded(dial, fill: UIColor.white.withAlphaComponent(active ? 0.8 : 0.5), active: active)
        } else {
            colors.fill.setFill(); plate.fill()
            colors.stroke.setStroke(); plate.lineWidth = 1.5; plate.stroke()
            UIColor.white.withAlphaComponent(active ? 0.5 : 0.22).setFill(); dial.fill()
        }

        // Grip lines, cut into the face rather than drawn on top of it.
        ctx.saveGState()
        dial.addClip()
        ctx.setLineCap(.round)
        // Knurling is a fine texture near the rim, not a set of spokes
        // reaching for the middle. The first pass cut them 3pt wide at
        // 30% black and took them more than halfway in, which made the
        // dial read as a segmented plate rather than a knob you could
        // grip. Thinner, lighter, and stopping well short of the centre.
        let notchInner = dialRadius * 0.74
        for i in 0..<12 {
            let a = spinnerVisual + Double(i) * .pi / 6
            let outer = CGPoint(x: center.x + cos(a) * dialRadius,
                                y: center.y + sin(a) * dialRadius)
            let inner = CGPoint(x: center.x + cos(a) * notchInner,
                                y: center.y + sin(a) * notchInner)
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(material ? 0.17 : 0.0).cgColor)
            ctx.setLineWidth(1.7)
            ctx.move(to: inner); ctx.addLine(to: outer); ctx.strokePath()
            // The lit lip on the far side of each groove, the same
            // trick the moulded rim uses at a smaller scale.
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(material ? 0.13 : 0.5).cgColor)
            ctx.setLineWidth(1)
            let off = CGPoint(x: cos(a + 0.05), y: sin(a + 0.05))
            ctx.move(to: CGPoint(x: center.x + off.x * notchInner,
                                 y: center.y + off.y * notchInner))
            ctx.addLine(to: CGPoint(x: center.x + off.x * dialRadius,
                                    y: center.y + off.y * dialRadius))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// A tall pedal with its label laid out to fit the width it has:
    /// the pill renderer centres a fixed-size string and let "Brake"
    /// truncate to an initial.
    /// A footplate sitting in its own housing.
    ///
    /// A pedal is the one control here whose whole identity is that it
    /// MOVES, so the housing is drawn as a well and the plate as a
    /// separate raised part inside it. Pressing collapses the plate's
    /// wall and slides it down into the well, which is a foot pushing
    /// something rather than a rectangle changing colour.
    ///
    /// The tread is cut in, not laid on, for the same reason the
    /// spinner's knurling is: grooves in a lit surface read as texture,
    /// lines drawn over one read as a sticker.
    private func drawPedal(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let path = UIBezierPath(roundedRect: frame, cornerRadius: min(frame.width, frame.height) * 0.28)
        let fill = tint ?? UIColor.white
        var plate = frame

        if material {
            fillSunken(path, fill: UIColor.white)
            // The plate travels into its housing. Small, because a real
            // pedal's throw is short and a big jump reads as a bug.
            plate = frame.insetBy(dx: frame.width * 0.07, dy: frame.height * 0.06)
                .offsetBy(dx: 0, dy: active ? frame.height * 0.045 : 0)
            let top = UIBezierPath(roundedRect: plate,
                                   cornerRadius: min(plate.width, plate.height) * 0.24)
            fillMoulded(top, fill: fill.withAlphaComponent(active ? 0.42 : 0.26), active: active)

            ctx.saveGState()
            top.addClip()
            let rows = 4
            for i in 1...rows {
                let y = plate.minY + plate.height * CGFloat(i) / CGFloat(rows + 1)
                let inset = plate.width * 0.16
                for (dy, color, width) in [
                    (CGFloat(0), UIColor.black.withAlphaComponent(0.34), CGFloat(2.5)),
                    (1.4, UIColor.white.withAlphaComponent(0.18), 1.5),
                ] {
                    ctx.setStrokeColor(color.cgColor)
                    ctx.setLineWidth(width)
                    ctx.setLineCap(.round)
                    ctx.move(to: CGPoint(x: plate.minX + inset, y: y + dy))
                    ctx.addLine(to: CGPoint(x: plate.maxX - inset, y: y + dy))
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        } else {
            ctx.setFillColor(fill.withAlphaComponent(active ? 0.55 : 0.22).cgColor)
            ctx.addPath(path.cgPath); ctx.fillPath()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(path.cgPath); ctx.strokePath()
        }

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
        // Against the plate, not the frame, so the label rides down with
        // it rather than staying put while the pedal moves under it.
        label.draw(at: CGPoint(
            x: plate.midX - text.width / 2, y: plate.midY - text.height / 2), withAttributes: attrs)
    }

    /// An arc that tilts with the wheel's travel, so the control shows
    /// its own steering angle the way a wheel's spokes do.
    /// The top of a steering wheel rising out of the panel.
    ///
    /// The last two controls the material pass never reached. A wheel
    /// was a stroked arc and a pedal was a filled rectangle, which is
    /// how they read next to a moulded stick and a shaded ball.
    ///
    /// A rim is a torus, so it is built as a closed band between two
    /// arcs and moulded like any other raised part: the wall gives it
    /// thickness, the lit face runs along the top of the tube. The grip
    /// mark is cut INTO that face rather than drawn over it, the same
    /// choice the spinner's knurling made, because a line lying on top
    /// of a lit surface is the one thing that gives away a flat drawing.
    private func drawWheel(in frame: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let radius = min(frame.width, frame.height * 2) / 2 - 6
        let center = CGPoint(x: frame.midX, y: frame.maxY)
        let thickness = max(9.0, radius * 0.13)
        let a0 = CGFloat.pi * 1.15, a1 = CGFloat.pi * 1.85
        let colors = style(active: abs(wheelAngle) > 0.02)

        let rim = UIBezierPath()
        rim.addArc(withCenter: center, radius: radius + thickness / 2,
                   startAngle: a0, endAngle: a1, clockwise: true)
        rim.addArc(withCenter: center, radius: radius - thickness / 2,
                   startAngle: a1, endAngle: a0, clockwise: false)
        rim.close()

        if material {
            fillMoulded(rim, fill: colors.fill, active: false)
        } else {
            colors.fill.setFill(); rim.fill()
            colors.stroke.setStroke(); rim.lineWidth = 1.5; rim.stroke()
        }

        // The grip, showing how far the wheel is turned, cut into the
        // tube: a dark groove with a lit lip on one side of it.
        let a = CGFloat.pi * 1.5 + CGFloat(wheelAngle) * (.pi * 0.35)
        ctx.saveGState()
        rim.addClip()
        for (offset, color, width) in [
            (CGFloat(0), UIColor.black.withAlphaComponent(material ? 0.42 : 0.0), CGFloat(5)),
            (0.035, UIColor.white.withAlphaComponent(material ? 0.24 : 0.75), 2.5),
        ] {
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            let ang = a + offset
            ctx.move(to: CGPoint(x: center.x + cos(ang) * (radius - thickness),
                                 y: center.y + sin(ang) * (radius - thickness)))
            ctx.addLine(to: CGPoint(x: center.x + cos(ang) * (radius + thickness),
                                    y: center.y + sin(ang) * (radius + thickness)))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// A filled ball in a shallow well. Deliberately plain: the picture
    /// is the game's, this only has to read as "roll me".
    /// A ball standing in its housing, which is what the cabinet part
    /// actually is: a sphere dropped into a dished plate with only the
    /// top of it proud of the panel.
    ///
    /// This and the spinner were the two controls the material pass
    /// missed. Everything else on a panel had been given a side wall, a
    /// lit face and a contact shadow while these two stayed flat rings,
    /// which is exactly how they read next to the rest. Marcus, 2026-08-25:
    /// "we put all that work into the other stuff and it's like those
    /// were forgotten."
    ///
    /// Built from the same two primitives as the stick, and for the same
    /// reason: a sunken plate is a hole, a moulded dome is an object, and
    /// the pair together is a ball sitting in one.
    private func drawTrackball(in frame: CGRect) {
        let radius = min(frame.width, frame.height) / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let active = trackballTouch != nil
        let colors = style(active: active)

        let plate = UIBezierPath(arcCenter: center, radius: radius,
                                 startAngle: 0, endAngle: .pi * 2, clockwise: true)
        let ballRadius = radius * 0.72
        let ball = UIBezierPath(arcCenter: center, radius: ballRadius,
                                startAngle: 0, endAngle: .pi * 2, clockwise: true)
        guard material else {
            colors.fill.setFill(); plate.fill()
            colors.stroke.setStroke(); plate.lineWidth = 1.5; plate.stroke()
            UIColor.white.withAlphaComponent(active ? 0.85 : 0.6).setFill(); ball.fill()
            return
        }
        fillSunken(plate, fill: colors.fill)

        // A trackball sits DOWN IN its housing: the cabinet part is a
        // sphere dropped through a hole with only its crown proud of
        // the panel, and you never see its equator. Marcus, 2026-08-25:
        // "the balls usually sat below the surface a bit."
        //
        // So the sphere is drawn bigger than the hole, centred below
        // it, and clipped to the aperture. What shows is the top of a
        // large ball rather than the whole of a small one, which is
        // the difference between something sunk into a panel and
        // something resting on it. That is also what separates it from
        // the joystick, which stands proud on a shaft and is red;
        // white here, so the two read as different objects at a
        // glance rather than the same object twice.
        let apertureR = radius * 0.74
        let aperture = UIBezierPath(arcCenter: center, radius: apertureR,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        ctx.saveGState()
        aperture.addClip()
        let ballC = CGPoint(x: center.x, y: center.y + radius * 0.16)
        let ballR = radius * 0.95
        fillSphere(center: ballC, radius: ballR, fill: .white, active: active)

        // The speckle, which is the only reason a rolling ball reads as
        // rolling. A smooth uniform sphere spinning looks exactly like a
        // smooth uniform sphere at rest, because nothing on it moves;
        // real trackballs are flecked, and the flecks are the motion.
        //
        // Each mark is a fixed point on the ball, turned by the ball's
        // own orientation and then projected, so they sweep across the
        // crown and disappear over the limb the way marks on a real one
        // do. Only the near hemisphere is drawn, and marks fade as they
        // approach the edge, where a sphere's surface turns away from
        // the viewer.
        for p in Self.ballSpeckle {
            let x = trackballSpin[0][0]*p[0] + trackballSpin[0][1]*p[1] + trackballSpin[0][2]*p[2]
            let y = trackballSpin[1][0]*p[0] + trackballSpin[1][1]*p[1] + trackballSpin[1][2]*p[2]
            let z = trackballSpin[2][0]*p[0] + trackballSpin[2][1]*p[1] + trackballSpin[2][2]*p[2]
            guard z > 0.12 else { continue }                 // facing away
            let px = ballC.x + CGFloat(x) * ballR
            let py = ballC.y + CGFloat(y) * ballR
            // Foreshortened: a disc seen at an angle is an ellipse, and
            // near the limb it is nearly an edge.
            let r = CGFloat((0.040 + 0.016 * z) * p[3]) * ballR
            let fade = CGFloat(min(1, (z - 0.12) / 0.35))

            // Each mark is a blob, not a dot: an oblong body lying at
            // its own angle with a second lobe pushed off to one side,
            // so the silhouette is irregular. Marcus, 2026-08-25:
            // "some just look too dark and perfect, need more dirt,
            // like penetrative."
            //
            // Drawn as a wide faint halo with a smaller darker core
            // inside it, which is what gives a soft edge without a
            // gradient per mark: grime soaked into plastic has no
            // outline, and a hard-edged ellipse always reads as
            // printed on top of the surface rather than down in it.
            let ink = CGFloat(fade) * CGFloat(p[4])
            let squash = CGFloat(p[5]), lean = CGFloat(p[6])
            let lobe = CGPoint(x: px + CGFloat(cos(p[7]) * p[8]) * r * CGFloat(z),
                               y: py + CGFloat(sin(p[7]) * p[8]) * r)
            func blob(_ c: CGPoint, _ rad: CGFloat, _ alpha: CGFloat) {
                guard alpha > 0.004 else { return }
                ctx.saveGState()
                ctx.translateBy(x: c.x, y: c.y)
                ctx.rotate(by: lean)
                UIColor(white: 0.26, alpha: alpha).setFill()
                UIBezierPath(ovalIn: CGRect(
                    x: -rad * CGFloat(z), y: -rad * squash,
                    width: rad * 2 * CGFloat(z), height: rad * 2 * squash)).fill()
                ctx.restoreGState()
            }
            blob(CGPoint(x: px, y: py), r * 1.45, 0.055 * ink)   // halo
            blob(CGPoint(x: px, y: py), r,        0.150 * ink)   // body
            blob(lobe, r * CGFloat(p[9]),         0.120 * ink)   // the second lobe
            continue
        }
        // The lip's own shadow falling onto the ball, strongest under
        // the near edge at the top, which is what actually says "this
        // is below the surface" rather than merely small.
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [UIColor.black.withAlphaComponent(0.55).cgColor,
                                       UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1]) {
            ctx.drawRadialGradient(
                g,
                startCenter: CGPoint(x: center.x, y: center.y - apertureR),
                startRadius: 0,
                endCenter: CGPoint(x: center.x, y: center.y - apertureR),
                endRadius: apertureR * 1.25, options: [])
        }
        ctx.restoreGState()

        // The cut edge of the hole itself, over everything.
        ctx.saveGState()
        UIColor.black.withAlphaComponent(0.5).setStroke()
        aperture.lineWidth = 2
        aperture.stroke()
        UIColor.white.withAlphaComponent(0.16).setStroke()
        let liplight = UIBezierPath(arcCenter: CGPoint(x: center.x, y: center.y + 1.2),
                                    radius: apertureR, startAngle: 0, endAngle: .pi * 2,
                                    clockwise: true)
        liplight.lineWidth = 1
        liplight.stroke()
        ctx.restoreGState()
    }

    private func drawStick(in frame: CGRect) {
        let radius = min(frame.width, frame.height) / 2
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let active = stickTouch != nil
        let colors = style(active: active)

        let base = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        if material {
            // A stick sits IN its housing, so the base is the one part
            // of a panel that goes the other way: sunk rather than
            // raised, lit from below because the far wall of a dish is
            // what catches the light. The knob on top is moulded like
            // everything else, which is what makes the pair read as an
            // object standing in a well.
            fillSunken(base, fill: colors.fill)
        } else {
            colors.fill.setFill()
            base.fill()
            colors.stroke.setStroke()
            base.lineWidth = 1.5
            base.stroke()
        }

        let knobRadius = radius * 0.42
        let knobCenter = CGPoint(
            x: center.x + stickPosition.x * (radius - knobRadius),
            y: center.y + stickPosition.y * (radius - knobRadius)
        )
        let knob = UIBezierPath(arcCenter: knobCenter, radius: knobRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        let knobFill = UIColor.white.withAlphaComponent(active ? 0.85 : 0.55)
        if material {
            fillMoulded(knob, fill: knobFill, active: active)
        } else {
            knobFill.setFill()
            knob.fill()
        }
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

    /// An arcade cabinet has a JOYSTICK, not a d-pad, so on an arcade
    /// panel that is what gets drawn: a ball standing in a round
    /// housing, leaning the way it is being pushed.
    ///
    /// Rendering only. The item stays a `dpad` carrying the digital
    /// inputs 4/5/6/7, the touch handling keeps the overlapping
    /// direction rects that make diagonals reachable, and nothing goes
    /// near the analogue axis. That last part is not incidental: FBNeo
    /// reads the left stick through a fake-analogue fallback even for
    /// digital games, which is what made a Bluetooth pad register up
    /// and down in the same frame (issue #3). A joystick that LOOKS
    /// like a joystick must not become one on the wire.
    ///
    /// The lean is the whole point of drawing it at all. A cross either
    /// lights up or does not; a ball that tilts tells you which way it
    /// went and how far, which is the feedback a real stick gives
    /// through the hand and a touchscreen otherwise cannot.
    private func drawArcadeStick(in frame: CGRect, inputs: [Int], tint: UIColor?) {
        let side = (frame.width * frame.height).squareRoot()
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let radius = side / 2

        // inputs arrive as [up, down, left, right]
        var dx = 0.0, dy = 0.0
        if inputs.count >= 4 {
            if pressed.contains(inputs[0]) { dy -= 1 }
            if pressed.contains(inputs[1]) { dy += 1 }
            if pressed.contains(inputs[2]) { dx -= 1 }
            if pressed.contains(inputs[3]) { dx += 1 }
        }
        let len = (dx * dx + dy * dy).squareRoot()
        if len > 0 { dx /= len; dy /= len }
        let anyActive = len > 0
        let colors = style(active: anyActive, tint: tint)

        // The mounting plate under the stick, the square base a real
        // one bolts to. The first cut was brushed steel from the
        // MAME4iOS reference, and Marcus called it right: chrome is
        // their world, and next to Cabinet's dark moulded panels it
        // read as a part from a different machine. The plate is now the
        // panel's own material, a shade off the ground so the base
        // reads without announcing itself, and the grain is gone.
        if material {
            let plateHalf = radius * 1.12
            let plate = UIBezierPath(
                roundedRect: CGRect(x: center.x - plateHalf, y: center.y - plateHalf,
                                    width: plateHalf * 2, height: plateHalf * 2),
                cornerRadius: radius * 0.18)
            fillMoulded(plate, fill: UIColor(white: 0.13, alpha: 1), active: false)
        }

        let housing = UIBezierPath(arcCenter: center, radius: radius,
                                   startAngle: 0, endAngle: .pi * 2, clockwise: true)
        if material {
            fillSunken(housing, fill: colors.fill)
        } else {
            colors.fill.setFill(); housing.fill()
            colors.stroke.setStroke(); housing.lineWidth = 1.5; housing.stroke()
        }

        // The eight gate notches around the plate, which is what tells
        // you at a glance that this is a stick and not a dish.
        if let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.white.withAlphaComponent(material ? 0.18 : 0.3).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineCap(.round)
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                ctx.move(to: CGPoint(x: center.x + cos(a) * radius * 0.72,
                                     y: center.y + sin(a) * radius * 0.72))
                ctx.addLine(to: CGPoint(x: center.x + cos(a) * radius * 0.88,
                                        y: center.y + sin(a) * radius * 0.88))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // The shaft, drawn before the ball so the ball caps it.
        let ballRadius = radius * 0.44
        let throwDist = (radius - ballRadius) * 0.55
        let ballCenter = CGPoint(x: center.x + dx * throwDist, y: center.y + dy * throwDist)
        if anyActive, let ctx = UIGraphicsGetCurrentContext() {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.black.withAlphaComponent(material ? 0.35 : 0.2).cgColor)
            ctx.setLineWidth(ballRadius * 0.5)
            ctx.setLineCap(.round)
            ctx.move(to: center)
            ctx.addLine(to: ballCenter)
            ctx.strokePath()
            ctx.restoreGState()
        }

        let ballFill = tint ?? Self.ballTop
        if material {
            fillSphere(center: ballCenter, radius: ballRadius, fill: ballFill, active: anyActive)
        } else {
            let ball = UIBezierPath(arcCenter: ballCenter, radius: ballRadius,
                                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ballFill.withAlphaComponent(anyActive ? 0.95 : 0.7).setFill()
            ball.fill()
        }
    }

    private func drawDpad(in frame: CGRect, inputs: [Int], label: String? = nil, tint: UIColor? = nil) {
        // An arcade panel gets a stick, because that is what the
        // cabinet had. Same item, same digital inputs, different
        // drawing. See drawArcadeStick.
        if system.hasPrefix("arcade") {
            drawArcadeStick(in: frame, inputs: inputs, tint: tint)
            return
        }
        // A d-pad is square. Every real one ever made is, and a thumb
        // rolling between up and left expects the same travel either
        // way. The cross used to fill whatever rect it was given, so
        // it inherited the frame's aspect AND the screen's: snes is
        // authored 0.19 by 0.42, which is square on a screen with no
        // safe-area insets and 16% taller once the drawing area is
        // inset to 773x407, which is what Marcus saw and measured.
        // Fitting a square inside the frame makes a d-pad the same
        // shape on every phone, whatever the layout says and whatever
        // the insets do.
        // Area-preserving rather than fitted inside: the frame was
        // never a deliberate box, it was a d-pad drawn to a size that
        // happened to render oblong, so keeping the weight the author
        // chose is closer to the intent than keeping a rectangle
        // nobody picked. Comes out 159pt where fitting inside gave
        // 147. Checked against every layout: no d-pad at this size
        // touches a neighbouring control.
        let side = (frame.width * frame.height).squareRoot()
        let frame = CGRect(
            x: frame.midX - side / 2, y: frame.midY - side / 2,
            width: side, height: side)
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
        if material {
            // usesEvenOddFillRule matters here: the cross is two
            // overlapping rounded rects, and the moulded fill draws
            // the path once rather than twice.
            cross.usesEvenOddFillRule = false
            fillMoulded(cross, fill: colors.fill, active: anyActive)
        } else {
            colors.fill.setFill()
            cross.fill()
        }
        if !material {
            colors.stroke.setStroke()
            cross.lineWidth = 1.5
            cross.stroke()
        }

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

    /// Fills a control so it stands off the panel: a side wall you can
    /// actually see, a tight contact shadow at its base, a lit face,
    /// and a soft edge along the top.
    ///
    /// The first attempt lit the face and cast a soft shadow and
    /// Marcus's verdict was that the controls still had no height. He
    /// was right, and the reason is that a dark canvas cannot receive
    /// a dark shadow: black on near-black is invisible, so the whole
    /// depth cue was doing nothing. Height on a dark ground has to be
    /// DRAWN rather than shaded, which is what the side wall below is,
    /// a darker copy of the shape offset downward, so the control
    /// reads as an object with a thickness rather than a disc lying
    /// flat. Pressing collapses that wall, which is a real key going
    /// down rather than a colour changing.
    private func fillMoulded(_ path: UIBezierPath, fill: UIColor, active: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            fill.setFill(); path.fill(); return
        }
        // Depth in points. Overshot to 8 while proving the effect was
        // working at all, which it now visibly is, so pulled back to
        // where a control reads as raised rather than as stacked. The
        // press depth stays near zero: the collapse is what sells it.
        let depth: CGFloat = active ? 1 : 4

        // The side wall: the shape again, below, in the fill's own
        // colour taken well down. Its own colour rather than black, so
        // a green button has a green edge and still reads as one piece.
        //
        // SOLID, and that is the whole trick. The fills these controls
        // use are translucent by design (14% white for an untinted
        // one, so a game shows through underneath), and the first
        // version inherited that alpha for the wall: 14% of a dark
        // colour on a dark panel is nothing at all, which is exactly
        // why Marcus saw no height. A panel has no game behind it, so
        // its walls can be opaque, and an opaque edge is the only part
        // of this that a dark ground can actually show.
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        let wall: UIColor = fill.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
            ? UIColor(hue: hue, saturation: min(sat * 1.2, 1),
                      brightness: max(bri * 0.42, 0.10), alpha: 1)
            : UIColor(white: 0.14, alpha: 1)
        ctx.saveGState()
        let side = path.copy() as! UIBezierPath
        side.apply(CGAffineTransform(translationX: 0, y: depth))
        // A tight contact shadow under the wall. Tight on purpose: a
        // wide soft one dissolves into a dark panel and says nothing.
        ctx.setShadow(
            offset: CGSize(width: 0, height: active ? 1 : 2),
            blur: active ? 2 : 4,
            color: UIColor.black.withAlphaComponent(0.7).cgColor)
        wall.setFill()
        side.fill()
        ctx.restoreGState()

        // A hairline of the wall's colour just inside the face, so the
        // join between the two is a turned edge rather than a step.
        // The face, sitting on top of its own wall, and opaque for the
        // same reason: a translucent face lets its own wall show
        // through and the object flattens back out. The alpha these
        // fills carry is for sitting over a game, which a panel does
        // not have.
        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        let solidFace: UIColor = fill.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            ? UIColor(red: fr, green: fg, blue: fb, alpha: 1)
            : fill
        // Untinted controls fill at 14% white, which is nearly the
        // panel itself once opaque; lift those so a grey control has
        // any presence at all.
        let face = fa < 0.5
            ? UIColor(white: 0.30 + Double(fa) * 0.4, alpha: 1)
            : solidFace
        face.setFill()
        path.fill()
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        wall.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 2.2
        path.stroke()
        ctx.restoreGState()

        // Light from above, fixed. A light that moved with the phone
        // was tried and looked wrong to Marcus; a real handheld thing
        // is lit by the room, and the room does not swing.
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        let top = UIColor.white.withAlphaComponent(active ? 0.02 : 0.16).cgColor
        let mid = UIColor.white.withAlphaComponent(active ? 0.0 : 0.04).cgColor
        let bottom = UIColor.black.withAlphaComponent(active ? 0.34 : 0.24).cgColor
        let stops: [CGColor] = active
            ? [bottom, UIColor.clear.cgColor, mid, top]
            : [top, mid, UIColor.clear.cgColor, bottom]
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops as CFArray, locations: [0, 0.35, 0.62, 1]) {
            let b = path.bounds
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: b.midX, y: b.minY),
                end: CGPoint(x: b.midX, y: b.maxY),
                options: [])
        }
        ctx.restoreGState()

        // A soft rim along the top edge, feathered over three passes:
        // one crisp stroke read as a hard band painted across the face.
        if !active {
            ctx.saveGState()
            ctx.addPath(path.cgPath)
            ctx.clip()
            let edge = path.copy() as! UIBezierPath
            edge.apply(CGAffineTransform(translationX: 0, y: 1.2))
            for (width, a) in [(3.4, 0.04), (2.2, 0.07), (1.2, 0.11)] {
                UIColor.white.withAlphaComponent(a).setStroke()
                edge.lineWidth = width
                edge.stroke()
            }
            ctx.restoreGState()
        }
    }

    /// The classic arcade ball top. Red because that is what a cabinet
    /// had, and because a white ball on a grey panel is the least
    /// interesting object in the room. One constant, easy to change.
    private static let ballTop = UIColor(red: 0.83, green: 0.14, blue: 0.17, alpha: 1)

    /// A sphere, as opposed to a disc with a highlight on it.
    ///
    /// `fillMoulded` extrudes a flat shape: side wall, lit face, rim. It
    /// is the right tool for a button, which IS a flat shape pushed up
    /// out of a panel, and the wrong one for a ball, which has no face
    /// and no wall. Marcus, 2026-08-25, on the joystick: "the white ball
    /// seems kind of boring and it also doesn't look much like a ball."
    /// It did not, because it was a moulded circle.
    ///
    /// What makes a sphere read is the gradient running off-centre.
    /// Light arrives from the upper left, so the bright point sits up
    /// and left of the middle rather than in it, the tone falls away in
    /// every direction from there, and the far edge goes darkest. The
    /// small hard specular near the light is what says the surface is
    /// glossy plastic, and the faint bounce along the lower right is
    /// light coming back off the panel, which is what stops the dark
    /// side reading as a flat shadow.
    private func fillSphere(center: CGPoint, radius: CGFloat, fill: UIColor, active: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext(), radius > 0 else {
            fill.setFill()
            UIBezierPath(arcCenter: center, radius: max(radius, 0),
                         startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
            return
        }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let hasHue = fill.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        func shade(_ bri: CGFloat, _ satMul: CGFloat = 1, _ alpha: CGFloat = 1) -> UIColor {
            hasHue ? UIColor(hue: h, saturation: min(sat * satMul, 1),
                             brightness: max(min(bri, 1), 0), alpha: alpha)
                   : UIColor(white: bri, alpha: alpha)
        }
        let ball = UIBezierPath(arcCenter: center, radius: radius,
                                startAngle: 0, endAngle: .pi * 2, clockwise: true)

        // Grounded first: a ball resting in a housing casts under
        // itself, and without it the thing floats.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: active ? 1 : 3),
                      blur: active ? 3 : 6,
                      color: UIColor.black.withAlphaComponent(0.65).cgColor)
        shade(max(b * 0.5, 0.06)).setFill()
        ball.fill()
        ctx.restoreGState()

        ctx.saveGState()
        ball.addClip()
        let lit = CGPoint(x: center.x - radius * 0.34, y: center.y - radius * 0.38)
        let stops: [CGFloat] = [0, 0.45, 0.78, 1]
        let cols = [
            shade(min(b * 1.55 + 0.20, 1.0), 0.55).cgColor,   // near the light
            shade(min(b * 1.05, 1.0)).cgColor,                // body
            shade(b * 0.52, 1.15).cgColor,                    // turning away
            shade(b * 0.26, 1.25).cgColor,                    // the far edge
        ]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: cols as CFArray, locations: stops) {
            ctx.drawRadialGradient(
                g, startCenter: lit, startRadius: 0,
                endCenter: center, endRadius: radius * 1.30,
                options: [.drawsAfterEndLocation])
        }
        // Bounce off the panel along the lower right, so the dark side
        // is a turning surface rather than a flat shadow.
        if let g2 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [shade(1, 0.3, 0.16).cgColor,
                                        shade(1, 0.3, 0).cgColor] as CFArray,
                               locations: [0, 1]) {
            ctx.drawRadialGradient(
                g2,
                startCenter: CGPoint(x: center.x + radius * 0.55, y: center.y + radius * 0.62),
                startRadius: 0,
                endCenter: CGPoint(x: center.x + radius * 0.55, y: center.y + radius * 0.62),
                endRadius: radius * 0.85, options: [])
        }
        // The specular: small, hard-ish, near the light. This is the
        // single detail that reads as "glossy" at a glance.
        let sr = radius * 0.26
        let sc = CGPoint(x: center.x - radius * 0.36, y: center.y - radius * 0.42)
        if let g3 = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [UIColor(white: 1, alpha: active ? 0.75 : 0.9).cgColor,
                                        UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                               locations: [0, 1]) {
            ctx.drawRadialGradient(g3, startCenter: sc, startRadius: 0,
                                   endCenter: sc, endRadius: sr, options: [])
        }
        ctx.restoreGState()

        // A dark contact line where the ball meets its housing.
        ctx.saveGState()
        shade(b * 0.20, 1.2, 0.55).setStroke()
        ball.lineWidth = 1.5
        ball.stroke()
        ctx.restoreGState()
    }

    /// The inverse of `fillMoulded`, for the parts of a panel that are
    /// holes rather than objects: a stick's housing, a trackball's
    /// well. Darker than the panel, its shadow cast inward from the
    /// near rim, lit along the far one.
    private func fillSunken(_ path: UIBezierPath, fill: UIColor) {
        guard let ctx = UIGraphicsGetCurrentContext() else {
            fill.setFill(); path.fill(); return
        }
        UIColor(white: 0.055, alpha: 1).setFill()
        path.fill()
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        let b = path.bounds
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [UIColor.black.withAlphaComponent(0.75).cgColor,
                     UIColor.clear.cgColor,
                     UIColor.white.withAlphaComponent(0.10).cgColor] as CFArray,
            locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: b.midX, y: b.minY),
                end: CGPoint(x: b.midX, y: b.maxY), options: [])
        }
        ctx.restoreGState()
    }


    /// An arcade button as a glossy dome in a bezel, the look of the
    /// machine rather than of an interface. Prompted by MAME4iOS's
    /// panels, which Marcus sent as the reference; built with this
    /// file's own vocabulary rather than their assets, the way the
    /// spinner and trackball were. Three parts sell it: a dark bezel
    /// ring the dome sits INSIDE rather than on, a colour that runs
    /// light-at-top to deep-at-bottom because a dome faces the light
    /// with its crown, and one hard specular bead up and left. Pressing
    /// flattens the dome: the gradient squashes, the bead dims, and the
    /// whole face drops a point, which reads as travel the way the
    /// moulded wall's collapse does on a flat key.
    /// An arcade button as a CONCAVE cap in a bezel: the dished kind a
    /// finger settles into, which is what most real panels carry.
    /// Marcus, after two rounds of taming the convex version: "instead
    /// of popping up I want them in." A dish is lit opposite to a dome.
    /// The rim's top edge shades the bowl, the light pools low in it,
    /// and the sheen is a soft floor glow rather than a crown bead.
    /// Pressing settles the whole dish a shade darker and a point
    /// deeper, a finger filling the bowl.
    private func fillDome(center: CGPoint, radius: CGFloat, fill: UIColor, active: Bool) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        fill.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)

        // The bezel, unchanged from the domed pass: a dark ring the cap
        // sits inside, with a faint lit inner edge.
        let bezel = UIBezierPath(arcCenter: center, radius: radius,
                                 startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(white: 0.16, alpha: 1).setFill(); bezel.fill()
        ctx.saveGState()
        bezel.addClip()
        ctx.setStrokeColor(UIColor(white: 0.42, alpha: 1).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius + 0.75, y: center.y - radius + 0.75,
                                     width: radius * 2 - 1.5, height: radius * 2 - 1.5))
        ctx.restoreGState()

        let dr = radius * 0.82
        let press: CGFloat = active ? 1.0 : 0
        let dc = CGPoint(x: center.x, y: center.y + press)
        let dish = UIBezierPath(ovalIn: CGRect(x: dc.x - dr, y: dc.y - dr,
                                               width: dr * 2, height: dr * 2))
        // Shading by pulling BRIGHTNESS out of a hue makes mud: yellow
        // driven dark goes olive, orange goes brown, and Marcus felt it
        // before either of us could name it, "it's the colors,
        // something ain't right." A real shadow is not a darker paint,
        // it is less light: so the walls and rim now darken by mixing
        // toward the panel's own near-black, which keeps every hue
        // itself all the way down, just further from the lamp.
        func mixed(_ c: UIColor, toward dark: CGFloat) -> UIColor {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            let dr2: CGFloat = 0.07, dg: CGFloat = 0.07, db: CGFloat = 0.08
            return UIColor(red: r + (dr2 - r) * dark, green: g + (dg - g) * dark,
                           blue: b + (db - b) * dark, alpha: 1)
        }
        let base = UIColor(hue: hue, saturation: sat, brightness: bri, alpha: 1)
        let floorC = mixed(base, toward: active ? 0.16 : 0.02)
        let wallC = mixed(base, toward: active ? 0.38 : 0.30)
        let rimC = mixed(base, toward: active ? 0.66 : 0.60)
        ctx.saveGState()
        dish.addClip()
        let space = CGColorSpaceCreateDeviceRGB()
        let grad = CGGradient(colorsSpace: space,
                              colors: [floorC.cgColor, wallC.cgColor, rimC.cgColor] as CFArray,
                              locations: [0, 0.62, 1])!
        // Light pools LOW in a dish: the bright centre sits below the
        // middle and the walls climb darker toward the rim.
        ctx.drawRadialGradient(
            grad,
            startCenter: CGPoint(x: dc.x, y: dc.y + dr * 0.30),
            startRadius: 0,
            endCenter: dc,
            endRadius: dr * 1.02, options: [.drawsAfterEndLocation])
        // The top rim's shadow falling into the bowl, the single
        // strongest cue that this is a hole and not a hill.
        let crescent = CGGradient(colorsSpace: space, colors: [
            UIColor.black.withAlphaComponent(active ? 0.34 : 0.28).cgColor,
            UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: dc.x, y: dc.y - dr * 0.9)
        ctx.scaleBy(x: 1.15, y: 0.5)
        ctx.drawRadialGradient(crescent, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: dr * 0.9, options: [])
        ctx.restoreGState()
        // And the lower inner lip catching the light on its way out.
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(active ? 0.10 : 0.18).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addArc(center: dc, radius: dr - 1, startAngle: .pi * 0.15,
                   endAngle: .pi * 0.85, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
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
        if material, system.hasPrefix("arcade") {
            // Arcade panels get the machine's own domed cap; every
            // other system keeps the flat moulded key, which is that
            // hardware's honest shape.
            fillDome(center: CGPoint(x: circleRect.midX, y: circleRect.midY),
                     radius: diameter / 2, fill: colors.fill, active: active)
        } else if material {
            fillMoulded(circle, fill: colors.fill, active: active)
        } else {
            colors.fill.setFill()
            circle.fill()
        }
        // No outline on a moulded control. A hard bright line around
        // an opaque object is what makes it read as cut out and stuck
        // on rather than formed, which is what Marcus saw once the
        // height started working. The wall, the shading and the rim
        // already say where the edge is. The stroke stays for the
        // translucent controls, where it is the only thing separating
        // them from the game behind.
        if !material {
            colors.stroke.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
        }

        drawLabel(label, in: circleRect, fontSize: diameter * 0.34, color: labelColor(tint: tint))
    }

    private func drawPill(in frame: CGRect, label: String?, tint: UIColor?, active: Bool) {
        let pill = UIBezierPath(roundedRect: frame, cornerRadius: frame.height / 2)
        let colors = style(active: active, tint: tint)
        if material {
            fillMoulded(pill, fill: colors.fill, active: active)
        } else {
            colors.fill.setFill()
            pill.fill()
        }
        if !material {
            colors.stroke.setStroke()
            pill.lineWidth = 1.5
            pill.stroke()
        }

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
