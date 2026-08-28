import SwiftUI

/// What a Virtual Boy screen colour actually looks like, without having
/// to start a game to find out.
///
/// A solid swatch answers the wrong question. The Virtual Boy drew in
/// four levels, black and three brightnesses of one colour, and the thing
/// worth knowing before you choose is whether the dark end still reads at
/// all. Cyan is legible all the way down; the original red is not, which
/// is half of why the other colours exist.
///
/// The subject is Cabinet's own icon, the cabinet with its marquee,
/// screen, three panel buttons and coin door, redrawn as the Virtual Boy
/// would have drawn it: black ground, everything else in one hue at the
/// three levels. Using the icon rather than an abstract pattern means the
/// shape is already familiar, so the eye is spending its attention on the
/// colour, which is the only thing being chosen here.
struct VirtualBoyPreview: View {
    /// A core option value like "black & red". Anything that is not a
    /// screen colour returns nil and the preview is simply not shown.
    let value: String

    /// Whether there is anything to draw for this value, screen colour
    /// or glasses, so a caller can choose between this and a plain
    /// swatch without drawing both.
    static func canDraw(_ value: String) -> Bool {
        let v = VirtualBoyPreview(value: value)
        return v.levels != nil || v.lensPair != nil || v.isFlat
    }

    static func isScreenColour(_ value: String) -> Bool {
        VirtualBoyPreview(value: value).levels != nil
    }

    /// "Off" on the glasses setting: the flat picture, drawn plainly so
    /// it reads as the absence of the effect beside the pairs.
    fileprivate var isFlat: Bool { value == "disabled" }

    /// A pair of lens colours, for the glasses setting. Distinguished
    /// from a screen colour by neither half being black.
    fileprivate var lensPair: (Color, Color)? {
        let parts = value.split(separator: "&").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard parts.count == 2, parts[0] != "black",
              let a = Self.named[parts[0]], let b = Self.named[parts[1]]
        else { return nil }
        return (a, b)
    }

    fileprivate static let named: [String: Color] = [
        "red": .red, "white": .white, "blue": .blue, "cyan": .cyan,
        "electric cyan": Color(red: 0.45, green: 1.0, blue: 1.0),
        "green": .green, "magenta": Color(red: 1.0, green: 0.0, blue: 1.0),
        "yellow": .yellow,
    ]

    /// The three lit levels above black, dimmest first.
    private var levels: [Color]? {
        let parts = value.split(separator: "&").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard parts.count == 2, parts[0] == "black",
              let hue = Self.named[parts[1]] else { return nil }
        return [hue.opacity(0.32), hue.opacity(0.66), hue]
    }

    var body: some View {
        Group {
            if let levels {
                framed { cabinet(levels: levels) }
            } else if let lensPair {
                // A real anaglyph, not an illustration of one. The same
                // machine is drawn twice a few points apart, once per
                // lens colour, added together on black exactly as the
                // core composites the two eyes. So the way to pick is to
                // hold your own glasses up to this: the pair that
                // resolves into depth instead of a coloured smear is the
                // pair you own. That is a question no swatch and no
                // colour name can answer, which is why this exists.
                framed {
                    ZStack {
                        depthScene(tint: lensPair.0, eye: -1)
                        depthScene(tint: lensPair.1, eye: 1)
                            .blendMode(.plusLighter)
                    }
                }
            } else if isFlat {
                // Off: the same scene with both eyes in the same place,
                // so it reads as the picture going flat rather than as
                // some other variety of the effect.
                framed { depthScene(tint: .white, eye: 0) }
            }
        }
    }

    /// A scene with actual depth in it, which the cabinet did not have.
    ///
    /// A flat silhouette shifted sideways puts every part of itself at
    /// one depth, so it proves the two colours are being separated and
    /// says nothing about whether depth is landing. This is a corridor
    /// running away from you with a diamond hanging in front of it: the
    /// rings carry a depth gradient from just off the glass to far
    /// behind it, and the diamond sits well in front of the screen so
    /// there is something unmistakably popping out to judge by.
    ///
    /// `eye` is -1, +1 or 0. Each element's offset is its own depth
    /// times the eye, which is the whole point: a uniform shift is not
    /// a stereo pair.
    private func depthScene(tint: Color, eye: CGFloat) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let maxP = w * 0.020
            ZStack {
                ForEach(0..<6, id: \.self) { i in
                    ring(i, w: w, h: h, tint: tint, eye: eye, maxP: maxP)
                }
                // The thing that should be floating between you and the
                // television if the glasses are the right pair.
                RoundedRectangle(cornerRadius: w * 0.012)
                    .fill(tint)
                    .frame(width: w * 0.10, height: w * 0.10)
                    .rotationEffect(.degrees(45))
                    .offset(x: eye * maxP * -1.15, y: h * 0.055)
            }
            .frame(width: w, height: h)
        }
    }

    /// One ring of the corridor. Split out because the whole scene in a
    /// single expression is more than the type checker will sit through.
    private func ring(
        _ i: Int, w: CGFloat, h: CGFloat,
        tint: Color, eye: CGFloat, maxP: CGFloat
    ) -> some View {
        let t = CGFloat(i) / 5
        // Near ring sits a little in front of the glass, far ring well
        // behind it.
        let depth: CGFloat = -0.25 + t * 1.25
        let shade: Double = 0.30 + 0.55 * Double(1 - t)
        let line: CGFloat = max(1, w * 0.008 * (1 - t * 0.55))
        let scale: CGFloat = 1 - t * 0.74
        return RoundedRectangle(cornerRadius: w * 0.02)
            .strokeBorder(tint.opacity(shade), lineWidth: line)
            .frame(width: w * 0.66 * scale, height: h * 0.66 * scale)
            .offset(x: eye * maxP * depth)
    }

    /// Half the separation between the eyes, in points at the drawn size.
    private var parallax: CGFloat { 3 }

    private func solid(_ c: Color) -> [Color] {
        [c.opacity(0.32), c.opacity(0.66), c]
    }

    private func framed<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black
            content()
        }
        .aspectRatio(384.0 / 224.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func cabinet(levels: [Color]) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Fractions taken off the icon so the proportions read as
            // the same machine, not a rectangle that happens to have
            // a bar on it.
            let bodyW = w * 0.50, bodyX = (w - bodyW) / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.035)
                    .fill(levels[0])
                    .frame(width: bodyW, height: h * 0.70)
                    .offset(x: bodyX, y: h * 0.13)
                RoundedRectangle(cornerRadius: w * 0.012)
                    .fill(levels[2])
                    .frame(width: bodyW * 0.78, height: h * 0.075)
                    .offset(x: bodyX + bodyW * 0.11, y: h * 0.175)
                RoundedRectangle(cornerRadius: w * 0.016)
                    .fill(levels[1])
                    .frame(width: bodyW * 0.78, height: h * 0.28)
                    .offset(x: bodyX + bodyW * 0.11, y: h * 0.285)
                HStack(spacing: bodyW * 0.10) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(levels[2]).frame(width: w * 0.045)
                    }
                }
                .offset(x: bodyX + bodyW * 0.16, y: h * 0.615)
                RoundedRectangle(cornerRadius: w * 0.008)
                    .fill(levels[1])
                    .frame(width: bodyW * 0.62, height: h * 0.045)
                    .offset(x: bodyX + bodyW * 0.19, y: h * 0.775)
            }
        }
    }
}
