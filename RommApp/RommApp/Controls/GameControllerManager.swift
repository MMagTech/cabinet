import Combine
import CoreHaptics
import GameController
import SwiftUI
import UIKit

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

    /// Local players. Two, deliberately: player 2 is Bluetooth only, there
    /// is no second-player touch layout, and no system here supports more
    /// than two on a single device in a way worth building for.
    static let maxPlayers = 2

    /// Everything that belongs to one player's controller. Kept per slot
    /// rather than as manager-wide fields so the two pads are genuinely
    /// independent: one disconnecting must not release the other's held
    /// buttons, and two different controller models each need their own
    /// bindings resolved from their own vendor name.
    /// The platform of the game currently running, or nil in the shell.
    /// Only the base binding map depends on it, and only N64 differs; the
    /// player sets it when a game starts so a controller connected mid
    /// game resolves the same way as one connected before it.
    var activePlatform: String? {
        didSet {
            guard activePlatform != oldValue else { return }
            let profile = ControllerBindings.profile(for: activePlatform)
            if digitizesLeftStickAsDPad != profile.digitizesLeftStick {
                digitizesLeftStickAsDPad = profile.digitizesLeftStick
                // Claims from the old mode must not survive into the new
                // one, or a direction the stick held on the way out stays
                // pressed with nothing left to release it.
                for (index, slot) in slots.enumerated() {
                    guard let slot else { continue }
                    for id in [RetroPad.left, RetroPad.right, RetroPad.down, RetroPad.up]
                    where slot.stickDown[id] == true {
                        setDirection(id, source: .stick, down: false, player: index)
                    }
                }
            }
            for (index, slot) in slots.enumerated() {
                guard let slot else { continue }
                // A held button must not straddle a rebind: its release
                // would resolve through the new map to a different id and
                // orphan the old press. Platform changes happen in the
                // shell, so there is nothing legitimate to keep held.
                releaseAll(player: index)
                // The same nil-vendorName fallback attach uses; skipping
                // instead left a nameless pad on the previous platform's
                // map forever (review finding, 2026-08-20).
                let name = slot.controller?.vendorName ?? slot.name ?? "unknown"
                slot.bindings = ControllerBindings.effective(for: name, platform: activePlatform)
            }
        }
    }

    private final class Slot {
        weak var controller: GCController?
        weak var pad: GCExtendedGamepad?
        var name: String?
        var bindings: [String: Int] = ControllerBindings.defaults
        var pressedInputs: Set<Int> = []
        var triggerDown: [String: Bool] = [:]
        /// Hysteresis state per digitized stick direction (RetroPad.up/
        /// down/left/right, or the second-stick ids 20-23), keyed by id.
        /// Same reason as `triggerDown`: a flat threshold with no gap
        /// chatters an axis resting near the boundary on and off. Also
        /// the stick's direction CLAIMS: see setDirection.
        var stickDown: [Int: Bool] = [:]
        /// The physical d-pad's direction claims: see setDirection.
        var dpadDown: Set<Int> = []
        var hapticEngines: [GCHapticsLocality: CHHapticEngine] = [:]
        var availableButtons: [String] = []
        /// Raw element names currently held, tracked independent of any
        /// RetroPad binding: the hotkey combo needs to know about L3/R3
        /// even though neither is bound to a game input by default.
        var heldElementNames: Set<String> = []
        /// True from the moment both hotkey buttons are down until either
        /// releases, so a held combo opens the menu once, not once per
        /// input event for as long as it stays held.
        var hotkeyArmed = false
    }

    private var started = false
    private var slots: [Slot?] = Array(repeating: nil, count: GameControllerManager.maxPlayers)

    /// Seats held by phone controllers, phoneID to slot index. Phones
    /// and pads share the same two seats under the same rule, first
    /// come and sticky: a pad connecting after a phone has joined must
    /// not silently demote the person already playing, and the other
    /// way round. Keyed by the phone's paired identity rather than a
    /// connection, so a phone that drops off Wi-Fi for two seconds
    /// comes back to the same port instead of swapping players
    /// mid-game. Empty whenever the phone-as-controller feature is not
    /// in use, which keeps every pad-only session on the exact
    /// behavior it always had.
    private var phoneClaims: [Data: Int] = [:]

    /// The seat this phone already holds, or the lowest one free of
    /// both pads and phone claims; nil when the house is full, which
    /// makes a third source simply not a player, exactly as a third
    /// gamepad behaves today.
    func claimPhoneSlot(for phoneID: Data) -> Int? {
        if let existing = phoneClaims[phoneID] { return existing }
        guard let free = slots.indices.first(where: { index in
            slots[index] == nil && !phoneClaims.values.contains(index)
        }) else { return nil }
        phoneClaims[phoneID] = free
        return free
    }

    /// A deliberate leave gives the seat back. A mere drop does not;
    /// that is the stickiness above.
    func releasePhoneSlot(for phoneID: Data) {
        phoneClaims[phoneID] = nil
    }

    /// The game ended; nobody is a phone player now.
    func releaseAllPhoneSlots() {
        phoneClaims.removeAll()
    }

    /// A controller is attached and driving the game. True when any slot is
    /// filled, so existing single-player callers keep their meaning.
    @Published private(set) var isConnected = false
    /// The attached controller's name, for showing which pad is in charge.
    /// Player 1's, since that is the pad every existing screen means.
    @Published private(set) var controllerName: String?
    /// Names by player slot, nil where no controller is attached, so a
    /// screen can show both players rather than only whoever connected
    /// first.
    @Published private(set) var connectedNames: [String?] = Array(repeating: nil, count: GameControllerManager.maxPlayers)
    /// Every button player 1's controller reports, by element name, so a
    /// remap screen can show what actually exists rather than what was
    /// assumed. Remapping stays a player-1 concern.
    @Published private(set) var availableButtons: [String] = []
    /// Set when a controller is paired but does not present a standard
    /// gamepad, which no app can drive and no remapping can rescue.
    @Published private(set) var unsupportedController: String?

    /// Sends a player slot, a RetroPad input id, and its state to the
    /// emulator. The slot is the core port for native play and the
    /// EmulatorJS player index for webview play; both count from 0.
    var send: ((Int, Int, Bool) -> Void)?
    /// A player's left stick position, x and y each -1 to 1, alongside the
    /// digitized d-pad bits `send` already carries: only Dreamcast and N64
    /// read this continuous form (RETRO_DEVICE_INDEX_ANALOG_LEFT), the rest
    /// simply never ask for it, so this fires unconditionally rather than
    /// needing to know per platform which cores want it. Was previously
    /// wired only from the touch overlay's stick, which is why a physical
    /// controller's left stick never drove N64 movement at all: N64 mostly
    /// ignores the digitized d-pad bits sent already, and needs the real
    /// analog value to move.
    var sendStick: ((Int, Float, Float) -> Void)?
    /// A player's RIGHT stick position, x and y each -1 to 1, alongside
    /// the digitized bits 20-23 `stick2` already sends.
    ///
    /// Those bits are all a twin-stick arcade cabinet needs, because its
    /// second stick is a digital joystick rather than an analog one, and
    /// for a long time arcade was the only thing reading that stick at
    /// all. A console's second stick is a real axis: PS2's right stick
    /// and the GameCube's C stick aim with it, and four on/off
    /// directions at full deflection is not aiming.
    ///
    /// The same shape and the same convention as `sendStick`, so a
    /// consumer that already handles one handles both.
    var sendStick2: ((Int, Float, Float) -> Void)?
    /// Whether the left stick also presses d-pad directions, as well as
    /// reporting its true analog value through `sendStick`.
    ///
    /// True everywhere by default, which is every consumer that existed
    /// before this flag: the webview player, and every native platform
    /// whose real controller has no analog stick, where the digitized
    /// bits are the only way a stick can move anything. Set false only
    /// for the platforms whose cores read the real analog value AND whose
    /// real controller carries a separate d-pad, since there one thumb
    /// would otherwise work two different physical controls at once. The
    /// Driven entirely by activePlatform through the platform profile
    /// table (ControllerBindings.profile(for:)); nothing else may write
    /// it, which is what keeps one platform's stick mode out of another's.
    private var digitizesLeftStickAsDPad = true
    /// Called when the pad's overlay button is pressed.
    var onMenu: (() -> Void)?
    /// Called when a controller disconnects mid game, so play can pause
    /// rather than continuing untouched while nobody is holding anything.
    /// Carries the slot that dropped: losing player 2's pad is a different
    /// event from losing player 1's, and saying "controller disconnected"
    /// for both reads as player 1's problem either way.
    var onDisconnect: ((Int) -> Void)?

    /// While set, presses are reported here instead of driving the game, so
    /// the remap screen can learn which physical button someone pressed.
    var captureHandler: ((String) -> Void)?

    private var observers: [NSObjectProtocol] = []

    var storageKey: String { controllerName ?? "unknown" }

    #if os(tvOS)
    /// Whether a running game owns the Menu button.
    ///
    /// tvOS gives Menu a system meaning (pop navigation, and at the root,
    /// leave the app). Binding it through GameController takes it away
    /// from the system for as long as the binding exists, and this
    /// manager's bindings are installed once and never torn down. So
    /// after playing a single game, Menu stopped popping anywhere in the
    /// app and quit outright instead: selecting a platform in the library
    /// and pressing Menu dropped you to the Apple TV home screen rather
    /// than back to the platform list.
    ///
    /// A game genuinely does want Menu (it is Start on most pads), so this
    /// is a gate rather than a removal: the player screen claims it on
    /// appear and gives it back on disappear. Everywhere else the system
    /// keeps it and back navigation works.
    var capturesMenuButton = false {
        didSet {
            guard capturesMenuButton != oldValue else { return }
            for (index, slot) in slots.enumerated() {
                guard let gamepad = slot?.controller?.extendedGamepad else { continue }
                bindMenuButton(gamepad, player: index)
            }
        }
    }
    #endif

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
        ) { [weak self] note in
            let controller = note.object as? GCController
            Task { @MainActor in self?.handleDisconnect(controller) }
        })

        // Connection order decides the slot, and every already-paired pad
        // is attached, not just the first: a controller connected before
        // the app launched is as much player 2 as one connected after.
        for existing in GCController.controllers() where !Self.isSimulatorPhantom(existing) {
            attach(existing)
        }
    }

    /// Rebuilds handlers after the remap screen changes a binding. Player 1
    /// only, matching where remapping is offered.
    func reloadBindings() {
        guard let controller = slots.first??.controller else { return }
        attach(controller)
    }

    // MARK: Wiring

    /// The iOS simulator always reports a synthetic controller named
    /// "Gamepad" even when nothing is attached to the Mac. Treating it as
    /// real suppresses the touch controls in every simulator run, which is
    /// exactly where they need to be testable. A real controller forwarded
    /// into the simulator arrives under its own vendor name, so filtering
    /// on this one name only hides the phantom. Device builds compile this
    /// check away entirely.
    private static func isSimulatorPhantom(_ controller: GCController) -> Bool {
        #if targetEnvironment(simulator)
        return controller.vendorName == "Gamepad"
        #else
        return false
        #endif
    }

    /// The slot a controller already occupies, or the lowest free one.
    /// Lowest-free is what makes slots stable across a disconnect: if
    /// player 1 drops, player 2 keeps slot 1 and stays player 2 rather
    /// than being silently promoted mid-game, and the next pad to connect
    /// takes the empty slot 0.
    private func slotIndex(for controller: GCController) -> Int? {
        if let existing = slots.firstIndex(where: { $0?.controller === controller }) {
            return existing
        }
        // Free means free of phones too. With no phone joined the
        // claims table is empty and this is the same lowest-free rule
        // it has always been.
        return slots.indices.first { slots[$0] == nil && !phoneClaims.values.contains($0) }
    }

    private func attach(_ controller: GCController) {
        guard !Self.isSimulatorPhantom(controller) else { return }
        guard let gamepad = controller.extendedGamepad else {
            // Paired and visible to iOS, but not as a standard gamepad. Say
            // so rather than appearing to see nothing at all, because the
            // two look identical from the outside and have different fixes.
            // The Siri Remote and other non-extended profiles land here on
            // purpose: nothing here is playable on them.
            unsupportedController = controller.vendorName ?? "This controller"
            return
        }
        // Every slot full: a third pad is simply not a player. Not an
        // error worth surfacing, there is nowhere for it to go.
        guard let index = slotIndex(for: controller) else { return }
        unsupportedController = nil

        let slot = slots[index] ?? Slot()
        slots[index] = slot
        slot.pad = gamepad
        slot.controller = controller
        slot.name = controller.vendorName
        slot.hapticEngines = [:]
        slot.bindings = ControllerBindings.effective(
            for: controller.vendorName ?? "unknown", platform: activePlatform)
        publishConnection()

        // Directions come from the d-pad and the left stick, always, with no
        // binding involved. They are never the thing that goes missing.
        gamepad.dpad.up.pressedChangedHandler = direction(RetroPad.up, player: index)
        gamepad.dpad.down.pressedChangedHandler = direction(RetroPad.down, player: index)
        gamepad.dpad.left.pressedChangedHandler = direction(RetroPad.left, player: index)
        gamepad.dpad.right.pressedChangedHandler = direction(RetroPad.right, player: index)
        // Handlers fire on the main queue (GCController's default
        // handlerQueue), so they call straight through. An earlier version
        // wrapped every edge, and every 120Hz stick sample, in its own
        // Task hop to the next main-actor scheduling point: a fresh
        // allocation and a runloop deferral per input, pure added latency
        // on the path where latency matters most.
        gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.stick(x: x, y: y, player: index) }
        }
        // A twin-stick arcade game's second joystick, ids 20-23, the same
        // ones the on-screen pad's own second stick already drives (see
        // ArcadeLayout.secondStick). Digital in, full deflection out,
        // matching every other source that reaches those ids: the real
        // cabinet's second stick is a joystick, not a true analog stick,
        // and both players' bridges treat it that way already. This was
        // simply never wired: only the click button existed before.
        // Safe per player now that each port owns its own mask: bits 20-23
        // of player 2's mask are player 2's own right stick, and cannot
        // alias onto the twin-stick bits FBNeo reads from player 1.
        gamepad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated { self?.stick2(x: x, y: y, player: index) }
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


        for (name, button) in candidates {
            // Triggers report analog values and need a threshold; everything
            // else is a clean pressed change. Reading isAnalog rather than
            // assuming, since some pads report pressure on face buttons.
            if button.isAnalog {
                button.valueChangedHandler = { [weak self] _, value, _ in
                    MainActor.assumeIsolated { self?.analog(name, value: value, player: index) }
                }
            } else {
                button.pressedChangedHandler = { [weak self] _, _, pressed in
                    MainActor.assumeIsolated { self?.button(name, pressed: pressed, player: index) }
                }
            }
        }
        // Menu is bound separately, through the helper below, because on
        // tvOS whether this app should own it at all depends on whether a
        // game is running. Still advertised as available either way, so
        // the remap screen can offer it.
        bindMenuButton(gamepad, player: index)
        slot.availableButtons = candidates.map(\.0) + [GCInputButtonMenu]
        if index == 0 { availableButtons = slot.availableButtons }
    }

    /// Installs, or on tvOS deliberately withholds, the Menu button handler.
    ///
    /// On iOS this is unconditional and behaves exactly as it always has.
    /// On tvOS the handler only goes on while a game is running: see
    /// `capturesMenuButton` for why holding it the rest of the time broke
    /// back navigation everywhere in the app.
    private func bindMenuButton(_ gamepad: GCExtendedGamepad, player index: Int) {
        #if os(tvOS)
        guard capturesMenuButton else {
            gamepad.buttonMenu.pressedChangedHandler = nil
            return
        }
        #endif
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                self?.button(GCInputButtonMenu, pressed: pressed, player: index)
            }
        }
    }

    /// A physical button changed. In capture mode it names itself for the
    /// remap screen; otherwise it drives whatever it is bound to.
    /// Capture is a player-1 concern: the remap screen is reached from
    /// Settings and always means "the pad I am holding", so a stray press
    /// on player 2's pad must not hijack what is being learned.
    private func button(_ name: String, pressed: Bool, player: Int) {
        // Tracked even while capturing or unbound: the hotkey combo is
        // independent of the ordinary bindings table, and needs to know
        // about a press regardless of what else is happening with it.
        updateHotkeyState(name: name, pressed: pressed, player: player)

        if let capture = captureHandler {
            if pressed, player == 0 { capture(name) }
            return
        }
        guard let slot = slots[player], let id = slot.bindings[name] else { return }

        // The overlay is not a game input, so it fires on press and is never
        // forwarded to the emulator. Either player can open the menu: both
        // are sitting in front of the same screen.
        if id == RetroPad.overlay {
            if pressed { onMenu?() }
            return
        }
        emit(id, pressed, player: player)
    }

    /// The pause menu's second door, alongside whatever single button is
    /// bound to `RetroPad.overlay`. Fires on the edge into "both held", not
    /// on every event while they stay down, and rearms only once either
    /// releases, so a sustained hold cannot reopen a just-closed menu.
    /// Runs even mid-capture and for otherwise-unbound buttons, since L3/R3
    /// carry no ordinary binding by default and the two must be tracked
    /// regardless of what capture or the bindings table are doing.
    private func updateHotkeyState(name: String, pressed: Bool, player: Int) {
        guard let slot = slots[player] else { return }
        if pressed {
            slot.heldElementNames.insert(name)
        } else {
            slot.heldElementNames.remove(name)
            slot.hotkeyArmed = false
        }
        // buttonB nil means single-button mode: buttonA alone is enough.
        let armedCondition = slot.heldElementNames.contains(MenuHotkey.buttonA)
            && (MenuHotkey.buttonB.map { slot.heldElementNames.contains($0) } ?? true)
        guard armedCondition, !slot.hotkeyArmed, captureHandler == nil else { return }
        slot.hotkeyArmed = true
        onMenu?()
    }

    /// Analog buttons, meaning triggers, need a threshold with hysteresis or
    /// a resting finger chatters the input on and off.
    private func analog(_ name: String, value: Float, player: Int) {
        guard let slot = slots[player] else { return }
        let wasDown = slot.triggerDown[name] ?? false
        let isDown = wasDown ? value > 0.25 : value > 0.35
        guard isDown != wasDown else { return }
        slot.triggerDown[name] = isDown
        button(name, pressed: isDown, player: player)
    }

    /// Which input surface is claiming a direction. A direction reaches
    /// the game while ANY source holds it, and a source releasing its
    /// claim can never release another source's: the physical d-pad and
    /// the digitized stick are different thumbs on different physical
    /// controls, and one path dropping the other's press is exactly how
    /// the left stick died on arcade (2026-08-20, the pollNow
    /// experiment's per-frame d-pad reads clearing stick-held
    /// directions). Any future writer of direction ids must claim
    /// through here under its own source.
    private enum DirectionSource { case dpad, stick }

    private func setDirection(_ id: Int, source: DirectionSource, down: Bool, player: Int) {
        guard let slot = slots[player] else { return }
        let wasDown = slot.dpadDown.contains(id) || slot.stickDown[id] == true
        switch source {
        case .dpad:
            if down { slot.dpadDown.insert(id) } else { slot.dpadDown.remove(id) }
        case .stick:
            slot.stickDown[id] = down
        }
        let nowDown = slot.dpadDown.contains(id) || slot.stickDown[id] == true
        if nowDown != wasDown {
            emit(id, nowDown, player: player)
        }
    }

#if DEBUG
    /// Test seam for tools/controls-test: drives the exact internal paths
    /// a physical pad does, so the direction state machines run on the
    /// Mac without hardware. A slot is created on demand because no
    /// GCController ever connects in the harness. Debug builds only.
    func _testInjectDpad(_ id: Int, down: Bool, player: Int = 0) {
        ensureTestSlot(player)
        setDirection(id, source: .dpad, down: down, player: player)
    }
    func _testInjectStick(x: Float, y: Float, player: Int = 0) {
        ensureTestSlot(player)
        stick(x: x, y: y, player: player)
    }
    func _testInjectStick2(x: Float, y: Float, player: Int = 0) {
        ensureTestSlot(player)
        stick2(x: x, y: y, player: player)
    }
    private func ensureTestSlot(_ player: Int) {
        if slots[player] == nil { slots[player] = Slot() }
    }
#endif

    private func direction(_ id: Int, player: Int) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard self?.captureHandler == nil else { return }
                self?.setDirection(id, source: .dpad, down: pressed, player: player)
            }
        }
    }

    private func stick(x: Float, y: Float, player: Int) {
        guard let slot = slots[player], captureHandler == nil else { return }
        // The left stick reaches a game by two separate routes, and on a
        // console whose real controller has BOTH a d-pad and an analog
        // stick, sending both routes at once presses two different
        // physical controls from one thumb. Dreamcast's Rush 2049 steers
        // on the analog stick and swings the camera on the d-pad, so
        // pushing right did both at once (reported on device 2026-08-16).
        //
        // Suppressed only where the core reads the true analog value, and
        // only for this stick. Everything about the second stick (stick2,
        // ids 20-23) and about platforms without an analog stick is
        // untouched: FBNeo's arcade movement has no path in other than
        // this digitizing, which is exactly what cabinet#3 was about.
        if digitizesLeftStickAsDPad {
            digitizeAxis(RetroPad.left, magnitude: max(0, -x), slot: slot, player: player)
            digitizeAxis(RetroPad.right, magnitude: max(0, x), slot: slot, player: player)
            digitizeAxis(RetroPad.down, magnitude: max(0, -y), slot: slot, player: player)
            digitizeAxis(RetroPad.up, magnitude: max(0, y), slot: slot, player: player)
        } else {
            // Any direction still held from before the mode changed has to
            // be released, or it stays pressed forever with nothing left
            // to clear it.
            for id in [RetroPad.left, RetroPad.right, RetroPad.down, RetroPad.up]
            where slot.stickDown[id] == true {
                setDirection(id, source: .stick, down: false, player: player)
            }
        }
        // The y flip is the convention seam, and this is the one place it
        // belongs: GameController reports the stick up-positive (the
        // digitizing above depends on that and stays raw), while
        // everything downstream of sendStick speaks libretro's
        // down-positive, the convention the touch stick already sends and
        // the frontend's analog channel documents. Unflipped, every core
        // that reads the true analog value saw a pad's vertical axis
        // mirrored: Dreamcast, N64 and PSP, hidden for weeks because the
        // verified games steered or strafed on x, and found the first
        // evening a 3D platformer was walked with a Bluetooth pad
        // (Sonic Adventure, 2026-08-29). The FBNeo refusal in
        // LibretroFrontend.inputState already documented the mismatch
        // ("GameController y is up-positive, opposite libretro's
        // convention on this path") without fixing the path for the
        // cores that legitimately read it.
        sendStick?(player, x, -y)
    }

    /// Same digitizing as the left stick, ids 23/22/21/20 (up/down/left/
    /// right) instead of the standard RetroPad directions: see
    /// ArcadeLayout.secondStick for why those specific numbers and where
    /// they lead downstream in each player.
    private func stick2(x: Float, y: Float, player: Int) {
        guard let slot = slots[player], captureHandler == nil else { return }
        digitizeAxis(21, magnitude: max(0, -x), slot: slot, player: player)
        digitizeAxis(20, magnitude: max(0, x), slot: slot, player: player)
        digitizeAxis(22, magnitude: max(0, -y), slot: slot, player: player)
        digitizeAxis(23, magnitude: max(0, y), slot: slot, player: player)
        // Additive, exactly as sendStick is for the left stick: the four
        // digitized bits above are untouched and still fire first, so
        // FBNeo's twin-stick path runs the same code in the same order
        // it did before this line existed. Nothing consumes sendStick2
        // unless it sets it, and only PS2 and GameCube do.
        //
        // Same y flip as sendStick, and for the same reason: everything
        // downstream of these publishers speaks libretro's down-positive
        // convention, while GameController reports up-positive and the
        // digitizing above depends on the raw sign.
        sendStick2?(player, x, -y)
    }

    /// Turns one direction's stick deflection into a digital press, the
    /// same hysteresis shape as `analog(_:value:player:)` above: engage at
    /// 0.5, release only below 0.4. A flat single threshold, what this
    /// replaced, let a stick resting right on the boundary during play
    /// chatter the direction on and off, which read on real hardware as
    /// "the character doesn't go where I'm telling it" on FBNeo's arcade
    /// games specifically, the one native platform whose movement has no
    /// other path in: N64 and Dreamcast read the raw analog value instead
    /// (see `sendStick`) and never hit this digitizing at all, which is
    /// why they were never affected. Found and fixed 2026-08-15.
    private func digitizeAxis(_ id: Int, magnitude: Float, slot: Slot, player: Int) {
        let wasDown = slot.stickDown[id] ?? false
        let isDown = wasDown ? magnitude > 0.4 : magnitude > 0.5
        guard isDown != wasDown else { return }
        setDirection(id, source: .stick, down: isDown, player: player)
    }

    /// Routes an input to the game, edges only: the stick handler above
    /// fires per sample, up to 120 a second, and most samples change no
    /// direction. Sending only on change keeps a held stick from
    /// streaming identical evaluateJavaScript calls into the webview.
    private func emit(_ id: Int, _ down: Bool, player: Int) {
        guard let slot = slots[player] else { return }
        if down {
            guard slot.pressedInputs.insert(id).inserted else { return }
        } else {
            guard slot.pressedInputs.remove(id) != nil else { return }
        }
        send?(player, id, down)
    }

    /// Frees only the slot whose controller actually went away, so losing
    /// one pad leaves the other player untouched and still in their own
    /// slot. GameController does not tell us which slot, only which
    /// controller, hence the identity match.
    private func handleDisconnect(_ controller: GCController?) {
        guard let index = slots.firstIndex(where: { slot in
            guard let slot else { return false }
            if let controller { return slot.controller === controller }
            // No controller on the notification: fall back to whichever
            // slot's pad has since gone nil.
            return slot.controller == nil
        }) else { return }

        releaseAll(player: index)
        slots[index] = nil
        publishConnection()
        onDisconnect?(index)
    }

    /// Mirrors slot state onto the published properties every existing
    /// screen already reads.
    private func publishConnection() {
        isConnected = slots.contains { $0 != nil }
        controllerName = slots.first??.name
        connectedNames = slots.map { $0?.name }
        if slots[0] == nil { availableButtons = [] }
    }

    // MARK: Rumble

    /// Routes a core's rumble event to the connected controller's own motor
    /// when there is one, falling back to the phone's Taptic Engine when
    /// there is not (no controller connected, or its haptics setup fails).
    /// `GCExtendedGamepad` carries no haptics API, only the owning
    /// `GCController` does, which is why this needs `controller` kept
    /// alongside `pad` rather than reusing what button handling already has.
    /// Called from LibretroFrontend's rumble callback via the handler block
    /// wired in RommApp.swift at launch, already hopped to the main thread
    /// there since CHHapticEngine and UIImpactFeedbackGenerator both need it.
    func fireRumble(port: Int, strong: Bool, strength: UInt16) {
        let intensity = Float(strength) / Float(UInt16.max)
        guard intensity > 0 else { return }
        guard slots.indices.contains(port) else { return }
        guard let slot = slots[port], let controller = slot.controller,
              let haptics = controller.haptics,
              let engine = hapticEngine(from: haptics, slot: slot)
        else {
            // A companion phone holding this seat IS this player's
            // controller, so its own Taptic Engine is the motor to
            // knock. Checked here, in the branch that already means
            // "no real controller on this port", so a pad with
            // haptics never reaches it and nothing about the existing
            // path changes. It matters most on tvOS, where the
            // fallback below is compiled out entirely and a phone
            // player therefore felt nothing at all.
            if phoneClaims.values.contains(port) {
                GameControllerManager.companionRumble?(port, strong, strength)
                return
            }
            // The phone is player 1's device, so only player 1's rumble
            // falls back to it. Buzzing the handset for player 2's pad
            // would be felt by the wrong person entirely.
            if port == 0 { firePhoneHaptic(strong: strong) }
            return
        }
        do {
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: strong ? 1.0 : 0.3),
            ], relativeTime: 0)
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            if port == 0 { firePhoneHaptic(strong: strong) }
        }
    }

    /// Connects a core's rumble events to whoever should feel them, and
    /// makes the on-by-default setting actually read as on.
    ///
    /// Shared, and called from both apps' launch, because it used to live in
    /// the iOS app delegate, which tvOS does not compile. So tvOS did
    /// neither of these, and rumble could not work there twice over: the
    /// setting read as off, since `boolForKey:` on a key nobody registered
    /// returns Foundation's false rather than this app's true, and even past
    /// that the handler was nil, and the fallback for a nil handler is a
    /// phone haptic an Apple TV does not have. Nothing on tvOS ever rumbled,
    /// and nothing said so.
    /// Where a companion phone's rumble goes, set by whichever screen
    /// currently owns the phone link and cleared when it lets go.
    /// Shaped like LibretroFrontend's own rumble handler and for the
    /// same reason: this file knows a phone holds a seat, but not
    /// which link is carrying it.
    nonisolated(unsafe) static var companionRumble: ((Int, Bool, UInt16) -> Void)?

    static func installRumbleRouting() {
        UserDefaults.standard.register(defaults: ["com.mmagtech.RommApp.rumbleEnabled": true])
        LibretroFrontend.setRumbleHandler { port, strong, strength in
            GameControllerManager.shared.fireRumble(port: port, strong: strong, strength: strength)
        }
    }

    /// One engine per locality, kept alive rather than rebuilt per rumble
    /// event: `CHHapticEngine.start()` is cheap to call again on an already
    /// running engine, but creating a fresh one every haptic is not free,
    /// and this can fire many times a second during a sustained effect.
    private func hapticEngine(from haptics: GCDeviceHaptics, slot: Slot) -> CHHapticEngine? {
        if let existing = slot.hapticEngines[.default] { return existing }
        guard let engine = haptics.createEngine(withLocality: .default) else { return nil }
        slot.hapticEngines[.default] = engine
        return engine
    }

    private func firePhoneHaptic(strong: Bool) {
        // No phone to fall back to on tvOS; a rumble that misses every
        // connected controller's own haptics is simply dropped there.
        #if !os(tvOS)
        let generator = UIImpactFeedbackGenerator(style: strong ? .heavy : .light)
        generator.impactOccurred()
        #endif
    }

    /// Drops every input on disconnect, or a direction held at the moment the
    /// pad died would stay held forever.
    private func releaseAll(player: Int) {
        guard let slot = slots[player] else { return }
        for id in slot.pressedInputs { send?(player, id, false) }
        slot.pressedInputs.removeAll()
        slot.triggerDown.removeAll()
        slot.stickDown.removeAll()
        slot.dpadDown.removeAll()
        slot.hapticEngines = [:]
    }

    // MARK: Remapping

    /// Remapping edits player 1's pad, the one whoever opened Settings is
    /// holding. Player 2's bindings still resolve from their own vendor
    /// name, so a different model in slot 2 keeps its correct defaults.
    private var player1Bindings: [String: Int] {
        get { slots[0]?.bindings ?? ControllerBindings.defaults }
        set { slots[0]?.bindings = newValue }
    }

    /// The element name currently bound to an input, if any.
    func boundButton(for id: Int) -> String? {
        player1Bindings.first { $0.value == id }?.key
    }

    /// The input a physical button currently drives, if any.
    func bindings(for name: String) -> Int? {
        player1Bindings[name]
    }

    /// Points a physical button at an input, clearing whatever else claimed
    /// either side so one press can never fire two inputs.
    func bind(button name: String, to id: Int) {
        player1Bindings = player1Bindings.filter { $0.key != name && $0.value != id }
        player1Bindings[name] = id
        ControllerBindings.save(player1Bindings, for: storageKey)
        reloadBindings()
    }

    /// Replaces the whole map at once, which is what choosing a preset means.
    func applyBindings(_ map: [String: Int]) {
        player1Bindings = map
        ControllerBindings.save(map, for: storageKey)
        reloadBindings()
    }

    /// Whether the current map is exactly this one, so the preset rows can
    /// show which arrangement is in effect and neither once it is edited.
    func matchesBindings(_ map: [String: Int]) -> Bool {
        player1Bindings == map
    }

    /// Whether the two face buttons currently read by their labels
    /// rather than by their positions.
    ///
    /// Cabinet binds positionally by default: the bottom face button
    /// drives RetroPad B and the right one drives RetroPad A, which is
    /// where those inputs physically sat on the consoles being
    /// emulated. Plenty of people read the letters instead, and on a
    /// Nintendo-style pad the letters are already the other way round
    /// from an Xbox one, so the same physical thumb movement means two
    /// different things depending on which pad is in hand. Swapped
    /// means A drives A and B drives B.
    var faceButtonsSwapped: Bool {
        player1Bindings[GCInputButtonA] == RetroPad.a
            && player1Bindings[GCInputButtonB] == RetroPad.b
    }

    /// Exchanges what the two face buttons send, leaving every other
    /// binding, including any the player set by hand, exactly as it is.
    func swapFaceButtons() {
        var map = player1Bindings
        let a = map[GCInputButtonA]
        let b = map[GCInputButtonB]
        map[GCInputButtonA] = b
        map[GCInputButtonB] = a
        applyBindings(map)
    }

    func clearBinding(for id: Int) {
        player1Bindings = player1Bindings.filter { $0.value != id }
        ControllerBindings.save(player1Bindings, for: storageKey)
        reloadBindings()
    }

    func resetBindings() {
        ControllerBindings.reset(for: storageKey)
        player1Bindings = ControllerBindings.defaults
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
