import CoreImage
import SwiftUI

/// EmulatorJS's own boot status, mirrored out of `.ejs_loading_text` verbatim
/// and split here into a phase and a percentage, never the other way around:
/// the phase text is localized and not safe to pattern match, but a trailing
/// "NN%" is a stable, language independent shape worth pulling out so the
/// bulb row below can show real progress instead of guessing at it.
struct LoadingStatus: Equatable {
    let phase: String
    let percent: Double?

    private static let percentPattern = try? NSRegularExpression(pattern: #"\s*(\d{1,3})%\s*$"#)

    init(raw: String) {
        guard let match = Self.percentPattern?.firstMatch(
            in: raw, range: NSRange(raw.startIndex..., in: raw)
        ), let range = Range(match.range(at: 1), in: raw), let value = Double(raw[range]) else {
            phase = raw
            percent = nil
            return
        }
        phase = String(raw[..<Range(match.range, in: raw)!.lowerBound])
        percent = min(1, max(0, value / 100))
    }
}

/// Covers the webview from the moment it starts loading until the game
/// reports started, the same "native curtain over an in-progress webview"
/// technique the crash recovery screen already uses. A cabinet marquee
/// warming up, not RomM's own loading bars: a row of bulbs stands in for a
/// progress bar, chasing when no real percentage has arrived yet and lit to
/// the real count once one has, and the status line underneath is
/// EmulatorJS's own phase text, not decoration, with the percentage cut off
/// since the bulbs already say that part.
struct BootCurtain: View {
    let title: String
    let status: LoadingStatus?
    /// Cover art to pull the glow's color from, `pathCoverLarge` falling
    /// back to `pathCoverSmall`, the same choice the launch screen makes.
    let coverPath: String?

    @EnvironmentObject private var session: Session
    @State private var tint = Self.defaultTint
    @State private var glowPulse = false
    @State private var chaseIndex = 0

    private static let defaultTint = Color(red: 1, green: 0.42, blue: 0.24)

    private let chaseTimer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // A fully opaque backstop first: the gradient above it is built
            // from real RGB blends, not alpha, but this guarantees nothing
            // under this curtain, RomM's own loading page included, can ever
            // bleed through regardless.
            Color.black.ignoresSafeArea()

            RadialGradient(
                colors: [
                    blend(tint, toward: .black, amount: 0.70),
                    blend(tint, toward: .black, amount: 0.84),
                    blend(tint, toward: .black, amount: 0.93),
                    Color(red: 0.04, green: 0.03, blue: 0.035), .black,
                ],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 10,
                endRadius: 340
            )
            .ignoresSafeArea()

            // Breaks up the 8 bit banding a slow radial fall into near black
            // shows on a real screen: invisible as a texture on its own,
            // present only to keep the gradient from stepping.
            NoiseTexture.image
                .resizable(resizingMode: .tile)
                .opacity(0.05)
                .blendMode(.overlay)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 18) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.5), tint.opacity(0.18), .clear],
                            center: .center, startRadius: 0, endRadius: 110
                        )
                    )
                    .frame(width: 220, height: 220)
                    .opacity(glowPulse ? 1 : 0.55)
                    .scaleEffect(glowPulse ? 1.04 : 0.94)
                    .blur(radius: 2)
                    .overlay {
                        Text(title.uppercased())
                            .font(.system(size: 19, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .shadow(color: tint.opacity(0.85), radius: 14)
                            .shadow(color: .white.opacity(0.5), radius: 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 32)
                    }

                bulbRow

                if let status {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(tint)
                            .frame(width: 5, height: 5)
                            .opacity(glowPulse ? 1 : 0.35)
                        Text(status.phase.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
        .onReceive(chaseTimer) { _ in
            guard status?.percent == nil else { return }
            chaseIndex = (chaseIndex + 1) % bulbCount
        }
        .task(id: coverPath) { await loadTint() }
    }

    private let bulbCount = 10

    private var bulbRow: some View {
        let litCount = status?.percent.map { Int(($0 * Double(bulbCount)).rounded()) }
        return HStack(spacing: 7) {
            ForEach(0..<bulbCount, id: \.self) { index in
                Circle()
                    .fill(bulbColor(index: index, litCount: litCount))
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: isBright(index: index, litCount: litCount) ? tint.opacity(0.85) : .clear,
                        radius: 5
                    )
            }
        }
    }

    private func isBright(index: Int, litCount: Int?) -> Bool {
        if let litCount { return index < litCount }
        return index == chaseIndex
    }

    private func bulbColor(index: Int, litCount: Int?) -> Color {
        if let litCount {
            return index < litCount ? tint : .white.opacity(0.14)
        }
        return index == chaseIndex ? .white : .white.opacity(0.14)
    }

    /// The marquee's color, pulled from the game's own box art rather than
    /// carried as one fixed hue for every game. A raw average tends muddy,
    /// box art skews dark and desaturated more often than not, so the result
    /// is pushed to a minimum saturation and brightness before it is trusted
    /// as a glow: this is a light standing in for the game, not a swatch.
    private func loadTint() async {
        guard let coverPath else { return }
        guard let data = try? await session.coverData(path: coverPath),
              let image = UIImage(data: data),
              let average = image.averageColor()
        else { return }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let vivid = UIColor(
            hue: hue, saturation: max(saturation, 0.55), brightness: max(brightness, 0.6), alpha: 1
        )
        withAnimation(.easeInOut(duration: 0.4)) {
            tint = Color(vivid)
        }
    }

    /// A real RGB mix at full alpha, never `.opacity()`: alpha is
    /// transparency, not darkness, and blending toward black through alpha
    /// is exactly what let RomM's own page ghost through the gradient
    /// underneath it.
    private func blend(_ color: Color, toward target: Color, amount: CGFloat) -> Color {
        let a = UIColor(color)
        let b = UIColor(target)
        var (ar, ag, ab, aa) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        var (br, bg, bb, ba) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(
            red: ar + (br - ar) * amount,
            green: ag + (bg - ag) * amount,
            blue: ab + (bb - ab) * amount
        )
    }
}

private extension UIImage {
    /// `CIAreaAverage`, Core Image's own single pixel reduction, rather than
    /// a hand rolled downsample: it is the standard, fast way to reduce a
    /// whole image to one representative color.
    func averageColor() -> UIColor? {
        guard let input = CIImage(image: self) else { return nil }
        let extent = CIVector(
            x: input.extent.origin.x, y: input.extent.origin.y,
            z: input.extent.size.width, w: input.extent.size.height
        )
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input, kCIInputExtentKey: extent,
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(
            output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil
        )
        return UIColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255, alpha: CGFloat(pixel[3]) / 255
        )
    }
}

/// A small tile of random gray values, generated once, to dither the boot
/// curtain's gradient. Cheap enough to build at launch: 64x64 pixels, drawn
/// once, reused for every game rather than regenerated per boot.
private enum NoiseTexture {
    static let image: Image = {
        let size = 64
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let uiImage = renderer.image { context in
            for y in 0..<size {
                for x in 0..<size {
                    let value = CGFloat.random(in: 0...1)
                    context.cgContext.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                    context.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return Image(uiImage: uiImage)
    }()
}
