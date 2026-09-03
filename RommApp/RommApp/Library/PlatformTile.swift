import SwiftUI

/// The platform tile: a name and a count over two covers. Extracted from
/// LibraryScreen so the Mac's Downloaded screen draws the identical tile
/// rather than a second one built to look like it. Owns everything about
/// how the tile is drawn and nothing about where it navigates; the
/// screen wraps it in its own NavigationLink.
struct PlatformTile: View {
    let title: String
    let count: Int
    let covers: [String]

    static var height: CGFloat {
        #if targetEnvironment(macCatalyst)
        110
        #else
        96
        #endif
    }

    /// Desk-distance type on the Mac tile, phone sizes elsewhere.
    private static var titleFont: Font {
        #if targetEnvironment(macCatalyst)
        .title3.weight(.semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    private static var countFont: Font {
        #if targetEnvironment(macCatalyst)
        .footnote
        #else
        .caption2
        #endif
    }

    var body: some View {
            ZStack(alignment: .bottomLeading) {
                backdrop(covers: covers)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Self.titleFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                    Text("\(count) games")
                        .font(Self.countFont)
                        .foregroundStyle(.white.opacity(0.65))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                }
                .padding(11)
            }
            .frame(height: Self.height)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .animation(.easeOut(duration: 0.35), value: covers)
    }

    /// The tile's art: two covers filling the trailing side edge to edge,
    /// with the label zone kept a flat opaque panel that fades out over
    /// the art. Proportional, never fixed points: the label zone is a
    /// fraction of the tile's own width, so the same tile works on any
    /// phone or pad width. The lesson came from the tvOS tile, where
    /// fixed widths squeezed "Arcade" until it hyphenated.
    private func backdrop(covers: [String]) -> some View {
        GeometryReader { geo in
            // Where the covers start, as a fraction of the tile. The
            // label overhangs into the faded region for long names, which
            // is why the gradient's first stretch stays mostly opaque.
            let labelZone = geo.size.width * 0.42
            ZStack(alignment: .leading) {
                Self.panel
                if !covers.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(covers.prefix(2).enumerated()), id: \.offset) { _, path in
                            CoverImage(path: path, title: "", showsPlaceholder: false)
                                .frame(
                                    width: (geo.size.width - labelZone) / 2,
                                    height: geo.size.height
                                )
                                .clipped()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    // A solid fill for the label zone rather than the
                    // gradient's own opaque stop: on the tvOS tile an
                    // interpolated "opaque" stop left a per-platform
                    // hairline of art color at the tile's edge, and a
                    // plain Rectangle has no interpolation to get wrong.
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Self.panel)
                            .frame(width: labelZone)
                        LinearGradient(
                            stops: [
                                .init(color: Self.panel, location: 0),
                                .init(color: Self.panel.opacity(0.8), location: 0.28),
                                .init(color: Self.panel.opacity(0), location: 0.8),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    /// The same panel value the tvOS tile settled on, and deliberately
    /// darker and less saturated than the approved mockup's purple: the
    /// same sRGB values render far more vividly on a wide-gamut display,
    /// which is how the first tvOS build came out a loud electric purple.
    private static let panel = Color(red: 0.14, green: 0.10, blue: 0.24)
}
