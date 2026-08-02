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

    /// Stored overrides merged over the defaults.
    static func effective(for controller: String) -> [String: Int] {
        var map = defaults
        if let saved = UserDefaults.standard.dictionary(forKey: key(for: controller))
            as? [String: Int] {
            // A saved map replaces wholesale rather than merging, so a
            // deliberate unbinding is not undone by the defaults.
            map = saved
        }
        return map
    }

    static func save(_ map: [String: Int], for controller: String) {
        UserDefaults.standard.set(map, forKey: key(for: controller))
    }

    static func reset(for controller: String) {
        UserDefaults.standard.removeObject(forKey: key(for: controller))
    }

    static func hasCustomBindings(for controller: String) -> Bool {
        UserDefaults.standard.dictionary(forKey: key(for: controller)) != nil
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

    /// Every input a person may want to bind, in the order the remap screen
    /// walks through them. Directions are excluded: they come from the d-pad
    /// and stick automatically and are not a source of trouble.
    static let bindable: [(id: Int, label: String, detail: String)] = [
        (overlay, "Exit and menu", "Shows the close button and the emulator's own menu."),
        (select, "Coin, Select", "Arcade credit. Needed to start any arcade game."),
        (start, "Start", "Begins play once credited."),
        (y, "Arcade button 1", "Light punch in fighters."),
        (x, "Arcade button 2", "Medium punch."),
        (l, "Arcade button 3", "Heavy punch."),
        (b, "Arcade button 4", "Light kick. The main action button in most games."),
        (a, "Arcade button 5", "Medium kick."),
        (r, "Arcade button 6", "Heavy kick."),
        (l2, "L2", "Rarely used by arcade games."),
        (r2, "R2", "Rarely used by arcade games."),
    ]

    static func label(for id: Int) -> String {
        bindable.first { $0.id == id }?.label ?? "Input \(id)"
    }

    /// Everything the test screen watches, directions included, since a stick
    /// that reports nothing is worth seeing too.
    static let diagnostics: [(id: Int, label: String, from: String)] = [
        (up, "Up", "D-pad or left stick"),
        (down, "Down", "D-pad or left stick"),
        (left, "Left", "D-pad or left stick"),
        (right, "Right", "D-pad or left stick"),
        (select, "Coin, Select", "Assigned in Change buttons"),
        (start, "Start", "Assigned in Change buttons"),
        (y, "Arcade button 1", "Assigned in Change buttons"),
        (x, "Arcade button 2", "Assigned in Change buttons"),
        (l, "Arcade button 3", "Assigned in Change buttons"),
        (b, "Arcade button 4", "Assigned in Change buttons"),
        (a, "Arcade button 5", "Assigned in Change buttons"),
        (r, "Arcade button 6", "Assigned in Change buttons"),
        (l2, "L2", "Assigned in Change buttons"),
        (r2, "R2", "Assigned in Change buttons"),
    ]
}
