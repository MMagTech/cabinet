import Combine
import GameController
import SwiftUI

/// Physical controllers, captured natively with GameController rather than
/// the webview's Gamepad API, per the scope doc. The web side is suppressed
/// separately in the player injection, or every press would register twice.
///
/// Buttons map positionally onto RetroPad ids, which is what the cores expect
/// and what makes the arcade six button fold fall out for free: on any modern
/// pad the left and top face buttons plus the left bumper become punches, and
/// the bottom and right face buttons plus the right bumper become kicks,
/// exactly the CPS row order the touch layout draws.
@MainActor
final class GameControllerManager: ObservableObject {
    /// A controller is attached and driving the game.
    @Published private(set) var isConnected = false
    /// The attached controller's name, for showing which pad is in charge.
    @Published private(set) var controllerName: String?
    /// Inputs currently held, so a test screen can show what the app sees.
    @Published private(set) var pressedInputs: Set<Int> = []

    /// Sends a RetroPad input id and its state to the emulator.
    var send: ((Int, Bool) -> Void)?
    /// Called when the pad's menu button is pressed.
    var onMenu: (() -> Void)?
    /// Called when a controller disconnects mid game, so play can pause
    /// rather than continuing untouched while nobody is holding anything.
    var onDisconnect: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    /// Trigger states, kept so hysteresis has something to compare against.
    private var triggerDown: [Int: Bool] = [:]

    // RetroPad ids. Confirmed against the EmulatorJS 4.2.3 bundle and the
    // standard libretro joypad ordering.
    enum Pad {
        static let b = 0, y = 1, select = 2, start = 3
        static let up = 4, down = 5, left = 6, right = 7
        static let a = 8, x = 9, l = 10, r = 11
        static let l2 = 12, r2 = 13

        /// What each id does in game, for the test screen. Names describe the
        /// emulator's input, not any particular pad's printing.
        static let names: [(id: Int, label: String)] = [
            (up, "Up"), (down, "Down"), (left, "Left"), (right, "Right"),
            (b, "B, arcade button 4"), (a, "A, arcade button 5"),
            (y, "Y, arcade button 1"), (x, "X, arcade button 2"),
            (l, "L, arcade button 3"), (r, "R, arcade button 6"),
            (l2, "L2 trigger"), (r2, "R2 trigger"),
            (select, "Select, arcade Coin"), (start, "Start"),
        ]
    }

    /// Routes an input to the game and to anything watching for diagnostics.
    private func emit(_ id: Int, _ down: Bool) {
        if down { pressedInputs.insert(id) } else { pressedInputs.remove(id) }
        send?(id, down)
    }

    func start() {
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

        // A pad may already be paired before the player opens.
        if let existing = GCController.controllers().first {
            attach(existing)
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        releaseAll()
    }

    // MARK: Wiring

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }

        isConnected = true
        controllerName = controller.vendorName

        pad.dpad.up.pressedChangedHandler = handler(Pad.up)
        pad.dpad.down.pressedChangedHandler = handler(Pad.down)
        pad.dpad.left.pressedChangedHandler = handler(Pad.left)
        pad.dpad.right.pressedChangedHandler = handler(Pad.right)

        // The left stick drives the same digital directions, so stick players
        // and d-pad players both work without a setting.
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in
                self?.stick(x: x, y: y)
            }
        }

        // Positional face buttons. buttonA is the bottom button on every pad,
        // which is RetroPad B, and so on around the diamond.
        pad.buttonA.pressedChangedHandler = handler(Pad.b)
        pad.buttonB.pressedChangedHandler = handler(Pad.a)
        pad.buttonX.pressedChangedHandler = handler(Pad.y)
        pad.buttonY.pressedChangedHandler = handler(Pad.x)

        pad.leftShoulder.pressedChangedHandler = handler(Pad.l)
        pad.rightShoulder.pressedChangedHandler = handler(Pad.r)

        // Analog triggers need a threshold with hysteresis, or a thumb resting
        // near the edge chatters the input on and off.
        pad.leftTrigger.valueChangedHandler = { [weak self] _, value, _ in
            Task { @MainActor in self?.trigger(Pad.l2, value: value) }
        }
        pad.rightTrigger.valueChangedHandler = { [weak self] _, value, _ in
            Task { @MainActor in self?.trigger(Pad.r2, value: value) }
        }

        pad.buttonOptions?.pressedChangedHandler = handler(Pad.select)
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in self?.onMenu?() }
        }
        // Start lives on the right shoulder cluster of arcade sticks and on
        // buttonMenu of gamepads, so honour both: the menu button opens the
        // pause menu, and the home button, when present, sends Start.
        pad.buttonHome?.pressedChangedHandler = handler(Pad.start)
    }

    private func handler(_ id: Int) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            Task { @MainActor in self?.emit(id, pressed) }
        }
    }

    /// Digital directions from an analog stick, with a dead zone so a resting
    /// thumb does not creep.
    private func stick(x: Float, y: Float) {
        let threshold: Float = 0.5
        emit(Pad.left, x < -threshold)
        emit(Pad.right, x > threshold)
        emit(Pad.down, y < -threshold)
        emit(Pad.up, y > threshold)
    }

    /// Presses past 0.35 and releases below 0.25, so the band between them
    /// holds whatever state the trigger was already in.
    private func trigger(_ id: Int, value: Float) {
        let wasDown = triggerDown[id] ?? false
        let isDown = wasDown ? value > 0.25 : value > 0.35
        guard isDown != wasDown else { return }
        triggerDown[id] = isDown
        emit(id, isDown)
    }

    private func handleDisconnect() {
        guard GCController.controllers().isEmpty else { return }
        releaseAll()
        isConnected = false
        controllerName = nil
        onDisconnect?()
    }

    /// Drops every input on disconnect, or a direction held at the moment the
    /// pad died would stay held forever.
    private func releaseAll() {
        for id in [
            Pad.b, Pad.y, Pad.select, Pad.start, Pad.up, Pad.down, Pad.left,
            Pad.right, Pad.a, Pad.x, Pad.l, Pad.r, Pad.l2, Pad.r2,
        ] {
            emit(id, false)
        }
        triggerDown.removeAll()
    }
}
