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
    /// The phone-as-controller arrangement: landscape, but with no
    /// picture to leave room for, so the controls can own the whole
    /// screen. `landscapeItems` are authored to sit in the gutters
    /// around a centred game, which is right when the game is there
    /// and wrong on a companion panel, where it left the controls
    /// hugging the bezels with the middle half of the screen empty.
    /// Measured 2026-08-23: those layouts use 13 to 21 per cent of the
    /// screen, and their buttons are a quarter to a sixth of the area
    /// of the hand-tuned arcade companion's.
    ///
    /// Optional, and the panel falls back to `landscapeItems` without
    /// one, exactly as landscape falls back to portrait. Nintendo DS
    /// deliberately has none: its panel DOES show a picture, the
    /// streamed bottom screen, so the gutter shape is correct there.
    let companionItems: [Item]?
    /// Extra portrait strip height, as a fraction of the normal strip, for
    /// pads too crowded to fit in it (N64's stick, d-pad, four face buttons,
    /// C cluster and three shoulders is a lot more than a two button Game
    /// Boy pad). Zero for every layout that does not opt in, which keeps
    /// their coordinates exactly what they have always meant: this only
    /// grows the strip a layout is normalised against when the layout asks
    /// for it, so nothing else in the library shifts.
    let headroom: Double?

    /// The arrangement for a phone driving a television: the
    /// companion set when the layout carries one, the landscape set
    /// otherwise.
    func companionOrLandscapeItems() -> [Item] {
        if let companion = companionItems, !companion.isEmpty { return companion }
        return items(landscape: true)
    }

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
            /// A rotary joystick: one control the player both pushed and
            /// twisted. The inner area is the stick, the collar around it
            /// twists to aim, because the cabinet had one thing under the
            /// hand and drawing two would be a different machine.
            case rotary
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

    /// A human name for a layout's own system id, for the moments a
    /// phone has to say what is on the television without having the
    /// game itself: the controller offer card, when the game is not
    /// on this phone's shelves. Falls back to the id, which is at
    /// least honest, never a wire string dressed up as a title.
    static func displayName(forSystem system: String) -> String {
        switch system {
        case "nds": return "Nintendo DS"
        case "snes": return "SNES"
        case "nes": return "NES"
        case "n64": return "Nintendo 64"
        case "gb": return "Game Boy"
        case "gba": return "Game Boy Advance"
        case "genesis", "genesis6": return "Genesis"
        case "sms": return "Master System"
        case "gamegear": return "Game Gear"
        case "psx": return "PlayStation"
        case "saturn": return "Saturn"
        case "dreamcast": return "Dreamcast"
        case "pce", "pce6": return "TurboGrafx-16"
        case "pcfx": return "PC-FX"
        case "ngpc": return "Neo Geo Pocket Color"
        case "atari2600": return "Atari 2600"
        case "atari7800": return "Atari 7800"
        case "lynx": return "Lynx"
        case "vectrex": return "Vectrex"
        case "virtualboy": return "Virtual Boy"
        case "wonderswan": return "WonderSwan"
        case "threedo": return "3DO"
        case "psp": return "PSP"
        case "arcade": return "Arcade"
        // The fallback layout, which forPlatform hands back for a
        // machine with no honest fixed pad shape. The card reads
        // "<this> is on your TV", so it has to be a subject: "Default"
        // is a UI word leaking out, and naming the TV twice is worse.
        case "default": return "A game"
        default: return system
        }
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
        // Game & Watch: the picture is the controller (see gw.json's own
        // note); this layout is the tap surface and a Menu pill.
        case "game-and-watch", "game & watch", "game and watch", "gameandwatch":
            name = "gw"
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
        case "atari2600", "atari-2600-plus":
            name = "atari2600"
        case "dc":
            name = "dreamcast"
        case "vectrex":
            name = "vectrex"
        case "virtualboy":
            name = "virtualboy"
        case "nds":
            name = "nds"
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
