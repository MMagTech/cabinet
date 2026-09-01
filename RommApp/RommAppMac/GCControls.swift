//  Cabinet's controllers, pointed at Dolphin.
//
//  GameControllerManager already owns pad pairing, two players,
//  bindings and haptics for every other core, and it is deliberately
//  not touched here: it publishes `send` and `sendStick` closures for
//  whoever is playing, so GameCube sets them the same way PS2 and the
//  native player do and changes nothing about the manager itself. That
//  matters beyond tidiness, since any edit to that file owes a Smash TV
//  twin-stick pass on real hardware before it can be called done.
//
//  What crosses here is a translation, RetroPad to GameCube. Cabinet
//  speaks RetroPad ids everywhere, including from the touch overlay and
//  the phone-as-controller wire, so doing the mapping here means
//  GameCube inherits all of those for free rather than only Bluetooth
//  pads.
//
//  Unlike the other cores this one keeps a whole pad state rather than
//  sending button events, because Dolphin asks the host for the state
//  of the port once per frame rather than being told about changes.
//  That is the emulated hardware's own shape: a GameCube controller is
//  polled.
//
//  KNOWN GAP, the same one PS2 has: the C stick. GameControllerManager
//  digitises the right stick into arcade-specific bits rather than
//  publishing it as an axis, so the C stick is only reachable through
//  the four digital directions below. A 3D game that aims with it will
//  feel stepped rather than smooth until that manager grows a real
//  right-stick axis, which is deliberately not being changed here.

import Foundation
import UIKit

enum GCControls {
    /// libretro's RetroPad ids, which are what Cabinet's `send` speaks.
    enum RetroPad {
        static let b = 0, y = 1, select = 2, start = 3
        static let up = 4, down = 5, left = 6, right = 7
        static let a = 8, x = 9, l = 10, r = 11
        static let l2 = 12, r2 = 13, l3 = 14, r3 = 15
    }

    /// RetroPad's face buttons are positional, not named after any one
    /// console: B is the bottom button, A the right, Y the left, X the
    /// top.
    ///
    /// The GameCube's are positional too, but not in the same
    /// arrangement: its A is a big centre button with B below-left, and
    /// X and Y are kidney-shaped buttons around them. Mapping by
    /// POSITION rather than by letter is what makes a modern pad feel
    /// right: the bottom button is A, because on a GameCube pad A is
    /// the one your thumb rests on, and that is what a person reaches
    /// for when a game says "press A".

    /// Named one per line rather than converted inline in the dictionary
    /// below. Twelve `UInt16(SOMETHING.rawValue)` conversions inside one
    /// literal is more than Swift's type checker will attempt, and it
    /// gives up with "unable to type-check this expression in reasonable
    /// time" rather than anything that points at the cause.
    private enum GCBit {
        static let up = UInt16(CABINET_GC_DPAD_UP)
        static let down = UInt16(CABINET_GC_DPAD_DOWN)
        static let left = UInt16(CABINET_GC_DPAD_LEFT)
        static let right = UInt16(CABINET_GC_DPAD_RIGHT)
        static let a = UInt16(CABINET_GC_BUTTON_A)
        static let b = UInt16(CABINET_GC_BUTTON_B)
        static let x = UInt16(CABINET_GC_BUTTON_X)
        static let y = UInt16(CABINET_GC_BUTTON_Y)
        static let start = UInt16(CABINET_GC_BUTTON_START)
        static let l = UInt16(CABINET_GC_TRIGGER_L)
        static let r = UInt16(CABINET_GC_TRIGGER_R)
        static let z = UInt16(CABINET_GC_TRIGGER_Z)
    }

    private static let map: [Int: UInt16] = [
        RetroPad.up: GCBit.up,
        RetroPad.down: GCBit.down,
        RetroPad.left: GCBit.left,
        RetroPad.right: GCBit.right,
        RetroPad.b: GCBit.a,
        RetroPad.a: GCBit.b,
        RetroPad.y: GCBit.x,
        RetroPad.x: GCBit.y,
        RetroPad.start: GCBit.start,
        RetroPad.l: GCBit.l,
        RetroPad.r: GCBit.r,
        RetroPad.r2: GCBit.z,
    ]

    /// The GameCube has no Select. RetroPad's select is left unmapped
    /// on purpose rather than doubled onto Start: a pad with two
    /// buttons that both pause is worse than one that does nothing.

    /// Held state per port, rebuilt into a CabinetDolphinPad on every
    /// change. Four ports because the console has four, even though
    /// GameControllerManager only pairs two today.
    private static var pads = [Pad(), Pad(), Pad(), Pad()]

    private struct Pad {
        var buttons: UInt16 = 0
        var stickX: UInt8 = 128
        var stickY: UInt8 = 128
        var substickX: UInt8 = 128
        var substickY: UInt8 = 128
        var triggerL: UInt8 = 0
        var triggerR: UInt8 = 0
    }

    /// While the pause panel is up the pad drives the panel, not the
    /// game. Presses only, so a button still held from before the pause
    /// cannot activate a row on its way back up. Same rule as PS2 and
    /// the native player's Mac menu.
    @MainActor static var menuIsOpen: (() -> Bool)?
    @MainActor static var onMenuButton: ((Int) -> Void)?

    @MainActor
    static func attach(onMenu: @escaping () -> Void) {
        let manager = GameControllerManager.shared

        // Not optional, and the reason is written into the native
        // player's own copy of this line: the manager only subscribes
        // to GCController connect and disconnect notifications once
        // started, and it is normally started by Settings or the remap
        // screen. A launch that goes straight into a game without
        // visiting either leaves every pad silent. Idempotent.
        manager.start()
        manager.activePlatform = "ngc"
        // Whether the stick also presses d-pad directions is resolved
        // from activePlatform above, in ControllerBindings.profile, which
        // is where every other platform's answer already lives.

        pads = [Pad(), Pad(), Pad(), Pad()]
        push(0)

        manager.send = { player, retroId, pressed in
            if menuIsOpen?() == true {
                if pressed { onMenuButton?(retroId) }
                return
            }
            guard player >= 0, player < 4, let bit = map[retroId] else { return }
            if pressed {
                pads[player].buttons |= bit
            } else {
                pads[player].buttons &= ~bit
            }
            // The shoulders are analog on real hardware and a lot of
            // games read the axis rather than the click, so a digital
            // press is sent as both: fully pressed on the axis and the
            // button bit set. Half-pressing is not reachable from a
            // digital pad and no game requires it.
            if bit == GCBit.l {
                pads[player].triggerL = pressed ? 255 : 0
            }
            if bit == GCBit.r {
                pads[player].triggerR = pressed ? 255 : 0
            }
            push(player)
        }

        manager.onMenu = onMenu
        // Nobody is holding anything after player one's pad drops, so
        // pause rather than let the game run on unattended. Player two
        // dropping leaves player one playing.
        manager.onDisconnect = { player in
            if player == 0 { onMenu() }
        }

        // A game being played is being watched, even while nothing
        // touches the keyboard or trackpad, which with a pad in hand is
        // the whole time.
        UIApplication.shared.isIdleTimerDisabled = true

        manager.sendStick = { player, x, y in
            guard player >= 0, player < 4 else { return }
            pads[player].stickX = axis(x)
            // Cabinet's y is positive up, matching libretro, and so is
            // the GameCube's: 255 is up. No inversion here, and that is
            // checked rather than assumed, because getting it wrong is
            // exactly the class of bug that cost this project a
            // twin-stick regression before.
            pads[player].stickY = axis(y)
            push(player)
        }
    }

    /// Cabinet's sticks are floats from -1 to 1; the GameCube's are 0 to
    /// 255 around a centre of 128.
    private static func axis(_ value: Float) -> UInt8 {
        let clamped = max(-1, min(1, value))
        let scaled = Int((clamped * 127).rounded()) + 128
        return UInt8(max(0, min(255, scaled)))
    }

    private static func push(_ player: Int) {
        let pad = pads[player]
        var out = CabinetDolphinPad(
            buttons: pad.buttons,
            stick_x: pad.stickX,
            stick_y: pad.stickY,
            substick_x: pad.substickX,
            substick_y: pad.substickY,
            trigger_left: pad.triggerL,
            trigger_right: pad.triggerR,
            connected: true
        )
        CabinetDolphinSetPad(Int32(player), &out)
    }

    @MainActor
    static func detach() {
        let manager = GameControllerManager.shared
        manager.send = nil
        manager.sendStick = nil
        manager.onMenu = nil
        manager.onDisconnect = nil
        menuIsOpen = nil
        onMenuButton = nil
        manager.activePlatform = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
