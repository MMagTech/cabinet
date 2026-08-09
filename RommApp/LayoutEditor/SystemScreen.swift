import SwiftUI
import UIKit

/// The game picture a layout is being placed around.
///
/// Buttons dragged over an empty background drift toward the middle of the
/// screen, because nothing pushes back. Real layouts have to live beside the
/// picture, so the editor puts the picture there: same aspect ratio the core
/// outputs, aspect fit inside the same rect the player gives its canvas.
enum SystemScreen {
    /// Native display aspect, width over height. The consoles all output to a
    /// 4:3 television whatever their pixel grid says; the handhelds are their
    /// own panel and nothing else.
    static func aspect(for layout: String) -> CGFloat {
        switch layout {
        case "gb": return 160.0 / 144.0
        case "gamegear": return 160.0 / 144.0
        case "gba": return 240.0 / 160.0
        case "lynx": return 160.0 / 102.0
        case "ngpc": return 160.0 / 152.0
        case "wonderswan": return 224.0 / 144.0
        case "psp": return 480.0 / 272.0
        // Both DS panels stacked, which is what the player shows.
        case "nds": return 256.0 / 384.0
        default: return 4.0 / 3.0
        }
    }

    /// A real captured frame for this system, or nil.
    ///
    /// Two places are checked. Bundled art lives in `LayoutEditor/Screens` as
    /// `screen-<layout>.png`. Anything dropped into the editor's Documents
    /// folder in Files wins over it, so a better frame can be tried without
    /// rebuilding, which is the same reason the working copies live there.
    static func image(for layout: String) -> UIImage? {
        let dropped = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screens/\(layout).png")
        if let data = try? Data(contentsOf: dropped), let image = UIImage(data: data) {
            return image
        }
        return UIImage(named: "screen-\(layout)")
    }
}

/// The picture, aspect fit inside whatever rect the player would give the
/// canvas, with the rest of that rect black exactly as the player leaves it.
struct ScreenBackdrop: View {
    let layout: String
    /// Drawn dimmer than life so controls stay readable while placing them.
    var dim: Double = 0.55

    var body: some View {
        ZStack {
            Color.black
            if let image = SystemScreen.image(for: layout) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .opacity(1 - dim)
            } else {
                PlaceholderScreen(layout: layout)
                    .aspectRatio(SystemScreen.aspect(for: layout), contentMode: .fit)
                    .opacity(1 - dim * 0.5)
            }
        }
    }
}

/// Stands in until a real captured frame is dropped in, and says so rather
/// than pretending. The aspect ratio is still the real one, so button
/// placement against the edges of the picture is already honest.
private struct PlaceholderScreen: View {
    let layout: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.10)],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { geo in
                Path { path in
                    let step = max(geo.size.width, geo.size.height) / 16
                    var x = step
                    while x < geo.size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        x += step
                    }
                    var y = step
                    while y < geo.size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        y += step
                    }
                }
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
            }
            VStack(spacing: 4) {
                Text(layout)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                Text("drop screen-\(layout).png into Screens")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Color.white.opacity(0.35))
        }
        .overlay(Rectangle().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}
