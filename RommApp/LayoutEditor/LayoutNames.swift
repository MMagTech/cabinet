import Foundation

/// A human name for each bundled layout file, and what real platform slugs
/// resolve to it.
///
/// Copied by hand from `ControlLayout.forPlatform(slug:)`'s switch, not
/// derived from it: that switch is not data the editor's target can read at
/// runtime, only Swift the compiler resolves. Keeping this list is the
/// tradeoff, and it only needs revisiting when a platform is added there,
/// which is rare enough that a stale entry here is an acceptable risk next
/// to the alternative of duplicating the switch as a lookup table.
struct LayoutName {
    let file: String
    let title: String
    let slugs: String

    static let all: [LayoutName] = [
        LayoutName(file: "atari7800", title: "Atari 7800", slugs: "atari7800"),
        LayoutName(file: "default", title: "Fallback pad", slugs: "anything with no fixed digital pad this app can honestly draw"),
        LayoutName(file: "dreamcast", title: "Dreamcast", slugs: "dc"),
        LayoutName(file: "gamegear", title: "Sega Game Gear", slugs: "gamegear"),
        LayoutName(file: "gb", title: "Game Boy", slugs: "gb, gbc, dmg, and the Light/Pocket revisions"),
        LayoutName(file: "gba", title: "Game Boy Advance", slugs: "gba, SP, Micro"),
        LayoutName(file: "genesis", title: "Genesis / Mega Drive (3-button)", slugs: "genesis, Nomad, Mega Jet, Tera Drive, Sega CD, 32X"),
        LayoutName(file: "genesis6", title: "Genesis / Mega Drive (6-button)", slugs: "same platforms as genesis; picked by the Controller core setting, not by slug"),
        LayoutName(file: "lynx", title: "Atari Lynx", slugs: "lynx, Lynx II"),
        LayoutName(file: "n64", title: "Nintendo 64", slugs: "n64, iQue Player"),
        LayoutName(file: "nds", title: "Nintendo DS", slugs: "nds, DS Lite, DSi, DSi XL"),
        LayoutName(file: "nes", title: "NES / Famicom", slugs: "nes, famicom, FDS, the new-style NES"),
        LayoutName(file: "ngpc", title: "Neo Geo Pocket", slugs: "Neo Geo Pocket, Pocket Color"),
        LayoutName(file: "pce", title: "PC Engine / TurboGrafx-16 (2-button)", slugs: "tg16, TurboGrafx-CD, SuperGrafx"),
        LayoutName(file: "pce6", title: "PC Engine / TurboGrafx-16 (Avenue Pad 6)", slugs: "same platforms as pce; picked by the Controller core setting, not by slug"),
        LayoutName(file: "pcfx", title: "PC-FX", slugs: "pc-fx"),
        LayoutName(file: "psp", title: "PlayStation Portable", slugs: "psp"),
        LayoutName(file: "psx", title: "PlayStation", slugs: "psx"),
        LayoutName(file: "saturn", title: "Sega Saturn", slugs: "saturn"),
        LayoutName(file: "sms", title: "Sega Master System", slugs: "sms, Mark III, Master System II, Girl, Super Compact"),
        LayoutName(file: "snes", title: "SNES / Super Famicom", slugs: "snes, sfam, and the regional hardware revisions"),
        LayoutName(file: "threedo", title: "3DO", slugs: "3do"),
        LayoutName(file: "wonderswan", title: "WonderSwan", slugs: "wonderswan, Color, Crystal"),
    ]

    static func title(for file: String) -> String? {
        all.first { $0.file == file }?.title
    }
}
