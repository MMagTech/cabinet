import CoreGraphics
import Foundation

/// A control layout, loaded from a bundled JSON file. Layouts are data, not
/// code: adding a system is a file, not a view hierarchy.
///
/// All frames are normalised 0 to 1 against the control strip the host hands
/// the pad view, not the screen, so one layout serves every phone size.
/// Every element carries two rects, per DeltaCore's model: `frame` is what
/// gets drawn, `extended` is what gets hit tested. The gap between them is
/// the single highest impact detail in how touch controls feel.
struct ControlLayout: Decodable {
    let system: String
    let items: [Item]

    struct Item: Decodable {
        enum Kind: String, Decodable {
            case dpad, button, pill
        }

        let kind: Kind
        let label: String?
        /// RetroArch device id for single controls (B 0, Select 2, Start 3,
        /// A 8, L 10, R 11), confirmed against the EmulatorJS 4.2.3 bundle.
        let input: Int?
        /// D-pad only: up, down, left, right, in that order.
        let inputs: [Int]?
        let frame: Rect
        let extended: Rect
    }

    struct Rect: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        func resolved(in size: CGSize) -> CGRect {
            CGRect(
                x: x * size.width,
                y: y * size.height,
                width: w * size.width,
                height: h * size.height
            )
        }
    }

    /// The layout for a platform slug, falling back to the generic pad.
    /// One file per system under Resources/ControlLayouts.
    static func forPlatform(slug: String) -> ControlLayout? {
        let name: String
        switch slug {
        case "gb", "gbc", "dmg": name = "gb"
        default: name = "default"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else {
            assertionFailure("Missing or invalid control layout \(name).json")
            return nil
        }
        return layout
    }
}
