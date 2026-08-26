import Foundation

/// A human name for each bundled layout file, and what real platform slugs
/// resolve to it.
///
/// The arcade entries are different in kind from the rest: arcade layouts
/// are picked per game by the cabinet itself rather than by platform slug,
/// and they were generated in code until the lab exported them as real
/// files. Editing one here changes every arcade game with that shape, and
/// the note beside each one says how many cabinets that is.
///
/// The analog entries are named by ArcadeLayout.tunedPanelName and written
/// by tools/lab/arcade/panels.sh, which refuses to write unless every
/// cabinet sharing a name also shares a panel. A name that does not
/// describe the panel completely is not a cosmetic problem: it is how a
/// two pedal layout reaches a one pedal machine.
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
        LayoutName(file: "arcade-twin4", title: "Arcade twin stick, 4 buttons", slugs: "two sticks plus 4 buttons"),
        LayoutName(file: "arcade-twin6", title: "Arcade twin stick, 6 buttons", slugs: "two sticks plus 6 buttons"),
        LayoutName(file: "arcade-gun-spinner1p1", title: "Arcade: Light gun, dial and 1 pedal, 1 button", slugs: "1 cabinet: luckywld"),
        LayoutName(file: "arcade-gun-trackball2", title: "Arcade: Light gun and trackball, 2 buttons", slugs: "1 cabinet: borntofi"),
        LayoutName(file: "arcade-gun1", title: "Arcade: Light gun, 1 button", slugs: "41 cabinets: bang, chiller, claypign"),
        LayoutName(file: "arcade-gun2", title: "Arcade: Light gun, 2 buttons", slugs: "30 cabinets: opwolf, alien3, bbusters"),
        LayoutName(file: "arcade-gun3", title: "Arcade: Light gun, 3 buttons", slugs: "10 cabinets: gdfs, gunbustr, le2"),
        LayoutName(file: "arcade-gun6", title: "Arcade: Light gun, 6 buttons", slugs: "2 cabinets: opthund, showdown"),
        LayoutName(file: "arcade-pedal0p1", title: "Arcade: 1 pedal, no buttons", slugs: "2 cabinets: suzuk8h2, suzuka8h"),
        LayoutName(file: "arcade-pedal1p1", title: "Arcade: 1 pedal, 1 button", slugs: "3 cabinets: opengolf, radr, slipstrm"),
        LayoutName(file: "arcade-pedal2p1", title: "Arcade: 1 pedal, 2 buttons", slugs: "7 cabinets: chqflag, chqflagj, f1en"),
        LayoutName(file: "arcade-pedal3p1", title: "Arcade: 1 pedal, 3 buttons", slugs: "4 cabinets: f1lap, f1lapj, roadriot"),
        LayoutName(file: "arcade-pedal4p1", title: "Arcade: 1 pedal, 4 buttons", slugs: "4 cabinets: dcclub, motofren, tceptor"),
        LayoutName(file: "arcade-pedal5p1", title: "Arcade: 1 pedal, 5 buttons", slugs: "1 cabinet: orunners"),
        LayoutName(file: "arcade-pedal6p1", title: "Arcade: 1 pedal, 6 buttons", slugs: "4 cabinets: ggreats2, hydra, hydrap"),
        LayoutName(file: "arcade-rotary1", title: "Arcade: Rotary stick, 1 button", slugs: "2 cabinets: forgottn, lostwrld"),
        LayoutName(file: "arcade-rotary2", title: "Arcade: Rotary stick, 2 buttons", slugs: "27 cabinets: 720, gwar, hbarrel"),
        LayoutName(file: "arcade-rotary3", title: "Arcade: Rotary stick, 3 buttons", slugs: "1 cabinet: ikari3"),
        LayoutName(file: "arcade-spinner0", title: "Arcade: Dial, no buttons", slugs: "5 cabinets: circus, clowns, clowns1"),
        LayoutName(file: "arcade-spinner0j", title: "Arcade: Dial and stick, no buttons", slugs: "2 cabinets: boxer, hwchamp"),
        LayoutName(file: "arcade-spinner0p1", title: "Arcade: Dial and 1 pedal, no buttons", slugs: "16 cabinets: csprint, ssprint, csprint1"),
        LayoutName(file: "arcade-spinner0p1j", title: "Arcade: Dial, 1 pedal and stick, no buttons", slugs: "5 cabinets: dirtfoxj, grchamp, harddriv"),
        LayoutName(file: "arcade-spinner1", title: "Arcade: Dial, 1 button", slugs: "46 cabinets: arkanoid, arknoid2, avalnche"),
        LayoutName(file: "arcade-spinner1j", title: "Arcade: Dial and stick, 1 button", slugs: "11 cabinets: boothill, galpanis, galpans2"),
        LayoutName(file: "arcade-spinner1p1", title: "Arcade: Dial and 1 pedal, 1 button", slugs: "20 cabinets: 280zzzap, offroad, polepos"),
        LayoutName(file: "arcade-spinner1p2", title: "Arcade: Dial and 2 pedals, 1 button", slugs: "1 cabinet: finallap"),
        LayoutName(file: "arcade-spinner2", title: "Arcade: Dial, 2 buttons", slugs: "33 cabinets: omegrace, tempest, badlands"),
        LayoutName(file: "arcade-spinner2j", title: "Arcade: Dial and stick, 2 buttons", slugs: "26 cabinets: freekick, aztarac, countrun"),
        LayoutName(file: "arcade-spinner2p1", title: "Arcade: Dial and 1 pedal, 2 buttons", slugs: "10 cabinets: apb1, apb2, apb3"),
        LayoutName(file: "arcade-spinner2p2", title: "Arcade: Dial and 2 pedals, 2 buttons", slugs: "1 cabinet: apb"),
        LayoutName(file: "arcade-spinner3", title: "Arcade: Dial, 3 buttons", slugs: "12 cabinets: sprint8, boxingb, carpolo"),
        LayoutName(file: "arcade-spinner3j", title: "Arcade: Dial and stick, 3 buttons", slugs: "13 cabinets: backfire, crater, cyvern"),
        LayoutName(file: "arcade-spinner3p1j", title: "Arcade: Dial, 1 pedal and stick, 3 buttons", slugs: "1 cabinet: roadblst"),
        LayoutName(file: "arcade-spinner4", title: "Arcade: Dial, 4 buttons", slugs: "8 cabinets: blstroid, moonwar, moonwara"),
        LayoutName(file: "arcade-spinner4j", title: "Arcade: Dial and stick, 4 buttons", slugs: "4 cabinets: aquajack, arkretrn, offtwall"),
        LayoutName(file: "arcade-spinner4p1", title: "Arcade: Dial and 1 pedal, 4 buttons", slugs: "4 cabinets: hcrash, hcrashc, rrreveng"),
        LayoutName(file: "arcade-spinner5", title: "Arcade: Dial, 5 buttons", slugs: "1 cabinet: sprint1"),
        LayoutName(file: "arcade-spinner5p1", title: "Arcade: Dial and 1 pedal, 5 buttons", slugs: "1 cabinet: spyhunt"),
        LayoutName(file: "arcade-spinner6", title: "Arcade: Dial, 6 buttons", slugs: "8 cabinets: sprint2, dragrace, montecar"),
        LayoutName(file: "arcade-spinner6j", title: "Arcade: Dial and stick, 6 buttons", slugs: "4 cabinets: dankuga, gblchmp, gtmr2"),
        LayoutName(file: "arcade-spinner6p1", title: "Arcade: Dial and 1 pedal, 6 buttons", slugs: "7 cabinets: calspeed, crusnusa, crusnwld"),
        LayoutName(file: "arcade-spinner6p1j", title: "Arcade: Dial, 1 pedal and stick, 6 buttons", slugs: "1 cabinet: hdrivair"),
        LayoutName(file: "arcade-trackball-spinner4", title: "Arcade: Trackball and dial, 4 buttons", slugs: "3 cabinets: dotron, dotrona, dotrone"),
        LayoutName(file: "arcade-trackball0", title: "Arcade: Trackball, no buttons", slugs: "13 cabinets: marble, beezer, beezer1"),
        LayoutName(file: "arcade-trackball1", title: "Arcade: Trackball, 1 button", slugs: "32 cabinets: atarifb, ataxx, centiped"),
        LayoutName(file: "arcade-trackball2", title: "Arcade: Trackball, 2 buttons", slugs: "38 cabinets: bowlrama, capbowl, cloud9"),
        LayoutName(file: "arcade-trackball3", title: "Arcade: Trackball, 3 buttons", slugs: "10 cabinets: ccastles, missile, arcadecl"),
        LayoutName(file: "arcade-trackball5", title: "Arcade: Trackball, 5 buttons", slugs: "2 cabinets: mjleague, pubball"),
        LayoutName(file: "arcade-trackball6", title: "Arcade: Trackball, 6 buttons", slugs: "2 cabinets: sjryuko, topsecex"),
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
        LayoutName(file: "gw", title: "Game & Watch", slugs: "the picture is the controller: taps press the drawn buttons; this is the surface plus Menu"),
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
