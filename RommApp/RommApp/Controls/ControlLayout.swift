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
    /// Portrait items, normalised against the bottom control strip.
    let items: [Item]
    /// Landscape items, normalised against the full screen, placed in the
    /// gutters flanking the centred canvas. Optional: a layout without them
    /// falls back to portrait items, which will look wrong but still work.
    let landscapeItems: [Item]?
    /// Extra portrait strip height, as a fraction of the normal strip, for
    /// pads too crowded to fit in it (N64's stick, d-pad, four face buttons,
    /// C cluster and three shoulders is a lot more than a two button Game
    /// Boy pad). Zero for every layout that does not opt in, which keeps
    /// their coordinates exactly what they have always meant: this only
    /// grows the strip a layout is normalised against when the layout asks
    /// for it, so nothing else in the library shifts.
    let headroom: Double?

    func items(landscape: Bool) -> [Item] {
        // Nil coalescing alone would hand back an empty landscape array as
        // though it were a real layout, leaving nothing to draw and nothing
        // to touch. Empty falls back the same as missing.
        guard landscape, let wide = landscapeItems, !wide.isEmpty else { return items }
        return wide
    }

    struct Item: Decodable {
        enum Kind: String, Decodable {
            /// A continuous analog control. Unlike every other kind here,
            /// its ids are not RetroPad button ids: EmulatorJS reads a
            /// stick through `GameManager.simulateInput` at four dedicated
            /// indices, one per direction, each carrying a magnitude from
            /// 0 to 0x7fff rather than a boolean down/up. Confirmed against
            /// EmulatorJS's own on screen stick, `data/src/emulator.js`,
            /// not assumed from the RetroPad table above.
            case dpad, button, pill, stick
            /// A dial you roll: relative rotation into the frontend's
            /// mouse channel, for the spinner/paddle-knob cabinets.
            case spinner
            /// A ball you flick: relative x/y with momentum, same
            /// channel, both axes.
            case trackball
            /// A wheel you turn: absolute steering angle from the phone's
            /// roll, gravity-referenced so it never drifts, into the
            /// analog stick's x axis the driving cores already read.
            case wheel
            /// A pedal: a pressure pad reported as an analog axis rather
            /// than a button, so a feathered throttle is possible.
            case pedal
            /// Point at the picture itself: absolute coordinates into the
            /// frontend's pointer channel, which is what a lightgun means
            /// on a touchscreen.
            case gun
        }

        let kind: Kind
        let label: String?
        /// RetroArch device id for single controls (B 0, Select 2, Start 3,
        /// A 8, L 10, R 11), confirmed against the EmulatorJS 4.2.3 bundle.
        let input: Int?
        /// D-pad only: up, down, left, right, in that order.
        /// Stick only: x-positive, x-negative, y-positive, y-negative, the
        /// same order and meaning as EmulatorJS's own `inputValues`.
        let inputs: [Int]?
        let frame: Rect
        let extended: Rect
        /// D-pad only. Four way sticks actively suppress diagonals: Pac-Man
        /// and Donkey Kong misbehave when fed two directions at once.
        let fourWay: Bool?
        /// Spinner: counts per full revolution (default 768, the
        /// thumbs-on-glass verdict). Trackball: counts per point of
        /// travel x100 (default 300). Data so the editor owns feel.
        var sensitivity: Double? = nil
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
    /// One file per real pad shape under Resources/ControlLayouts, not one
    /// per platform: a Super Famicom and a European SNES are the same
    /// controller wearing a different name, and get the same file.
    ///
    /// Keyed by canonical slug (`Rom.canonicalPlatformSlug`), the same
    /// contract every other platform keyed lookup in this app follows, and
    /// sourced from every non-computer, non-arcade entry in
    /// `Resources/cores.json`. Arcade resolves through `ArcadeProfileStore`
    /// instead and never reaches this switch. A slug with no fixed digital
    /// pad this app can honestly draw (a mouse or light gun game, a light
    /// gun peripheral, a keypad heavy machine like the 5200 or ColecoVision)
    /// falls through to `default` rather than being blocked: unlike a
    /// keyboard machine or an analog stick, a two button pad is at least a
    /// plausible, if incomplete, way to play, so it is offered rather than
    /// refused.
    /// A layout by bundled file name, for the cases where the file is not
    /// a straight function of the platform: the six-button Genesis pad is
    /// picked by a core setting, not a slug.
    static func named(_ name: String) -> ControlLayout? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else {
            assertionFailure("Missing or invalid control layout \(name).json")
            return nil
        }
        return layout
    }

    static func forPlatform(slug: String) -> ControlLayout? {
        let name: String
        switch slug {
        case "gb", "gbc", "dmg", "game-boy-light", "game-boy-pocket":
            name = "gb"
        case "gba", "game-boy-adavance-sp", "game-boy-micro":
            name = "gba"
        case "snes", "sfam", "new-style-super-nes-model-sns-101",
             "super-famicom-jr-model-shvc-101", "super-famicom-shvc-001",
             "super-nintendo-original-european-version":
            name = "snes"
        case "genesis", "sega-mega-drive-2-slash-genesis", "sega-nomad",
             "mega-pc", "sega-mega-jet", "tera-drive", "segacd", "sega32":
            name = "genesis"
        case "saturn":
            name = "saturn"
        case "psx":
            name = "psx"
        case "psp":
            name = "psp"
        case "pc-fx":
            name = "pcfx"
        case "tg16", "turbografx-cd", "supergrafx":
            name = "pce"
        case "3do":
            name = "threedo"
        case "lynx", "atari-lynx-mkii":
            name = "lynx"
        case "wonderswan", "wonderswan-color", "swancrystal":
            name = "wonderswan"
        case "nds", "nintendo-ds-lite", "nintendo-dsi", "nintendo-dsi-xl":
            name = "nds"
        case "n64", "ique-player":
            name = "n64"
        case "nes", "famicom", "fds", "new-style-nes", "game-televisison":
            name = "nes"
        case "sms", "sega-mark-iii", "sega-master-system-ii",
             "master-system-girl", "master-system-super-compact",
             "sega-game-box-9":
            name = "sms"
        case "gamegear":
            name = "gamegear"
        case "neo-geo-pocket", "neo-geo-pocket-color":
            name = "ngpc"
        case "atari7800":
            name = "atari7800"
        case "dc":
            name = "dreamcast"
        default:
            name = "default"
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
