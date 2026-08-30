import SwiftUI

/// The Dreamcast VMU window, drawn where the companion panel will
/// actually put it.
///
/// Editor furniture, like `DSScreenGuide` and the grid: it exists
/// nowhere in the app and takes no touches. Dreamcast is the second
/// system where the phone is not purely a controller. It shows player
/// one's VMU LCD, streamed from the machine running the game, sitting
/// where the real controller's window sat.
///
/// Unlike the DS screen this is not a positioned element and cannot be
/// moved: `ControllerPadView` pins it as a fixed 120x84 overlay, top
/// centre, 40pt down, for `system == "dreamcast"` alone. So this guide
/// is not something to arrange, it is an obstacle to arrange around,
/// and without it you are laying controls into a space that is already
/// occupied by something the editor never draws.
///
/// The numbers are written the same way they are written in
/// `VMUCompanionWindow` and its overlay rather than pre-multiplied
/// here, so that if the window ever moves this has to move with it.
struct VMUGuide: View {
    var area: CGRect

    /// Matches ControllerPadView: `.overlay(alignment: .top)` with a
    /// 40pt inset, around a 120x84 window.
    static let windowSize = CGSize(width: 120, height: 84)
    static let topInset: CGFloat = 40

    static func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: (size.width - windowSize.width) / 2,
            y: topInset,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    var body: some View {
        let r = Self.rect(in: area.size)
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.orange.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.orange.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
            )
            .overlay(alignment: .bottom) {
                // Below the box rather than inside it: at 120x84 there
                // is no room for a caption without covering the thing
                // the caption is describing.
                Text("VMU")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.orange.opacity(0.7))
                    .offset(y: 14)
            }
            .frame(width: r.width, height: r.height)
            .position(x: area.minX + r.midX, y: area.minY + r.midY)
            .allowsHitTesting(false)
    }
}
