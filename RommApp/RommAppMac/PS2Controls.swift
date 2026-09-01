//  Cabinet's controllers, pointed at PCSX2.
//
//  GameControllerManager already owns pad pairing, two players,
//  bindings and haptics for every other core, and it is deliberately
//  not touched here: it publishes `send` and `sendStick` closures for
//  whoever is playing, so PS2 sets them the same way the native player
//  does and changes nothing about the manager itself. That matters
//  beyond tidiness, since any edit to that file owes a Smash TV
//  twin-stick pass on real hardware before it can be called done.
//
//  What crosses here is a translation, RetroPad to DualShock2. Cabinet
//  speaks RetroPad ids everywhere, including from the touch overlay and
//  the phone-as-controller wire, so doing the mapping here means PS2
//  inherits all of those for free rather than only Bluetooth pads.
//
//  The right stick reaches the game through GameControllerManager's
//  sendStick2, added for this and for the GameCube's C stick. The
//  manager's digitized twin-stick bits are untouched and still fire, so
//  nothing about FBNeo's arcade path changed.

import Foundation
import UIKit

enum PS2Controls {
    /// libretro's RetroPad ids, which are what Cabinet's `send` speaks.
    enum RetroPad {
        static let b = 0, y = 1, select = 2, start = 3
        static let up = 4, down = 5, left = 6, right = 7
        static let a = 8, x = 9, l = 10, r = 11
        static let l2 = 12, r2 = 13, l3 = 14, r3 = 15
    }

    /// RetroPad's face buttons are positional, not named after any one
    /// console: B is the bottom button, A the right, Y the left, X the
    /// top. On a DualShock2 that is Cross, Circle, Square, Triangle, so
    /// the pad in your hand matches the shape printed on it.
    private static let map: [Int: CabinetPS2Button] = [
        RetroPad.up: CabinetPS2Up,
        RetroPad.down: CabinetPS2Down,
        RetroPad.left: CabinetPS2Left,
        RetroPad.right: CabinetPS2Right,
        RetroPad.b: CabinetPS2Cross,
        RetroPad.a: CabinetPS2Circle,
        RetroPad.y: CabinetPS2Square,
        RetroPad.x: CabinetPS2Triangle,
        RetroPad.select: CabinetPS2Select,
        RetroPad.start: CabinetPS2Start,
        RetroPad.l: CabinetPS2L1,
        RetroPad.r: CabinetPS2R1,
        RetroPad.l2: CabinetPS2L2,
        RetroPad.r2: CabinetPS2R2,
        RetroPad.l3: CabinetPS2L3,
        RetroPad.r3: CabinetPS2R3,
    ]

    /// While the pause panel is up the pad drives the panel, not the
    /// game. Presses only, so a button still held from before the pause
    /// cannot activate a row on its way back up. Same rule as the
    /// native player's Mac menu.
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
        manager.activePlatform = "ps2"

        manager.send = { player, retroId, pressed in
            if menuIsOpen?() == true {
                if pressed { onMenuButton?(retroId) }
                return
            }
            guard let button = map[retroId] else { return }
            CabinetPS2SetButton(UInt32(player), button.rawValue, pressed ? 1 : 0)
        }

        manager.onMenu = onMenu
        // Nobody is holding anything after player one's pad drops, so
        // pause rather than let the game run on unattended. Player two
        // dropping leaves player one playing.
        manager.onDisconnect = { player in
            if player == 0 { onMenu() }
        }

        // A DualShock2 stick is four one-way values rather than two
        // signed axes, so each half of each axis is sent separately and
        // the unused half is explicitly zeroed. Skipping that zero
        // leaves the opposite direction stuck on at whatever it last
        // held, which reads in-game as drift that never centres.
        // A game being played is being watched, even while nothing
        // touches the keyboard or trackpad, which with a pad in hand is
        // the whole time.
        UIApplication.shared.isIdleTimerDisabled = true

        manager.sendStick = { player, x, y in
            let pad = UInt32(player)
            CabinetPS2SetButton(pad, CabinetPS2LeftStickRight.rawValue, max(0, x))
            CabinetPS2SetButton(pad, CabinetPS2LeftStickLeft.rawValue, max(0, -x))
            // sendStick's y is DOWN-positive. GameControllerManager flips
            // GameController's up-positive value at the publish point so
            // that everything downstream speaks libretro's convention,
            // and this is downstream.
            //
            // This used to be the other way round, under a comment
            // asserting that Cabinet's y was up-positive, which was true
            // of the pad but not of this closure. It was never caught
            // because nobody had played PS2 with a stick: the y flip and
            // this file were written two days apart and never met. The
            // same mistake, on the same axis, is written up twice in
            // CLAUDE.md.
            CabinetPS2SetButton(pad, CabinetPS2LeftStickUp.rawValue, max(0, -y))
            CabinetPS2SetButton(pad, CabinetPS2LeftStickDown.rawValue, max(0, y))
        }

        // The right stick, which had no path in at all: the manager only
        // digitized it into the arcade twin-stick bits, so a PS2 game
        // that aims with it saw four on/off directions at full
        // deflection. Twin-stick shooters and anything with a camera
        // need the real axis.
        manager.sendStick2 = { player, x, y in
            let pad = UInt32(player)
            CabinetPS2SetButton(pad, CabinetPS2RightStickRight.rawValue, max(0, x))
            CabinetPS2SetButton(pad, CabinetPS2RightStickLeft.rawValue, max(0, -x))
            CabinetPS2SetButton(pad, CabinetPS2RightStickUp.rawValue, max(0, -y))
            CabinetPS2SetButton(pad, CabinetPS2RightStickDown.rawValue, max(0, y))
        }
    }

    @MainActor
    static func detach() {
        let manager = GameControllerManager.shared
        manager.send = nil
        manager.sendStick = nil
        manager.sendStick2 = nil
        manager.onMenu = nil
        manager.onDisconnect = nil
        menuIsOpen = nil
        onMenuButton = nil
        manager.activePlatform = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
