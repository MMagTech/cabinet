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

        // The stick. Four way games actively suppress diagonals, which
        // matters for the Pac-Man and Donkey Kong family.
        items.append(ControlLayout.Item(
            kind: .dpad,
            label: nil,
            input: nil,
            inputs: [4, 5, 6, 7],
            frame: ControlLayout.Rect(x: 0.04, y: 0.16, w: 0.40, h: 0.50),
            extended: ControlLayout.Rect(x: 0.00, y: 0.08, w: 0.48, h: 0.66),
            fourWay: profile.isFourWay
        ))

        items.append(contentsOf: actionButtons(count: max(0, min(profile.buttons, 6))))

        // Coin, primary, and Start beside it.
        items.append(ControlLayout.Item(
            kind: .button,
            label: "Coin",
            input: 2,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.06, y: 0.78, w: 0.15, h: 0.19),
            extended: ControlLayout.Rect(x: 0.02, y: 0.74, w: 0.22, h: 0.26),
            fourWay: nil
        ))
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Start",
            input: 3,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.30, y: 0.84, w: 0.20, h: 0.10),
            extended: ControlLayout.Rect(x: 0.26, y: 0.79, w: 0.27, h: 0.19),
            fourWay: nil
        ))

        return ControlLayout(system: "arcade:\(profile.profile)", items: items)
    }

    /// Action buttons on the right side. One row for up to three, two rows
    /// of three above each other for more, matching cabinet muscle memory.
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
                frame: ControlLayout.Rect(x: x, y: y, w: 0.14, h: 0.19),
                extended: ControlLayout.Rect(x: x - 0.035, y: y - 0.05, w: 0.21, h: 0.29),
                fourWay: nil
            )
        }

        if count <= 4 {
            // A rising arc from lower left to upper right, thumb shaped.
            let positions: [(Double, Double)] = [
                (0.52, 0.38), (0.66, 0.24), (0.80, 0.12), (0.84, 0.40),
            ]
            for index in 0..<count {
                let (x, y) = positions[index]
                items.append(button(
                    id: singleRowIds[index], label: "\(index + 1)", x: x, y: y
                ))
            }
        } else {
            // Two rows of three.
            let columns: [Double] = [0.52, 0.68, 0.84]
            for index in 0..<count {
                let row = index / 3
                let column = index % 3
                items.append(button(
                    id: doubleRowIds[index],
                    label: "\(index + 1)",
                    x: columns[column],
                    y: row == 0 ? 0.12 : 0.40
                ))
            }
        }

        return items
    }
}
