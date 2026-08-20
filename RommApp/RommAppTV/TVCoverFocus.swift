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
/// The caption slide for a cover card. `CoverFocusStyle` scales a
/// focused card 1.10 about its centre, so the card's bottom edge
/// advances by five percent of the cover height; a caption sitting
/// under the card gets buried under that growth (reported 2026-08-20,
/// Smash T.V. on the Recent shelf). Sliding the caption down by the
/// same amount keeps it clear, the way the TV app's own shelf titles
/// ride down with a lifted poster. Unfocused, layout is untouched.
///
/// The 0.05 here IS half of the style's 1.10 minus one; if the scale
/// in CoverFocusStyle ever changes, change this with it.
extension View {
    func coverCaptionSlide(active: Bool, coverHeight: CGFloat) -> some View {
        offset(y: active ? coverHeight * 0.05 + 2 : 0)
            .animation(.easeOut(duration: 0.18), value: active)
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

/// Focus for a full-width settings-style row (Settings' own action/info
/// rows, Native Cores' platform list): a real glass background that is
/// always visible, not just conjured on focus, plus a modest tint and
/// scale when focused.
///
/// `.plain` looked like the safe choice for these rows since it has no
/// visible plate when unstyled, but tvOS's own default focus effect for
/// `.plain` is not "no effect": it paints a solid white plate over
/// whatever background the row already has, and its own scale growth
/// reserves no headroom, so a focused row can grow wide enough to
/// overlap its neighbour. Both symptoms are the exact ones
/// `CoverFocusStyle`/`TextFocusStyle` already exist to avoid; this is
/// the same fix for a row that needs a background at rest, not only
/// when focused.
struct RowFocusStyle: ButtonStyle {
    var cornerRadius: CGFloat = 16

    func makeBody(configuration: Configuration) -> some View {
        FocusBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct FocusBody: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .background {
                    if #available(tvOS 26.0, *) {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(.clear)
                            .glassEffect(
                                isFocused ? .regular.tint(.white.opacity(0.22)) : .regular,
                                in: RoundedRectangle(cornerRadius: cornerRadius)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(isFocused ? AnyShapeStyle(.white.opacity(0.18)) : AnyShapeStyle(.ultraThinMaterial))
                    }
                }
                // A restrained scale, matching the rest of the app's own
                // focus effects, not the system default's larger jump
                // that had no reserved headroom and grew into the next
                // row.
                .scaleEffect(isFocused ? 1.03 : 1.0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}

extension View {
    /// The opaque backdrop a `fullScreenCover` needs on tvOS, which paints
    /// none of its own (without this, the screen underneath shows straight
    /// through, and the two read as one garbled screen). A subtle dark
    /// gradient rather than flat `Color.black`: the account switcher and
    /// PIN screens have no game art to blur into an ambient backdrop the
    /// way `TVGameLaunchView`'s black base does, and flat black with
    /// nothing over it reads as a dead, unfinished screen next to
    /// everything else in this app's glass-on-dark look.
    func tvModalBackdrop() -> some View {
        background(
            LinearGradient(
                colors: [Color(white: 0.13), Color(white: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}
