import SwiftUI

/// Editing furniture: a measuring grid behind the controls.
///
/// Editor only, and it exists nowhere in the app. Layouts are
/// normalised 0 to 1, so the useful grid is fractions of the surface
/// rather than points: every twentieth reads as fine spacing, every
/// quarter as structure, and the centre lines are what a symmetric
/// pad is measured against.
///
/// Drawn under the controls on purpose. A grid over the top would
/// obscure the very thing being judged.
struct EditorGrid: View {
    /// The rect the layout is normalised against, which in portrait is
    /// the control strip rather than the whole screen.
    var area: CGRect

    var body: some View {
        Canvas { context, _ in
            guard area.width > 1, area.height > 1 else { return }

            func line(_ from: CGPoint, _ to: CGPoint, _ color: Color, _ width: CGFloat) {
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(color), lineWidth: width)
            }

            let fine = Color.white.opacity(0.06)
            let quarter = Color.white.opacity(0.13)
            let centre = Color.cyan.opacity(0.35)

            for step in 1..<20 {
                let t = CGFloat(step) / 20
                let heavy = step % 5 == 0
                let x = area.minX + area.width * t
                let y = area.minY + area.height * t
                if step != 10 {
                    line(CGPoint(x: x, y: area.minY), CGPoint(x: x, y: area.maxY),
                         heavy ? quarter : fine, heavy ? 1 : 0.5)
                    line(CGPoint(x: area.minX, y: y), CGPoint(x: area.maxX, y: y),
                         heavy ? quarter : fine, heavy ? 1 : 0.5)
                }
            }

            // The two centre lines, which is what symmetry is judged
            // against and the reason this grid exists at all.
            line(CGPoint(x: area.midX, y: area.minY), CGPoint(x: area.midX, y: area.maxY), centre, 1)
            line(CGPoint(x: area.minX, y: area.midY), CGPoint(x: area.maxX, y: area.midY), centre, 1)
        }
        .allowsHitTesting(false)
    }
}
