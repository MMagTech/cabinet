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
