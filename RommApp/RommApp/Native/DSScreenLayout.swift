import Foundation
import CoreGraphics

/// Geometry for the Nintendo DS's two screens, shared by the renderer
/// (which draws them) and the touch layer (which maps finger positions
/// on the bottom one into libretro pointer space). One source of truth
/// so the picture and the touch target can never drift apart.
///
/// melonDS is pinned to its Top/Bottom layout with a gap of zero
/// (NativeCoreOptions.forcedOptions), so the core always delivers one
/// 256x384 frame, both screens stacked, no dead rows. Presentation is
/// this app's job: the renderer slices that frame into two quads and
/// places them on a virtual canvas that inserts a small hinge break
/// between them, the way the real clamshell held its screens apart.
/// The break is drawn nowhere: it is simply canvas the quads leave
/// uncovered, so whatever sits behind the picture shows through.
enum DSScreenLayout {
    /// One DS screen, in the core's own pixels.
    static let screenWidth: CGFloat = 256
    static let screenHeight: CGFloat = 192

    /// The hinge break, in the same pixel units as the screens, so the
    /// gap scales with the picture instead of sitting at a fixed point
    /// size that would dominate a phone and vanish on a television.
    static let gapPixels: CGFloat = 10

    /// The virtual canvas both screens and the break stack into.
    static var canvasHeight: CGFloat { screenHeight * 2 + gapPixels }
    static var canvasAspect: CGFloat { screenWidth / canvasHeight }

    /// The canvas aspect-fit and centered in a view, in that view's own
    /// coordinates. Same fit the renderer performs in NDC.
    static func canvasRect(in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let viewAspect = size.width / size.height
        var w = size.width
        var h = size.height
        if canvasAspect > viewAspect {
            h = w / canvasAspect
        } else {
            w = h * canvasAspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Fraction of the canvas height one screen occupies, and where the
    /// bottom screen starts. Used by both the NDC quads and the rects.
    static var screenFraction: CGFloat { screenHeight / canvasHeight }
    static var bottomStartFraction: CGFloat { (screenHeight + gapPixels) / canvasHeight }

    static func topScreenRect(in size: CGSize) -> CGRect {
        let c = canvasRect(in: size)
        return CGRect(x: c.minX, y: c.minY, width: c.width, height: c.height * screenFraction)
    }

    static func bottomScreenRect(in size: CGSize) -> CGRect {
        let c = canvasRect(in: size)
        return CGRect(
            x: c.minX, y: c.minY + c.height * bottomStartFraction,
            width: c.width, height: c.height * screenFraction
        )
    }

    /// A point in the view mapped into libretro pointer space, where the
    /// core expects coordinates over its whole 256x384 frame, not over
    /// the bottom screen alone. Clamped into the bottom screen, so a
    /// drag that wanders past an edge keeps reporting the edge, the way
    /// a stylus pressed against the bezel would: melonDS's own touch
    /// containment (input.cpp) drops out-of-region samples entirely,
    /// which would make an edge drag flicker instead.
    ///
    /// x maps [left, right] to [-1, 1] over the frame's full width. The
    /// bottom screen is the frame's lower half, rows 192..384, so its
    /// [top, bottom] maps to [0, 1], not [-1, 1].
    static func pointer(for point: CGPoint, in size: CGSize) -> (x: Float, y: Float) {
        let r = bottomScreenRect(in: size)
        guard r.width > 0, r.height > 0 else { return (0, 0) }
        let u = min(max((point.x - r.minX) / r.width, 0), 1)
        let v = min(max((point.y - r.minY) / r.height, 0), 1)
        return (Float(u * 2 - 1), Float(v))
    }
}
