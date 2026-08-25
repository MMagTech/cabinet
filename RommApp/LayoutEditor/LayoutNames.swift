import Foundation

/// A human name for each bundled layout file, and what real platform slugs
/// resolve to it.
///
/// The arcade entries are different in kind from the rest: arcade layouts
/// are picked per game by the cabinet's own profile (stick type and button
/// count) rather than by platform slug, and they were generated in code
/// until tools/arcade-layouts exported them as real files. Editing one
/// here changes every arcade game with that shape.
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
        LayoutName(file: "arcade-stick0", title: "Arcade, 0 buttons", slugs: "one stick, no buttons: Pac-Man, Donkey Kong and the rest of the maze and climb family"),
        LayoutName(file: "arcade-stick1", title: "Arcade, 1 button", slugs: "one stick, 1 button"),
        LayoutName(file: "arcade-stick2", title: "Arcade, 2 buttons", slugs: "one stick, 2 buttons"),
        LayoutName(file: "arcade-stick3", title: "Arcade, 3 buttons", slugs: "one stick, 3 buttons"),
        LayoutName(file: "arcade-stick4", title: "Arcade, 4 buttons", slugs: "one stick, 4 buttons"),
        LayoutName(file: "arcade-stick5", title: "Arcade, 5 buttons", slugs: "one stick, 5 buttons"),
        LayoutName(file: "arcade-stick6", title: "Arcade, 6 buttons", slugs: "one stick, six buttons: the fighter layout, and the generic guess for an unmapped cabinet"),
        LayoutName(file: "arcade-twin0", title: "Arcade twin stick, 0 buttons", slugs: "two sticks (MAME doublejoy): Smash TV, Robotron, Battlezone"),
        LayoutName(file: "arcade-twin1", title: "Arcade twin stick, 1 button", slugs: "two sticks plus 1 button"),
        LayoutName(file: "arcade-twin2", title: "Arcade twin stick, 2 buttons", slugs: "two sticks plus 2 buttons"),
        LayoutName(file: "arcade-twin3", title: "Arcade twin stick, 3 buttons", slugs: "two sticks plus 3 buttons"),
        LayoutName(file: "arcade-twin4", title: "Arcade twin stick, 4 buttons", slugs: "two sticks plus 4 buttons"),
        LayoutName(file: "arcade-twin5", title: "Arcade twin stick, 5 buttons", slugs: "two sticks plus 5 buttons"),
        LayoutName(file: "arcade-twin6", title: "Arcade twin stick, 6 buttons", slugs: "two sticks plus 6 buttons"),
        LayoutName(file: "arcade-spinner0", title: "Arcade spinner, no buttons", slugs: "dial and paddle-knob cabinets: the spinner replaces the stick"),
        LayoutName(file: "arcade-spinner1", title: "Arcade spinner, 1 button", slugs: "dial plus 1 button: On the Ball, Arkanoid"),
        LayoutName(file: "arcade-spinner2", title: "Arcade spinner, 2 buttons", slugs: "dial plus 2 buttons"),
        LayoutName(file: "arcade-trackball0", title: "Arcade trackball, no buttons", slugs: "trackball cabinets with no buttons"),
        LayoutName(file: "arcade-trackball1", title: "Arcade trackball, 1 button", slugs: "trackball plus 1 button: Centipede, Millipede"),
        LayoutName(file: "arcade-trackball2", title: "Arcade trackball, 2 buttons", slugs: "trackball plus 2 buttons: Golden Tee, Capcom Bowling family"),
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
        LayoutName(file: "arcade-wheel0", title: "Arcade: wheel + 2 pedals, 0 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-wheel1", title: "Arcade: wheel + 2 pedals, 1 button", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-wheel2", title: "Arcade: wheel + 2 pedals, 2 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-wheel3", title: "Arcade: wheel + 2 pedals, 3 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-wheel4", title: "Arcade: wheel + 2 pedals, 4 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-wheel5", title: "Arcade: wheel + 2 pedals, 5 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-wheel6", title: "Arcade: wheel + 2 pedals, 6 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun0", title: "Arcade: light gun, 0 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun1", title: "Arcade: light gun, 1 button", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun2", title: "Arcade: light gun, 2 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun3", title: "Arcade: light gun, 3 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun4", title: "Arcade: light gun, 4 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun5", title: "Arcade: light gun, 5 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-gun6", title: "Arcade: light gun, 6 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary0", title: "Arcade: rotary stick, 0 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary1", title: "Arcade: rotary stick, 1 button", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary2", title: "Arcade: rotary stick, 2 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary3", title: "Arcade: rotary stick, 3 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary4", title: "Arcade: rotary stick, 4 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary5", title: "Arcade: rotary stick, 5 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-rotary6", title: "Arcade: rotary stick, 6 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-spinner3", title: "Arcade: dial, 3 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-spinner4", title: "Arcade: dial, 4 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-spinner5", title: "Arcade: dial, 5 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-spinner6", title: "Arcade: dial, 6 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-trackball3", title: "Arcade: trackball, 3 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-trackball4", title: "Arcade: trackball, 4 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-trackball5", title: "Arcade: trackball, 5 buttons", slugs: "arcade, by cabinet"),
        LayoutName(file: "arcade-trackball6", title: "Arcade: trackball, 6 buttons", slugs: "arcade, by cabinet"),
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
