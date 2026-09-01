import GameController

/// Which physical button drives which emulator input, per controller.
///
/// Six arcade buttons have to land somewhere on a pad with four face
/// buttons, and the scope doc calls the fold required, not optional. Two
/// arrangements ship. The default puts the heavies on the right side, HP on
/// RB and HK on RT, which is how every console Street Fighter port maps a
/// pad and what most people's hands already know. The variant puts the
/// heavies on the two bumpers instead, for pads whose triggers travel too
/// far to tap in a combo. Defaults are only a starting point: compact pads
/// often expose no Options button at all, which would otherwise leave Coin
/// unreachable and an arcade game unplayable. Anything can be rebound, and
/// choices are remembered per controller model.
enum ControllerBindings {
    /// GameController element name to RetroPad id. The scope doc's fold:
    /// punches across the top (X, Y, RB), kicks across the bottom (A, B, RT).
    static let defaults: [String: Int] = [
        GCInputButtonX: RetroPad.y,             // left face, arcade 1, LP
        GCInputButtonY: RetroPad.x,             // top face, arcade 2, MP
        GCInputRightShoulder: RetroPad.l,       // arcade 3, HP
        GCInputButtonA: RetroPad.b,             // bottom face, arcade 4, LK
        GCInputButtonB: RetroPad.a,             // right face, arcade 5, MK
        GCInputRightTrigger: RetroPad.r,        // arcade 6, HK
        GCInputLeftShoulder: RetroPad.l2,
        GCInputLeftTrigger: RetroPad.r2,
        GCInputButtonMenu: RetroPad.start,
        GCInputButtonOptions: RetroPad.select,  // Coin in arcade profiles
        GCInputButtonHome: RetroPad.overlay,    // exit and emulator menu
    ]

    /// The bumpers variant: heavies on LB and RB, triggers unused by the
    /// six. The SNES Street Fighter II arrangement.
    static let bumpers: [String: Int] = [
        GCInputButtonX: RetroPad.y,             // arcade 1, LP
        GCInputButtonY: RetroPad.x,             // arcade 2, MP
        GCInputLeftShoulder: RetroPad.l,        // arcade 3, HP
        GCInputButtonA: RetroPad.b,             // arcade 4, LK
        GCInputButtonB: RetroPad.a,             // arcade 5, MK
        GCInputRightShoulder: RetroPad.r,       // arcade 6, HK
        GCInputLeftTrigger: RetroPad.l2,
        GCInputRightTrigger: RetroPad.r2,
        GCInputButtonMenu: RetroPad.start,
        GCInputButtonOptions: RetroPad.select,
        GCInputButtonHome: RetroPad.overlay,
    ]

    /// N64 only. The arcade fold above is wrong for this console in a
    /// way players notice immediately (Hydro Thunder's camera swinging
    /// where a labelled button should act, reported 2026-08-19).
    ///
    /// The full row follows the layout established emulators have set
    /// for N64 on an Xbox-style pad (mupen64plus-next's RetroArch
    /// defaults, Project64): A accelerates where A sits, N64 B on the
    /// west face, C-down and C-up on the east and north faces, Z on the
    /// left trigger, N64 L and R on the bumpers, all four C-buttons on
    /// the right stick.
    ///
    /// The RetroPad ids look odd because this app pins the core's
    /// alt-map mode (see NativeCoreOptions' n64 case: the touch layout
    /// needs C-buttons as plain RetroPad bits), and in that mode the
    /// core reads N64 L from RetroPad Select and N64 R from RetroPad R2
    /// (emulate_game_controller_via_libretro.c, alternate_mapping
    /// branch). The row exists precisely so a core quirk like that is
    /// absorbed here, per platform, instead of leaking to the player's
    /// hands.
    static let n64: [String: Int] = {
        var map = defaults
        map[GCInputButtonA] = RetroPad.b              // N64 A
        map[GCInputButtonX] = RetroPad.y              // N64 B
        map[GCInputButtonB] = RetroPad.a              // C-down
        map[GCInputButtonY] = RetroPad.x              // C-up
        map[GCInputLeftTrigger] = RetroPad.l2         // Z
        map[GCInputLeftShoulder] = RetroPad.select    // N64 L (alt-map quirk)
        map[GCInputRightShoulder] = RetroPad.r2       // N64 R (alt-map quirk)
        map[GCInputRightTrigger] = RetroPad.r2        // N64 R, trigger twin
        return map
    }()

    /// A platform's complete controller personality, resolved from one
    /// table in one place. The engine (GameControllerManager) is shared
    /// by every platform; everything platform-specific about how a pad
    /// reaches a game lives here as data, so editing one platform's row
    /// cannot change another's. Same principle as the touch layouts:
    /// layouts are data, not code.
    struct PlatformProfile {
        /// The base button map, before any per controller edits the
        /// player has saved.
        let base: [String: Int]
        /// Whether the left stick is digitized into d-pad presses. True
        /// wherever the digitized bits are the only path a stick has
        /// into the game (arcade, and every d-pad-only console); false
        /// only where the core reads the true analog value from a
        /// controller that also carries a separate d-pad (Dreamcast,
        /// N64), where one thumb must not press two physical controls
        /// at once (Rush 2049, reported 2026-08-16).
        let digitizesLeftStick: Bool
    }

    /// nil platform is the shell and the webview player: arcade base
    /// map, digitizing on, exactly the behaviour that predates profiles.
    static func profile(for platform: String?) -> PlatformProfile {
        switch platform {
        case "n64":
            return PlatformProfile(base: n64, digitizesLeftStick: false)
        case "dreamcast":
            return PlatformProfile(base: defaults, digitizesLeftStick: false)
        case "ngc":
            // The GameCube has a real analog stick AND a separate d-pad,
            // and its games read both. Digitizing the stick into d-pad
            // bits would make every stick movement press a direction too,
            // which in a menu reads as the cursor running away. Additive:
            // no other platform's answer changes.
            return PlatformProfile(base: defaults, digitizesLeftStick: false)
        default:
            return PlatformProfile(base: defaults, digitizesLeftStick: true)
        }
    }

    /// The choices the remap screen offers whole, before any per button
    /// editing.
    static let presets: [(name: String, detail: String, map: [String: Int])] = [
        (
            "Heavies on the right side",
            "HP on RB, HK on RT. How console fighters map a pad.",
            defaults
        ),
        (
            "Heavies on the bumpers",
            "HP on LB, HK on RB. For pads whose triggers travel too far.",
            bumpers
        ),
    ]

    private static func key(for controller: String) -> String {
        "com.mmagtech.RommApp.bindings.\(controller)"
    }

    /// Stored overrides applied over the platform base.
    ///
    /// A saved map was authored on the remap screen against `defaults`,
    /// so it is treated as the player's EDITS against defaults, not as a
    /// complete map: keys whose value differs from defaults carry over,
    /// keys the player cleared stay cleared, and everything untouched
    /// resolves from the platform base. On default-base platforms this
    /// reproduces the old wholesale replacement byte for byte; on N64 it
    /// keeps the player's deliberate changes while the platform's own
    /// face-button labels still land (review finding, 2026-08-20: the
    /// wholesale replacement silently reverted the N64 map for anyone
    /// who had ever remapped a single button).
    static func effective(for controller: String, platform: String? = nil) -> [String: Int] {
        var map = profile(for: platform).base
        if let saved = UserDefaults.standard.dictionary(forKey: key(for: controller))
            as? [String: Int] {
            for (element, id) in saved where defaults[element] != id {
                // A binding the player changed, or added on an element
                // defaults leaves unbound. Their choice outranks the
                // platform base on that element.
                map[element] = id
            }
            for element in defaults.keys where saved[element] == nil {
                // A binding the player deliberately cleared stays
                // cleared on every platform.
                map.removeValue(forKey: element)
            }
        }
        return map
    }

    static func save(_ map: [String: Int], for controller: String) {
        UserDefaults.standard.set(map, forKey: key(for: controller))
    }

    static func reset(for controller: String) {
        UserDefaults.standard.removeObject(forKey: key(for: controller))
    }
}

/// A second, independent way to open the pause menu, alongside whatever
/// single button is bound to `RetroPad.overlay` (Home, by default). Home
/// alone was not enough: iOS reserves some pads' Home button for its own
/// accessory picker, and even where it works, a single button anyone might
/// rest a thumb on is one accidental press from pausing a game.
///
/// Kept as two element names rather than folded into the ordinary bindings
/// table, because a hotkey is fundamentally different from every other
/// entry there: it needs both held together, not one button pointed at one
/// input, and it applies regardless of what either button is otherwise
/// bound to. Global rather than per-controller, unlike ordinary bindings:
/// the actual risk this exists to avoid, a real game using the same two
/// buttons together during normal play, comes from the game, not the pad
/// model, so there is no reason a Xbox pad and a PS5 pad would want
/// different choices here.
///
/// L3+R3, both stick clicks, is the default, matching RetroArch's own
/// alternative to Select+Start specifically because analog trigger pairs
/// (L2+R2) collide with real gameplay, braking and accelerating together
/// in a racing game being the obvious case, while clicking both sticks at
/// once has no gameplay meaning in anything this app runs.
enum MenuHotkey {
    private static let keyA = "com.mmagtech.RommApp.hotkey.buttonA"
    private static let keyB = "com.mmagtech.RommApp.hotkey.buttonB"
    /// Explicit "cleared" marker, distinct from "never configured": a plain
    /// nil default for buttonB would be indistinguishable from someone who
    /// deliberately removed it to make this a single-button hotkey, and the
    /// factory default (R3) would keep coming back every launch.
    private static let clearedMarker = "\u{0}none"

    static var buttonA: String {
        UserDefaults.standard.string(forKey: keyA) ?? GCInputLeftThumbstickButton
    }

    /// nil means single-button mode: buttonA alone opens the menu. Set
    /// means both must be held together.
    static var buttonB: String? {
        let stored = UserDefaults.standard.string(forKey: keyB)
        if stored == clearedMarker { return nil }
        return stored ?? GCInputRightThumbstickButton
    }

    static func save(buttonA: String, buttonB: String?) {
        UserDefaults.standard.set(buttonA, forKey: keyA)
        UserDefaults.standard.set(buttonB ?? clearedMarker, forKey: keyB)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: keyA)
        UserDefaults.standard.removeObject(forKey: keyB)
    }

    static var isDefault: Bool {
        UserDefaults.standard.string(forKey: keyA) == nil
            && UserDefaults.standard.string(forKey: keyB) == nil
    }
}

/// RetroPad ids, confirmed against the EmulatorJS 4.2.3 bundle and the
/// standard libretro joypad ordering.
enum RetroPad {
    static let b = 0, y = 1, select = 2, start = 3
    static let up = 4, down = 5, left = 6, right = 7
    static let a = 8, x = 9, l = 10, r = 11
    static let l2 = 12, r2 = 13

    /// Not a game input: reveals the overlay holding the close button and
    /// EmulatorJS's menu. Bindable like anything else, because the Home
    /// button it defaults to is reserved by iOS on some controllers, and a
    /// player with no way back out of a game is stuck.
    static let overlay = -1

    /// EmulatorJS's own indices for its first and second analog sticks (16
    /// to 19, 20 to 23), confirmed against its source, not the standard
    /// RetroPad table above, and confirmed generic to the bridge itself
    /// rather than particular to any one core: N64's stick and C-buttons use
    /// them, Virtual Boy's second d-pad uses the same block for its own
    /// control scheme, and FBNeo's arcade cores route a twin-stick game's
    /// second joystick through the identical right-analog-stick indices.
    /// Anything in this range must go through `PlayerView.Input.send`'s
    /// magnitude path, `__cm`, never the boolean `__ci` one: EmulatorJS
    /// reads both through the same analog dispatch regardless of source.
    static func isAnalogAxis(_ id: Int) -> Bool { (16...23).contains(id) }

    /// Every input a person may want to bind, in the order the remap screen
    /// walks through them. Directions are excluded: they come from the d-pad
    /// and stick automatically and are not a source of trouble.
    /// Names have to hold for the whole library, not just arcade.
    ///
    /// These used to be labelled "Arcade button 1" through 6 and described
    /// entirely in terms of fighting games, which reads as nonsense while
    /// binding a pad for Game Boy or Mega Drive, where the same input is
    /// simply B or A. Each row now leads with the arcade position, since
    /// that is what the on screen pad prints and what an arcade panel is
    /// laid out as, and names the console equivalent underneath so the row
    /// still means something on every other system.
    static let bindable: [(id: Int, label: String, detail: String)] = [
        (overlay, "Pause menu", "Freezes the game and opens the menu to resume, save or quit."),
        (select, "Coin", "Insert a credit. Select on a console."),
        (start, "Start", "Begins play once credited. Start on a console."),
        // Console equivalents are given as the input's own short name, not
        // as a physical position. "Left shoulder on a console pad" sitting
        // beside an assignment reading "Right shoulder, RB" looks like a
        // contradiction, when in truth one names the input and the other
        // the button now driving it. A letter cannot be misread that way.
        (y, "Button 1", "Top row, left. Y on a console pad."),
        (x, "Button 2", "Top row, middle. X on a console pad."),
        (l, "Button 3", "Top row, right. L on a console pad."),
        (b, "Button 4", "Bottom row, left. B on a console pad."),
        (a, "Button 5", "Bottom row, middle. A on a console pad."),
        (r, "Button 6", "Bottom row, right. R on a console pad."),
        (l2, "L2", "Used by a few console games, almost no arcade ones."),
        (r2, "R2", "Used by a few console games, almost no arcade ones."),
    ]

    static func label(for id: Int) -> String {
        bindable.first { $0.id == id }?.label ?? "Input \(id)"
    }

}
