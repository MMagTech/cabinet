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
    static func build(for profile: ArcadeProfile) -> ControlLayout {
        var items: [ControlLayout.Item] = []

        // The stick, low in the left thumb's arc, pivoting from the bottom
        // corner grip. Four way games actively suppress diagonals, which
        // matters for the Pac-Man and Donkey Kong family.
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
            landscapeItems: landscapeItems(for: profile)
        )
    }

    /// The landscape arrangement: canvas centred, controls flanking it in
    /// the gutters. Frames are normalised against the full screen.
    private static func landscapeItems(for profile: ArcadeProfile) -> [ControlLayout.Item] {
        var items: [ControlLayout.Item] = []

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
}
