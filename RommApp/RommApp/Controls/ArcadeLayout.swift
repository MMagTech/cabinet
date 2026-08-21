import Foundation

/// Builds a control layout from an arcade profile at runtime.
///
/// Arcade layouts are per game, not per system, so they cannot be bundled
/// files like console layouts. The profile says how many buttons and what
/// kind of stick; this arranges them. Button labels are generic numbers for
/// v0.1, per the scope doc: labels are cosmetic, the index to core input
/// mapping is what matters.
///
/// RetroPad ids per position, matching FBNeo's conventions:
/// - Up to four buttons run B, A, Y, X (0, 8, 1, 9), which on Neo Geo is
///   exactly A, B, C, D.
/// - Five and six button games get two rows of three, punches over kicks:
///   Y, X, L over B, A, R (1, 9, 10 over 0, 8, 11), the CPS fighter order.
/// - Coin is Select (2) and Start is Start (3) on every arcade core.
///
/// Coin is a primary control, not a small central pill. People feed arcade
/// machines coins constantly.
enum ArcadeLayout {
    /// `analog` is what the game's own driver says it wants
    /// (analog-controls.json); passed only by the native player when the
    /// running core's mouse channel is actually wired, so the webview
    /// player keeps its d-pad and nothing changes for it.
    static func build(for profile: ArcadeProfile, analog: AnalogControls? = nil) -> ControlLayout {
        // Arcade accurate: the panel the player stood at. The driver
        // data says which analog controls the cabinet had; the profile
        // says whether a joystick was there too. Between them every
        // shape in the library is one of a dozen panels.
        if let analog, let panel = panel(for: profile, analog: analog) {
            return panel
        }
        return buildStandard(for: profile)
    }

    /// Assembles the cabinet's panel: the analog controls the driver
    /// declares, the joystick if the machine had one, and the buttons.
    ///
    /// A tuned file always wins, so the LayoutEditor stays the way these
    /// get made properly; this is what a shape looks like before anyone
    /// has tuned it, which is the same relationship every arcade layout
    /// has always had to its generator.
    private static func panel(for profile: ArcadeProfile, analog: AnalogControls) -> ControlLayout? {
        let hasJoystick = profile.profile != "special"
        var analogKinds: [ControlLayout.Item.Kind] = []
        // A rotary joystick was one control: the player pushed it and
        // twisted it with the same hand, at the same time. A thumb on
        // glass cannot do both to one spot, and being able to walk one
        // way while firing another IS the game, so the control splits
        // across the two thumbs rather than sitting whole under one.
        // The stick keeps its slot; the twist becomes a ring the right
        // thumb reaches, above the buttons.
        if (analog.rotary ?? 0) > 0 {
            let base = buildStandard(for: profile)
            // The stick becomes a rotary item purely as a marker: the pad
            // reads it as a d-pad for direction and, seeing it, turns on
            // tilt aiming. Nothing extra is drawn, because the third
            // control is the phone.
            func mark(_ list: [ControlLayout.Item]) -> [ControlLayout.Item] {
                list.map { item in
                    guard item.kind == .dpad else { return item }
                    return ControlLayout.Item(
                        kind: .rotary, label: nil, input: nil, inputs: item.inputs,
                        frame: item.frame, extended: item.extended,
                        fourWay: false, sensitivity: nil)
                }
            }
            return ControlLayout(
                system: base.system, items: mark(base.items),
                landscapeItems: base.landscapeItems.map(mark), headroom: base.headroom)
        }
        if (analog.trackball ?? 0) > 0 { analogKinds.append(.trackball) }
        if (analog.dial ?? 0) > 0 || (analog.paddle ?? 0) > 0 { analogKinds.append(.spinner) }
        if (analog.axis ?? 0) > 0 && analogKinds.isEmpty { analogKinds.append(.wheel) }
        let gun = (analog.lightgun ?? 0) > 0
        let pedalCount = analog.pedals ?? 0
        let pedals = pedalCount > 0
        // An analog stick is a stick: the existing kind already serves
        // it, and the standard layout already draws one.
        if analogKinds.isEmpty && !gun && !pedals { return nil }

        if let tuned = tunedPanel(for: profile, kinds: analogKinds, gun: gun, pedals: pedals) {
            return tuned
        }

        let base = buildStandard(for: profile)
        var items = base.items
        var wide = base.landscapeItems ?? base.items

        // A gun cabinet aims at the picture, so its surface is the whole
        // screen and the panel keeps only its buttons. Landscape only:
        // in portrait the pad occupies a strip and cannot reach the
        // picture, and every gun cabinet was landscape anyway.
        if gun {
            let surface = ControlLayout.Item(
                kind: .gun, label: nil, input: nil, inputs: nil,
                frame: ControlLayout.Rect(x: 0, y: 0, w: 1, h: 1),
                extended: ControlLayout.Rect(x: 0, y: 0, w: 1, h: 1),
                fourWay: nil, sensitivity: nil)
            wide = [surface] + wide.filter { $0.kind != .dpad && $0.kind != .stick }
        }

        for (index, kind) in analogKinds.enumerated() {
            let sens: Double = kind == .spinner ? 768 : (kind == .wheel ? 500 : 300)
            if !hasJoystick && index == 0 {
                // No stick on this panel: the analog control takes its
                // slot and its reach.
                func swap(_ list: [ControlLayout.Item]) -> [ControlLayout.Item] {
                    list.map { item in
                        guard item.kind == .dpad else { return item }
                        return ControlLayout.Item(
                            kind: kind, label: nil, input: nil, inputs: nil,
                            frame: item.frame, extended: item.extended,
                            fourWay: nil, sensitivity: sens)
                    }
                }
                items = swap(items); wide = swap(wide)
            } else {
                // Beside the stick, upper right, clear of the buttons.
                let y = 0.06 + Double(index) * 0.34
                let item = ControlLayout.Item(
                    kind: kind, label: nil, input: nil, inputs: nil,
                    frame: ControlLayout.Rect(x: 0.62, y: y, w: 0.28, h: 0.28),
                    extended: ControlLayout.Rect(x: 0.58, y: y - 0.04, w: 0.36, h: 0.36),
                    fourWay: nil, sensitivity: sens)
                items.append(item); wide.append(item)
            }
        }

        // Pedals ride RetroPad R and L, which is where this core puts
        // them: it maps MAME's button 6 to R and button 5 to L and
        // renames them "Pedal" and "Pedal2" when a driver declares them.
        // Guessed ids sent a Super Off Road accelerator to the wrong
        // button entirely. And the count is the driver's: that cabinet
        // has one pedal, so drawing a brake it never had is exactly the
        // invention this rule exists to prevent.
        for (i, spec) in pedalSpecs(count: pedalCount).enumerated() {
            let pedal = ControlLayout.Item(
                kind: .pedal, label: spec.label, input: spec.input, inputs: nil,
                frame: ControlLayout.Rect(x: 0.855, y: 0.40 + Double(i) * 0.27, w: 0.125, h: 0.23),
                extended: ControlLayout.Rect(x: 0.815, y: 0.36 + Double(i) * 0.27, w: 0.185, h: 0.29),
                fourWay: nil, sensitivity: nil)
            items.append(pedal); wide.append(pedal)
        }

        return ControlLayout(
            system: base.system, items: items,
            landscapeItems: wide, headroom: base.headroom)
    }

    /// One pedal is an accelerator and says so; two are gas and brake.
    /// Short labels because a pedal is drawn as a narrow pill and a long
    /// word truncates to initials, which is how "Gas" and "Brake" first
    /// appeared on screen as G and B.
    private static func pedalSpecs(count: Int) -> [(label: String, input: Int)] {
        switch count {
        case 0: return []            // no pedals on the panel, none drawn
        case 1: return [("Gas", RetroPad.r)]
        default: return [("Gas", RetroPad.r), ("Brake", RetroPad.l)]
        }
    }

    /// A hand-tuned panel file, named for its shape, if one exists yet.
    private static func tunedPanel(
        for profile: ArcadeProfile, kinds: [ControlLayout.Item.Kind], gun: Bool, pedals: Bool
    ) -> ControlLayout? {
        guard !gun, !pedals, kinds.count == 1 else { return nil }
        let stem = kinds[0] == .spinner ? "spinner" : (kinds[0] == .trackball ? "trackball" : "wheel")
        let name = "arcade-\(stem)\(max(0, min(profile.buttons, 6)))"
        guard profile.profile == "special",
              let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else { return nil }
        return file
    }

    /// A cabinet whose panel carried a joystick AND a dial or trackball
    /// (Discs of Tron, the joystick-plus-spinner family). The stick keeps
    /// its slot; the analog control takes the upper right, clear of the
    /// action buttons below it.
    private static func withAnalogBeside(_ base: ControlLayout, kind: ControlLayout.Item.Kind) -> ControlLayout {
        let sens: Double = kind == .spinner ? 768 : 300
        let item = ControlLayout.Item(
            kind: kind, label: nil, input: nil, inputs: nil,
            frame: ControlLayout.Rect(x: 0.60, y: 0.06, w: 0.30, h: 0.30),
            extended: ControlLayout.Rect(x: 0.56, y: 0.02, w: 0.38, h: 0.38),
            fourWay: nil, sensitivity: sens)
        return ControlLayout(
            system: base.system, items: base.items + [item],
            landscapeItems: base.landscapeItems.map { $0 + [item] },
            headroom: base.headroom)
    }

    private static func buildStandard(for profile: ArcadeProfile) -> ControlLayout {
        // A tuned file wins over the generated arrangement. The generator
        // below is what produced these files in the first place
        // (tools/arcade-layouts), so this changes nothing until one is
        // edited; it exists so arcade layouts can be tuned in the
        // LayoutEditor like every other system instead of being the one
        // corner of the app where layouts are code.
        if let tuned = tunedLayout(for: profile) {
            return tuned
        }
        var items: [ControlLayout.Item] = []

        // The stick, low in the left thumb's arc, pivoting from the bottom
        // corner grip. Four way games actively suppress diagonals, which
        // matters for the Pac-Man and Donkey Kong family. A twin-stick game
        // shrinks it to leave room for the second one mirroring it on the
        // right, where the action button arc would otherwise go: aiming is
        // this genre's primary control, not a secondary one competing with
        // movement for space.
        if profile.isDualStick {
            items.append(ControlLayout.Item(
                kind: .dpad,
                label: nil,
                input: nil,
                inputs: [4, 5, 6, 7],
                frame: ControlLayout.Rect(x: 0.04, y: 0.40, w: 0.34, h: 0.46),
                extended: ControlLayout.Rect(x: 0.0, y: 0.32, w: 0.40, h: 0.62),
                fourWay: false
            ))
            items.append(secondStick(landscape: false))
            items.append(contentsOf: dualStickButtons(count: profile.buttons))
        } else {
            items.append(ControlLayout.Item(
                kind: .dpad,
                label: nil,
                input: nil,
                inputs: [4, 5, 6, 7],
                frame: ControlLayout.Rect(x: 0.07, y: 0.38, w: 0.40, h: 0.52),
                extended: ControlLayout.Rect(x: 0.02, y: 0.30, w: 0.50, h: 0.68),
                fourWay: profile.isFourWay
            ))
            items.append(contentsOf: actionButtons(count: max(0, min(profile.buttons, 6))))
        }

        // Coin and Start are pressed a few times a session, so they take the
        // top band of the strip, out of both thumb arcs where mid-game hands
        // never stray. Coin stays big and obvious: primary in presence, not
        // in position.
        // A breath of margin above both, so Coin never rides the canvas edge.
        items.append(ControlLayout.Item(
            kind: .button,
            label: "Coin",
            input: 2,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.05, y: 0.07, w: 0.14, h: 0.17),
            extended: ControlLayout.Rect(x: 0.01, y: 0.03, w: 0.22, h: 0.26),
            fourWay: nil
        ))
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Start",
            input: 3,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.40, y: 0.10, w: 0.20, h: 0.10),
            extended: ControlLayout.Rect(x: 0.36, y: 0.05, w: 0.28, h: 0.20),
            fourWay: nil
        ))

        // Menu freezes the game the moment it is pressed, so it lives on
        // the pad like any control: hunting a pause through a web menu
        // while something shoots at you is how runs end. Arcade games have
        // no pause of their own, which is exactly why this one matters.
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Menu",
            input: RetroPad.overlay,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.72, y: 0.10, w: 0.17, h: 0.10),
            extended: ControlLayout.Rect(x: 0.68, y: 0.05, w: 0.25, h: 0.20),
            fourWay: nil
        ))

        // The button count rides in the system name because that is what
        // decides the colours: a game overridden to six buttons needs the
        // fighter palette even though its profile still says whatever the
        // cabinet data called it.
        return ControlLayout(
            system: "arcade:\(profile.profile):\(max(0, min(profile.buttons, 6)))",
            items: items,
            landscapeItems: landscapeItems(for: profile),
            headroom: nil
        )
    }

    /// The tuned file for this profile's geometry, if one is bundled.
    ///
    /// Only the stick kind and the button count pick the file: everything
    /// else about a profile is either behaviour or palette, and both are
    /// re-applied here from the live profile rather than trusted from the
    /// file. Four-way-ness in particular is the game's own cabinet data
    /// (Pac-Man and Donkey Kong break when fed diagonals), so it overrides
    /// whatever the file happens to carry, and the system string is rebuilt
    /// so the palette still follows the running game.
    private static func tunedLayout(for profile: ArcadeProfile) -> ControlLayout? {
        let count = max(0, min(profile.buttons, 6))
        let name = "arcade-\(profile.isDualStick ? "twin" : "stick")\(count)"
        // Loaded here rather than through ControlLayout.named, which
        // asserts on a miss because everywhere else a missing layout IS a
        // bug. Here it simply means this variant has never been tuned, and
        // the generator below is the answer.
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else { return nil }
        let fourWay = profile.isDualStick ? false : profile.isFourWay
        func applied(_ items: [ControlLayout.Item]) -> [ControlLayout.Item] {
            items.map { item in
                guard item.kind == .dpad, item.inputs == [4, 5, 6, 7] else { return item }
                return ControlLayout.Item(
                    kind: item.kind, label: item.label, input: item.input,
                    inputs: item.inputs, frame: item.frame,
                    extended: item.extended, fourWay: fourWay
                )
            }
        }
        return ControlLayout(
            system: "arcade:\(profile.profile):\(count)",
            items: applied(file.items),
            landscapeItems: file.landscapeItems.map(applied),
            headroom: file.headroom
        )
    }

    /// The landscape arrangement: canvas centred, controls flanking it in
    /// the gutters. Frames are normalised against the full screen.
    private static func landscapeItems(for profile: ArcadeProfile) -> [ControlLayout.Item] {
        var items: [ControlLayout.Item] = []

        if profile.isDualStick {
            items.append(ControlLayout.Item(
                kind: .dpad,
                label: nil,
                input: nil,
                inputs: [4, 5, 6, 7],
                frame: ControlLayout.Rect(x: 0.03, y: 0.42, w: 0.19, h: 0.42),
                extended: ControlLayout.Rect(x: 0.00, y: 0.32, w: 0.24, h: 0.58),
                fourWay: false
            ))
            items.append(secondStick(landscape: true))
            items.append(contentsOf: dualStickButtons(count: profile.buttons, landscape: true))
            items.append(ControlLayout.Item(
                kind: .button,
                label: "Coin",
                input: 2,
                inputs: nil,
                frame: ControlLayout.Rect(x: 0.025, y: 0.06, w: 0.065, h: 0.15),
                extended: ControlLayout.Rect(x: 0.00, y: 0.02, w: 0.10, h: 0.24),
                fourWay: nil
            ))
            items.append(ControlLayout.Item(
                kind: .pill,
                label: "Start",
                input: 3,
                inputs: nil,
                frame: ControlLayout.Rect(x: 0.87, y: 0.07, w: 0.10, h: 0.09),
                extended: ControlLayout.Rect(x: 0.84, y: 0.03, w: 0.15, h: 0.16),
                fourWay: nil
            ))
            items.append(ControlLayout.Item(
                kind: .pill,
                label: "Menu",
                input: RetroPad.overlay,
                inputs: nil,
                frame: ControlLayout.Rect(x: 0.105, y: 0.07, w: 0.10, h: 0.09),
                extended: ControlLayout.Rect(x: 0.10, y: 0.03, w: 0.14, h: 0.16),
                fourWay: nil
            ))
            return items
        }

        items.append(ControlLayout.Item(
            kind: .dpad,
            label: nil,
            input: nil,
            inputs: [4, 5, 6, 7],
            frame: ControlLayout.Rect(x: 0.03, y: 0.42, w: 0.19, h: 0.42),
            extended: ControlLayout.Rect(x: 0.00, y: 0.32, w: 0.24, h: 0.58),
            fourWay: profile.isFourWay
        ))

        let count = max(0, min(profile.buttons, 6))
        let singleRowIds = [0, 8, 1, 9]
        let doubleRowIds = [1, 9, 10, 0, 8, 11]

        func button(id: Int, label: String, x: Double, y: Double) -> ControlLayout.Item {
            ControlLayout.Item(
                kind: .button,
                label: label,
                input: id,
                inputs: nil,
                frame: ControlLayout.Rect(x: x, y: y, w: 0.07, h: 0.16),
                extended: ControlLayout.Rect(x: x - 0.02, y: y - 0.05, w: 0.11, h: 0.26),
                fourWay: nil
            )
        }

        if count <= 4 {
            // The right thumb's sweep, rotated for landscape: rising from
            // low inside toward the upper corner.
            let positions: [(Double, Double)] = [
                (0.78, 0.64), (0.85, 0.46), (0.90, 0.26), (0.90, 0.68),
            ]
            for index in 0..<count {
                let (x, y) = positions[index]
                items.append(button(
                    id: singleRowIds[index], label: "\(index + 1)", x: x, y: y
                ))
            }
        } else {
            let columns: [Double] = [0.77, 0.845, 0.92]
            for index in 0..<count {
                let row = index / 3
                let column = index % 3
                items.append(button(
                    id: doubleRowIds[index],
                    label: "\(index + 1)",
                    x: columns[column],
                    y: row == 0 ? 0.40 : 0.62
                ))
            }
        }

        items.append(ControlLayout.Item(
            kind: .button,
            label: "Coin",
            input: 2,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.025, y: 0.06, w: 0.065, h: 0.15),
            extended: ControlLayout.Rect(x: 0.00, y: 0.02, w: 0.10, h: 0.24),
            fourWay: nil
        ))
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Start",
            input: 3,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.87, y: 0.07, w: 0.10, h: 0.09),
            extended: ControlLayout.Rect(x: 0.84, y: 0.03, w: 0.15, h: 0.16),
            fourWay: nil
        ))

        // Beside Coin in the top left gutter, out of both thumb arcs.
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Menu",
            input: RetroPad.overlay,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.105, y: 0.07, w: 0.10, h: 0.09),
            extended: ControlLayout.Rect(x: 0.10, y: 0.03, w: 0.14, h: 0.16),
            fourWay: nil
        ))

        return items
    }

    /// Action buttons in the right thumb's arc. The arc curls with the
    /// thumb's natural sweep, from low inside toward the corner, so moving
    /// between buttons is a rotation of the thumb, never a new grip. Two
    /// rows of three keep cabinet muscle memory for six button games,
    /// dropped low enough that the top row is a stretch, not a reach.
    private static func actionButtons(count: Int) -> [ControlLayout.Item] {
        guard count > 0 else { return [] }

        let singleRowIds = [0, 8, 1, 9]                 // B A Y X
        let doubleRowIds = [1, 9, 10, 0, 8, 11]         // Y X L / B A R

        var items: [ControlLayout.Item] = []

        func button(id: Int, label: String, x: Double, y: Double) -> ControlLayout.Item {
            ControlLayout.Item(
                kind: .button,
                label: label,
                input: id,
                inputs: nil,
                frame: ControlLayout.Rect(x: x, y: y, w: 0.15, h: 0.20),
                extended: ControlLayout.Rect(x: x - 0.04, y: y - 0.06, w: 0.23, h: 0.32),
                fourWay: nil
            )
        }

        if count <= 4 {
            // The sweep: button one sits at the thumb's rest, later buttons
            // follow the arc up and outward. A fourth tucks below the arc.
            let positions: [(Double, Double)] = [
                (0.54, 0.58), (0.70, 0.44), (0.82, 0.28), (0.80, 0.62),
            ]
            for index in 0..<count {
                let (x, y) = positions[index]
                items.append(button(
                    id: singleRowIds[index], label: "\(index + 1)", x: x, y: y
                ))
            }
        } else {
            // Two rows of three, low in the strip.
            let columns: [Double] = [0.50, 0.66, 0.82]
            for index in 0..<count {
                let row = index / 3
                let column = index % 3
                items.append(button(
                    id: doubleRowIds[index],
                    label: "\(index + 1)",
                    x: columns[column],
                    y: row == 0 ? 0.36 : 0.62
                ))
            }
        }

        return items
    }

    /// The second joystick, mirroring the first on the right rather than
    /// taking the action buttons' usual arc: aiming is this genre's primary
    /// control. Drawn as a d-pad, the same digital cross the first stick is,
    /// because it is one on the real cabinet; FBNeo routes it through the
    /// analog right stick indices underneath, which `PlayerView.Input.send`
    /// already handles for anything in that range, so nothing here needs to
    /// know the difference.
    private static func secondStick(landscape: Bool) -> ControlLayout.Item {
        let ids = [23, 22, 21, 20]   // up, down, left, right
        if landscape {
            return ControlLayout.Item(
                kind: .dpad, label: nil, input: nil, inputs: ids,
                frame: ControlLayout.Rect(x: 0.78, y: 0.42, w: 0.19, h: 0.42),
                extended: ControlLayout.Rect(x: 0.76, y: 0.32, w: 0.24, h: 0.58),
                fourWay: false
            )
        }
        return ControlLayout.Item(
            kind: .dpad, label: nil, input: nil, inputs: ids,
            frame: ControlLayout.Rect(x: 0.62, y: 0.40, w: 0.34, h: 0.46),
            extended: ControlLayout.Rect(x: 0.60, y: 0.32, w: 0.40, h: 0.62),
            fourWay: false
        )
    }

    /// A twin-stick game's own fire/bomb buttons, ordinary digital buttons
    /// on the real cabinet and RetroPad ids here, unlike the sticks either
    /// side of them: only a joystick's directions get the analog reroute.
    /// Portrait, they sit in the gap the two sticks leave between them, the
    /// one open patch of strip; landscape has no equivalent gap, so they
    /// stack in the same top corner Start already occupies its own game's
    /// worth of room away from.
    private static func dualStickButtons(count: Int, landscape: Bool = false) -> [ControlLayout.Item] {
        let ids = [0, 8, 1, 9]
        let shown = max(0, min(count, 4))
        guard shown > 0 else { return [] }

        func item(id: Int, label: String, x: Double, y: Double, w: Double, h: Double) -> ControlLayout.Item {
            ControlLayout.Item(
                kind: .button, label: label, input: id, inputs: nil,
                frame: ControlLayout.Rect(x: x, y: y, w: w, h: h),
                extended: ControlLayout.Rect(x: x - 0.03, y: y - 0.03, w: w + 0.06, h: h + 0.06),
                fourWay: nil
            )
        }

        var items: [ControlLayout.Item] = []
        if landscape {
            let positions: [(Double, Double)] = [(0.50, 0.30), (0.50, 0.48), (0.44, 0.30), (0.44, 0.48)]
            for index in 0..<shown {
                let (x, y) = positions[index]
                items.append(item(id: ids[index], label: "\(index + 1)", x: x, y: y, w: 0.06, h: 0.14))
            }
        } else {
            let positions: [(Double, Double)] = [(0.43, 0.48), (0.43, 0.68), (0.35, 0.48), (0.51, 0.48)]
            for index in 0..<shown {
                let (x, y) = positions[index]
                items.append(item(id: ids[index], label: "\(index + 1)", x: x, y: y, w: 0.14, h: 0.16))
            }
        }
        return items
    }
}
