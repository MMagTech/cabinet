import SwiftUI

/// The Nintendo DS bottom screen, drawn where the companion panel will
/// actually put it.
///
/// Editor furniture, like the grid: it exists nowhere in the app and
/// takes no touches. DS is the one system where the phone is not purely
/// a controller. It holds the game's touch screen, streamed from the
/// television, and the controls have to live around that rather than
/// wherever there is room. Without seeing the screen you are arranging
/// controls around an obstacle you cannot see.
///
/// The geometry is the same expression DSPanelTouchSurface uses, not an
/// approximation of it: width is the lesser of two thirds of the
/// panel's height at 4:3, and 44% of its width; height follows at 3:4;
/// and it sits dead centre. If that ever changes, this has to change
/// with it, which is why the numbers are written the same way in both
/// places rather than pre-multiplied here.
struct DSScreenGuide: View {
    var area: CGRect

    static func rect(in size: CGSize) -> CGRect {
        let w = min(size.height * 0.66 * 4 / 3, size.width * 0.44)
        let h = w * 3 / 4
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    var body: some View {
        let r = Self.rect(in: area.size)
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.cyan.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
            .overlay(alignment: .top) {
                Text("bottom screen")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.7))
                    .padding(.top, 6)
            }
            .frame(width: r.width, height: r.height)
            .position(x: area.minX + r.midX, y: area.minY + r.midY)
            .allowsHitTesting(false)
    }
}
