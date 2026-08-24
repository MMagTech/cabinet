import SwiftUI

/// Editing furniture: a measuring grid behind the controls.
///
/// Editor only, and it exists nowhere in the app.
///
/// SQUARE cells, which is the whole point of it. Layouts are
/// normalised 0 to 1 in each axis independently, so a grid of
/// twentieths draws cells as oblong as the surface is, and two gaps
/// that measure the same in layout units look different on screen.
/// Marcus is judging distance between buttons by eye, so the grid has
/// to measure in one unit both ways: a cell is a fixed number of
/// POINTS square, laid out from the centre so the two axes agree.
///
/// Yellow because the first version was white and cyan, which
/// disappeared against the paler grounds. Yellow survives every
/// background these panels use, and it is a colour no control is
/// drawn in, so the grid can never be mistaken for a control.
struct EditorGrid: View {
    /// The rect the layout is normalised against, which in portrait is
    /// the control strip rather than the whole screen.
    var area: CGRect

    /// Cell side in points. Twelve or so cells down the shorter axis
    /// reads as a measuring grid rather than as graph paper.
    private var cell: CGFloat { max(min(area.width, area.height) / 12, 16) }

    var body: some View {
        Canvas { context, _ in
            guard area.width > 1, area.height > 1 else { return }

            func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat) {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                context.stroke(path, with: .color(color), lineWidth: width)
            }

            let fine = Color.yellow.opacity(0.13)
            let heavy = Color.yellow.opacity(0.30)
            let centre = Color.yellow.opacity(0.75)

            // Out from the centre in both directions, so the grid is
            // symmetric about the same axes a symmetric pad is.
            var step = 1
            while CGFloat(step) * cell < max(area.width, area.height) / 2 + cell {
                let offset = CGFloat(step) * cell
                let strong = step % 4 == 0
                for x in [area.midX - offset, area.midX + offset] where x > area.minX && x < area.maxX {
                    line(CGPoint(x: x, y: area.minY), CGPoint(x: x, y: area.maxY),
                         strong ? heavy : fine, strong ? 1 : 0.5)
                }
                for y in [area.midY - offset, area.midY + offset] where y > area.minY && y < area.maxY {
                    line(CGPoint(x: area.minX, y: y), CGPoint(x: area.maxX, y: y),
                         strong ? heavy : fine, strong ? 1 : 0.5)
                }
                step += 1
            }

            // The two centre lines, which is what symmetry is judged
            // against and the reason this grid exists at all.
            line(CGPoint(x: area.midX, y: area.minY), CGPoint(x: area.midX, y: area.maxY), centre, 1.2)
            line(CGPoint(x: area.minX, y: area.midY), CGPoint(x: area.maxX, y: area.midY), centre, 1.2)
        }
        .allowsHitTesting(false)
    }
}
