#if os(tvOS)
import SwiftUI

/// The letterbox glow's one setting. Landed here 2026-08-13 after tuning
/// live on a real panel with a slider: two earlier guessed-from-a-mockup
/// preset sets were wrong on device (bleeding into the picture, banding,
/// not reaching the outer edge), so a continuous slider replaced them to
/// find real numbers, then Marcus called the final values, Off/Subtle
/// 5%/Strong 8% peak opacity, reach fixed at 100% (the ramp always
/// travels the full dead space to the physical screen edge; a separate
/// reach slider was tried and dropped once 100% was confirmed as the
/// only value worth keeping).
enum BiasGlowLevel: String, CaseIterable, Identifiable {
    case off
    case subtle
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .strong: return "Strong"
        }
    }

    /// Peak white opacity right at the game's edge. 5% and 8% here are
    /// fractions of the 0.5 ceiling the tuning slider offered, matching
    /// what read correctly on device: raw 0.025 and 0.04.
    var opacity: Double {
        switch self {
        case .off: return 0
        case .subtle: return 0.025
        case .strong: return 0.04
        }
    }

    static let storageKey = "com.mmagtech.RommAppTV.biasGlowLevel"

    /// Migrates every retired storage shape (the two earlier preset
    /// enums, and the tuning build's raw opacity/reach doubles) onto the
    /// closest current level, so nobody's saved choice gets silently
    /// reset by a naming change.
    static func level(fromStored raw: String) -> BiasGlowLevel {
        if let level = BiasGlowLevel(rawValue: raw) { return level }
        if let opacity = Double(raw) {
            return opacity <= 0 ? .off : (opacity < 0.03 ? .subtle : .strong)
        }
        switch raw {
        case "off", "zero": return .off
        case "one", "two": return .subtle
        case "three", "four", "five": return .strong
        default: return .subtle
        }
    }
}

/// A soft neutral-white bleed off the edges of the letterboxed game
/// picture, in-software bias lighting for the seam retro aspect ratios
/// create inside the panel, where a physical strip behind the TV cannot
/// reach. White on purpose: it adds luminance without hue, so it can
/// never clash with whatever the game is rendering, and the panel's own
/// calibration keeps it matched to the picture's white point for free.
///
/// Layered on top of `TVGameSurface` rather than behind it, because the
/// Metal view paints the whole screen including the black bars; over
/// pure black the two orderings look identical, and this way the shared
/// renderer's draw path is untouched. Each bar's gradient starts exactly
/// at the fitted game edge and spans the whole dead space to the screen
/// edge, with no blur, so not one game pixel is ever covered.
///
/// Two things fight banding, the visible stepping an 8-bit panel makes
/// of any long near-black ramp: the gradient's stops follow a slow
/// power curve rather than a straight line (flat start, shallow
/// exponent, so brightness carries further toward the physical edge
/// instead of collapsing early), and a static tiled noise texture is
/// composited into the glow, masked by the same ramp and scaled with
/// opacity so it stays a quiet dither rather than its own visible
/// texture. The noise is generated once, never animated.
///
/// The rect comes from the renderer's published `displayAspect`, the
/// same value the picture itself is fitted with, so 4:3 consoles, Game
/// Boy's near-square picture, rotated TATE boards and mid-game
/// resolution switches all place the glow correctly with no cases here.
/// A picture that fills the screen leaves no dead space and the glow
/// simply has nowhere to draw.
struct TVBiasGlow: View {
    @ObservedObject var renderer: NativePlayerRenderer
    let level: BiasGlowLevel

    var body: some View {
        GeometryReader { geo in
            let aspect = renderer.displayAspect
            let opacity = level.opacity
            if opacity > 0, aspect > 0, geo.size.width > 0, geo.size.height > 0 {
                let rect = fittedRect(aspect: aspect, in: geo.size)
                ZStack {
                    if rect.minX > 1 {
                        barGlow(opacity: opacity, size: CGSize(width: rect.minX, height: geo.size.height), from: .trailing)
                            .position(x: rect.minX / 2, y: geo.size.height / 2)
                        barGlow(opacity: opacity, size: CGSize(width: geo.size.width - rect.maxX, height: geo.size.height), from: .leading)
                            .position(x: (rect.maxX + geo.size.width) / 2, y: geo.size.height / 2)
                    }
                    if rect.minY > 1 {
                        barGlow(opacity: opacity, size: CGSize(width: rect.width, height: rect.minY), from: .bottom)
                            .position(x: rect.midX, y: rect.minY / 2)
                        barGlow(opacity: opacity, size: CGSize(width: rect.width, height: geo.size.height - rect.maxY), from: .top)
                            .position(x: rect.midX, y: (rect.maxY + geo.size.height) / 2)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// One bar's glow: the eased white ramp, with the dither noise
    /// composited additively and masked by the same ramp shape so it
    /// fades with the glow.
    private func barGlow(opacity: Double, size: CGSize, from edge: UnitPoint) -> some View {
        let opposite = Self.opposite(of: edge)
        return Rectangle()
            .fill(Self.easedGradient(peak: opacity, from: edge, to: opposite))
            .overlay {
                Image(uiImage: Self.noise)
                    .resizable(resizingMode: .tile)
                    .opacity(opacity * 0.25)
                    .blendMode(.plusLighter)
                    .mask {
                        Rectangle()
                            .fill(Self.easedGradient(peak: 1, from: edge, to: opposite))
                    }
            }
            .compositingGroup()
            .frame(width: size.width, height: size.height)
    }

    private static func opposite(of edge: UnitPoint) -> UnitPoint {
        switch edge {
        case .leading: return .trailing
        case .trailing: return .leading
        case .top: return .bottom
        default: return .top
        }
    }

    /// A white-to-clear ramp whose stops follow a slow power curve, the
    /// full dead-space bar to the screen edge (reach is fixed at 100%,
    /// confirmed on device 2026-08-13). The flat start (derivative zero
    /// at t=0) keeps the panel's banding-prone darkest levels spread
    /// over many quantization steps instead of one; the shallow
    /// exponent stretches the falloff further out so brightness carries
    /// closer to the physical edge instead of collapsing early.
    private static func easedGradient(peak: Double, from start: UnitPoint, to end: UnitPoint) -> LinearGradient {
        let stops = stride(from: 0.0, through: 1.0, by: 0.05).map { t -> Gradient.Stop in
            let s = pow(t, 1.7)
            return Gradient.Stop(color: .white.opacity(peak * (1 - s)), location: t)
        }
        return LinearGradient(stops: stops, startPoint: start, endPoint: end)
    }

    /// A small grayscale noise tile, generated once per launch. Static,
    /// never animated: its only job is to sit inside the ramp and break
    /// up quantization bands, the same dither every video pipeline uses
    /// on shallow gradients.
    private static let noise: UIImage = {
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices {
            pixels[i] = UInt8.random(in: 0...255)
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: side, height: side,
                  bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent
              )
        else { return UIImage() }
        return UIImage(cgImage: cgImage)
    }()

    /// The same aspect-fit the renderer applies in Metal clip space,
    /// redone in view coordinates.
    private func fittedRect(aspect: Double, in size: CGSize) -> CGRect {
        let viewAspect = Double(size.width / size.height)
        var fitted = size
        if aspect > viewAspect {
            fitted.height = size.width / CGFloat(aspect)
        } else {
            fitted.width = size.height * CGFloat(aspect)
        }
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height
        )
    }
}
#endif
