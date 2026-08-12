#if os(tvOS)
import SwiftUI

/// The focus treatment for a piece of cover art.
///
/// tvOS's own `.plain`/`.card` button styles paint a solid white plate
/// behind the focused label. Behind a photograph that plate is invisible,
/// but around one it reads as a hard white slab, which is what a shelf of
/// covers looks like when you cycle across it. This keeps the parts of the
/// system effect that communicate focus (the lift, the shadow, the sense
/// of the card coming forward) and replaces the plate with a translucent
/// rim, so the artwork stays the brightest thing on screen.
///
/// Not a general-purpose style: it assumes its label is a rounded piece of
/// art, which is why the rim is drawn as a rounded rectangle rather than
/// following an arbitrary shape.
struct CoverFocusStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    /// Whether the ring should draw at all. Real cover art (a shelf card,
    /// a grid tile: the label is not part of the button's own bounds)
    /// wants the ring, it is what makes a rounded piece of art read as
    /// selected. A composite label that mixes art with its own text (the
    /// library's platform tiles) does not: the ring is a rectangle drawn
    /// around the whole button, and on any tile it always crosses the
    /// text somewhere, not just where a light cover happened to make it
    /// visible. That was found on Neo Geo Pocket Color, whose cover is
    /// nearly white so a 4pt line drawn over pale text and a busy
    /// background stood out; it was equally present on every other tile,
    /// including ones (Game Boy Color) where a plain dark scrim behind
    /// the label happened to hide it. Same bug everywhere, visible on
    /// some. The scale and shadow still communicate focus perfectly well
    /// on their own without it.
    var showsRing: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration, cornerRadius: cornerRadius, showsRing: showsRing)
    }

    private struct FocusBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let showsRing: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .clipShape(.rect(cornerRadius: cornerRadius))
                .overlay {
                    if showsRing {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(.white.opacity(isFocused ? 0.85 : 0), lineWidth: 4)
                    }
                }
                // Pressed reads as a small push *into* the screen, against
                // the focused lift, so a click still feels like one even
                // though the card is already raised.
                .scaleEffect(configuration.isPressed ? 1.02 : (isFocused ? 1.10 : 1.0))
                .shadow(
                    color: .black.opacity(isFocused ? 0.55 : 0),
                    radius: isFocused ? 26 : 0,
                    y: isFocused ? 14 : 0
                )
                .animation(.easeOut(duration: 0.18), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif

/// Focus for a text link or textual control, such as a shelf's
/// "Recent >" header, or a list of save states to choose between.
///
/// tvOS's own `.borderless` style draws a rounded plate behind whatever it
/// is given, which around a small chevron glyph becomes a grey disc that
/// sits on top of the neighbouring letters, and its default (no style at
/// all) focus treatment is worse: a flat, hard-edged plate with no glass
/// whatsoever, the "Continue from" save-state buttons had before this
/// existed. A flat plate was the problem, not the idea of drawing
/// something behind the label at all: this is navigation and selection
/// chrome, not artwork, the same category as the library switcher's
/// pills, so real Liquid Glass belongs here the way it doesn't belong on
/// a cover. On tvOS 26 a glass shape fades in behind the label on focus;
/// tvOS 18 keeps the plain tint-and-lift it always had, since
/// `glassEffect` doesn't exist there.
struct TextFocusStyle: ButtonStyle {
    /// Capsule for a short single-line label ("Recent >"). A save-state
    /// button's two-line block reads oddly under a fully rounded capsule,
    /// so it passes a smaller radius for a plain rounded rect instead.
    var cornerRadius: CGFloat = 999

    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct FocusBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    if #available(tvOS 26.0, *), isFocused {
                        // Plain .regular glass read as barely-there over
                        // a smooth backdrop: blurring a near-uniform
                        // colour looks almost the same as the colour
                        // itself, so there was nothing to visibly
                        // refract. The white tint gives it a floor, the
                        // same way the switcher's own selected pill
                        // isn't bare .regular either.
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.clear)
                            .glassEffect(
                                .regular.tint(.white.opacity(0.25)),
                                in: RoundedRectangle(cornerRadius: cornerRadius)
                            )
                    }
                }
                .scaleEffect(isFocused ? 1.06 : 1.0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
