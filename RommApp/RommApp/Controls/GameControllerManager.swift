import Combine
import GameController
import SwiftUI

/// Physical controllers, captured natively with GameController rather than
/// the webview's Gamepad API, per the scope doc. The web side is suppressed
/// separately in the player injection, or every press would register twice.
///
/// Buttons are bound through ControllerBindings rather than hardcoded, because
/// controllers genuinely differ: a full size pad has Menu and Options where
/// Start and Coin belong, while a compact pad may expose neither, which would
/// leave an arcade game with no way to insert a credit. Whatever a controller
/// reports can be pointed at whatever input the player needs.
@MainActor
final class GameControllerManager: ObservableObject {
    /// One manager for the whole app. Button handlers live on the controller
    /// itself, so two managers would overwrite each other's handlers and
    /// whichever screen attached last would silently steal every press.
    static let shared = GameControllerManager()

    private var started = false
    /// A controller is attached and driving the game.
    @Published private(set) var isConnected = false
    /// The attached controller's name, for showing which pad is in charge.
    @Published private(set) var controllerName: String?
    /// Inputs currently held, so a test screen can show what the app sees.
    @Published private(set) var pressedInputs: Set<Int> = []
    /// Every button this controller reports, by element name, so a remap
    /// screen can show what actually exists rather than what was assumed.
    @Published private(set) var availableButtons: [String] = []
    /// Set when a controller is paired but does not present a standard
    /// gamepad, which no app can drive and no remapping can rescue.
    @Published private(set) var unsupportedController: String?

    /// Sends a RetroPad input id and its state to the emulator.
    var send: ((Int, Bool) -> Void)?
    /// Called when the pad's overlay button is pressed.
    var onMenu: (() -> Void)?
    /// Called when a controller disconnects mid game, so play can pause
    /// rather than continuing untouched while nobody is holding anything.
    var onDisconnect: (() -> Void)?

    /// While set, presses are reported here instead of driving the game, so
    /// the remap screen can learn which physical button someone pressed.
    var captureHandler: ((String) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var triggerDown: [String: Bool] = [:]
    private weak var pad: GCExtendedGamepad?
    private var bindings: [String: Int] = ControllerBindings.defaults

    var storageKey: String { controllerName ?? "unknown" }

    func start() {
        guard !started else { return }
        started = true

        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            Task { @MainActor in self?.attach(controller) }
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDisconnect() }
        })

        if let existing = GCController.controllers().first {
            attach(existing)
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        releaseAll()
    }

    /// Rebuilds handlers after the remap screen changes a binding.
    func reloadBindings() {
        guard let controller = GCController.controllers().first else { return }
        attach(controller)
    }

    // MARK: Wiring

    private func attach(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else {
            // Paired and visible to iOS, but not as a standard gamepad. Say
            // so rather than appearing to see nothing at all, because the
            // two look identical from the outside and have different fixes.
            unsupportedController = controller.vendorName ?? "This controller"
            isConnected = false
            return
        }
        unsupportedController = nil

        pad = gamepad
        isConnected = true
        controllerName = controller.vendorName
        bindings = ControllerBindings.effective(for: controller.vendorName ?? "unknown")

        // Directions come from the d-pad and the left stick, always, with no
        // binding involved. They are never the thing that goes missing.
        gamepad.dpad.up.pressedChangedHandler = direction(RetroPad.up)
        gamepad.dpad.down.pressedChangedHandler = direction(RetroPad.down)
        gamepad.dpad.left.pressedChangedHandler = direction(RetroPad.left)
        gamepad.dpad.right.pressedChangedHandler = direction(RetroPad.right)
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in self?.stick(x: x, y: y) }
        }

        // Bind the standard buttons by their canonical names. The elements
        // dictionary cannot be used for this: it keys every button under
        // several aliases at once, so iterating it installs handlers under
        // whichever alias happens to come last and no name ever matches the
        // binding table again.
        var candidates: [(String, GCControllerButtonInput)] = [
            (GCInputButtonA, gamepad.buttonA),
            (GCInputButtonB, gamepad.buttonB),
            (GCInputButtonX, gamepad.buttonX),
            (GCInputButtonY, gamepad.buttonY),
            (GCInputLeftShoulder, gamepad.leftShoulder),
            (GCInputRightShoulder, gamepad.rightShoulder),
            (GCInputLeftTrigger, gamepad.leftTrigger),
            (GCInputRightTrigger, gamepad.rightTrigger),
            (GCInputButtonMenu, gamepad.buttonMenu),
        ]
        // These are optional on the profile: a compact pad may have none of
        // them, which is exactly why remapping exists.
        if let options = gamepad.buttonOptions {
            candidates.append((GCInputButtonOptions, options))
        }
        if let home = gamepad.buttonHome {
            candidates.append((GCInputButtonHome, home))
        }
        if let l3 = gamepad.leftThumbstickButton {
            candidates.append((GCInputLeftThumbstickButton, l3))
        }
        if let r3 = gamepad.rightThumbstickButton {
            candidates.append((GCInputRightThumbstickButton, r3))
        }

        #if DEBUG
        print("GC_ATTACH name=\(controller.vendorName ?? "?") category=\(controller.productCategory) buttons=\(candidates.map(\.0))")
        #endif

        for (name, button) in candidates {
            // Triggers report analog values and need a threshold; everything
            // else is a clean pressed change. Reading isAnalog rather than
            // assuming, since some pads report pressure on face buttons.
            if button.isAnalog {
                button.valueChangedHandler = { [weak self] _, value, _ in
                    Task { @MainActor in self?.analog(name, value: value) }
                }
            } else {
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.button(name, pressed: pressed) }
                }
            }
        }
        availableButtons = candidates.map(\.0)
    }

    /// A physical button changed. In capture mode it names itself for the
    /// remap screen; otherwise it drives whatever it is bound to.
    private func button(_ name: String, pressed: Bool) {
        #if DEBUG
        print("GC_BUTTON \(name) pressed=\(pressed) capturing=\(captureHandler != nil) bound=\(bindings[name].map(String.init) ?? "none")")
        #endif
        if let capture = captureHandler {
            if pressed { capture(name) }
            return
        }
        guard let id = bindings[name] else { return }
        emit(id, pressed)
    }

    /// Analog buttons, meaning triggers, need a threshold with hysteresis or
    /// a resting finger chatters the input on and off.
    private func analog(_ name: String, value: Float) {
        let wasDown = triggerDown[name] ?? false
        let isDown = wasDown ? value > 0.25 : value > 0.35
        guard isDown != wasDown else { return }
        triggerDown[name] = isDown
        button(name, pressed: isDown)
    }

    private func direction(_ id: Int) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            #if DEBUG
            print("GC_DPAD id=\(id) pressed=\(pressed)")
            #endif
            Task { @MainActor in
                guard self?.captureHandler == nil else { return }
                self?.emit(id, pressed)
            }
        }
    }

    private func stick(x: Float, y: Float) {
        guard captureHandler == nil else { return }
        let threshold: Float = 0.5
        emit(RetroPad.left, x < -threshold)
        emit(RetroPad.right, x > threshold)
        emit(RetroPad.down, y < -threshold)
        emit(RetroPad.up, y > threshold)
    }

    /// Routes an input to the game and to anything watching for diagnostics.
    private func emit(_ id: Int, _ down: Bool) {
        if down { pressedInputs.insert(id) } else { pressedInputs.remove(id) }
        send?(id, down)
    }

    private func handleDisconnect() {
        guard GCController.controllers().isEmpty else { return }
        releaseAll()
        isConnected = false
        controllerName = nil
        availableButtons = []
        onDisconnect?()
    }

    /// Drops every input on disconnect, or a direction held at the moment the
    /// pad died would stay held forever.
    private func releaseAll() {
        for id in pressedInputs { send?(id, false) }
        pressedInputs.removeAll()
        triggerDown.removeAll()
    }

    // MARK: Remapping

    /// The element name currently bound to an input, if any.
    func boundButton(for id: Int) -> String? {
        bindings.first { $0.value == id }?.key
    }

    /// The input a physical button currently drives, if any.
    func bindings(for name: String) -> Int? {
        bindings[name]
    }

    /// Points a physical button at an input, clearing whatever else claimed
    /// either side so one press can never fire two inputs.
    func bind(button name: String, to id: Int) {
        bindings = bindings.filter { $0.key != name && $0.value != id }
        bindings[name] = id
        ControllerBindings.save(bindings, for: storageKey)
        reloadBindings()
    }

    func clearBinding(for id: Int) {
        bindings = bindings.filter { $0.value != id }
        ControllerBindings.save(bindings, for: storageKey)
        reloadBindings()
    }

    func resetBindings() {
        ControllerBindings.reset(for: storageKey)
        bindings = ControllerBindings.defaults
        reloadBindings()
    }

    /// A readable name for a GameController element, since the raw constants
    /// read like "Button Options" and mean nothing to most people.
    static func friendlyName(_ element: String) -> String {
        switch element {
        case GCInputButtonA: return "Bottom face button, A or Cross"
        case GCInputButtonB: return "Right face button, B or Circle"
        case GCInputButtonX: return "Left face button, X or Square"
        case GCInputButtonY: return "Top face button, Y or Triangle"
        case GCInputLeftShoulder: return "Left shoulder, LB or L1"
        case GCInputRightShoulder: return "Right shoulder, RB or R1"
        case GCInputLeftTrigger: return "Left trigger, LT or L2"
        case GCInputRightTrigger: return "Right trigger, RT or R2"
        case GCInputButtonMenu: return "Menu or Options"
        case GCInputButtonOptions: return "View, Create or Share"
        case GCInputButtonHome: return "Home or Guide"
        case GCInputLeftThumbstickButton: return "Left stick click"
        case GCInputRightThumbstickButton: return "Right stick click"
        default: return element
        }
    }
}
