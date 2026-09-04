import Foundation

/// The natively compiled cores this app ships, one case per core. Kept
/// apart from the webview player's core catalogue on purpose: that list
/// is RomM's, this one is ours.
enum NativeCore {
    case fbneo
    case beetleSaturn
    case gambatte
    case mgba
    case genesisPlusGX
    case beetlePCEFast
    case snes9x
    case fceumm
    case beetleNGP
    case prosystem
    case picoDrive
    case pcsxReARMed
    case flycast
    case mupen64Plus
    case mame2003Plus
    case vecx
    case stella2014
    case opera
    case beetleVB
    case melonDS
    case ppsspp
    /// Game & Watch. iOS-only by decision (docs/building.md); the tvOS
    /// build is gated out at the frontend and this case never resolves
    /// there because the platform below never exists on tvOS.
    case gw
    /// The Dreamcast VMU as a standalone machine, playing the minigames
    /// DC games download onto their save card. iOS-only by decision,
    /// like GW. Deliberately NO NativePlatform case anywhere: the VMU
    /// is not a platform and never appears in RomM or the library. The
    /// minigame is cargo inside a DC game's save, and the only door to
    /// it is the VMU row on that game's launch screen (GameLaunchView),
    /// which boots this core on the card file directly through
    /// VMULauncher, never through NativeLauncher.prepare.
    case vemulator

    /// The frontend's identifier for the statically linked core.
    var coreID: LibretroCoreID {
        switch self {
        case .fbneo: return .fbneo
        case .beetleSaturn: return .beetleSaturn
        case .gambatte: return .gambatte
        case .mgba: return .mgba
        case .genesisPlusGX: return .genesisPlusGX
        case .beetlePCEFast: return .beetlePCEFast
        case .snes9x: return .snes9x
        case .fceumm: return .fceumm
        case .beetleNGP: return .beetleNGP
        case .prosystem: return .prosystem
        case .picoDrive: return .picoDrive
        case .pcsxReARMed: return .pcsxReARMed
        case .flycast: return .flycast
        case .mupen64Plus: return .mupen64Plus
        case .mame2003Plus: return .mame2003Plus
        case .vecx: return .vecx
        case .stella2014: return .stella2014
        case .opera: return .opera
        case .beetleVB: return .beetleVB
        case .melonDS: return .melonDS
        case .ppsspp: return .ppsspp
        case .gw: return .gw
        case .vemulator: return .vemulator
        }
    }

    /// The emulator tag uploaded states carry. Tested 2026-08-06 and the
    /// answer is no: the webview's WASM FBNeo (the build frozen inside
    /// EmulatorJS 4.2.3) cannot restore states written by the native
    /// FBNeo build, it fails silently and boots fresh. libretro state
    /// formats are core-build-specific, so each player's states are
    /// tagged distinctly on purpose: a separate tag keeps each player's
    /// launch UI from offering states it cannot actually restore.
    var emulatorTag: String {
        switch self {
        case .fbneo: return "fbneo-native"
        case .beetleSaturn: return "saturn-native"
        case .gambatte: return "gambatte-native"
        case .mgba: return "mgba-native"
        case .genesisPlusGX: return "gpgx-native"
        case .beetlePCEFast: return "pcefast-native"
        case .snes9x: return "snes9x-native"
        case .fceumm: return "fceumm-native"
        case .beetleNGP: return "ngp-native"
        case .prosystem: return "prosystem-native"
        case .picoDrive: return "picodrive-native"
        case .pcsxReARMed: return "pcsx-rearmed-native"
        case .flycast: return "flycast-native"
        case .mupen64Plus: return "mupen64plus-native"
        case .mame2003Plus: return "mame2003plus-native"
        case .vecx: return "vecx-native"
        case .stella2014: return "stella2014-native"
        case .opera: return "opera-native"
        case .beetleVB: return "beetle-vb-native"
        case .melonDS: return "melonds-native"
        case .ppsspp: return "ppsspp-native"
        // No states exist for this core, so the tag never labels one;
        // it is here because the switch is exhaustive on purpose.
        case .gw: return "gw-native"
        // Also never labels a state (the core cannot serialize). The
        // VMU player's card uploads deliberately do NOT use this tag
        // either: the card is the DC game's own save, one row shared
        // with Flycast, so they carry NativeCore.flycast.emulatorTag.
        // See VMULauncher.
        case .vemulator: return "vemulator-native"
        }
    }

    /// A stable string identifier for this core, used to namespace
    /// per-core UserDefaults keys (shader choice).
    var storageKey: String {
        switch self {
        case .fbneo: return "fbneo"
        case .beetleSaturn: return "beetleSaturn"
        case .gambatte: return "gambatte"
        case .mgba: return "mgba"
        case .genesisPlusGX: return "genesisPlusGX"
        case .beetlePCEFast: return "beetlePCEFast"
        case .snes9x: return "snes9x"
        case .fceumm: return "fceumm"
        case .beetleNGP: return "beetleNGP"
        case .prosystem: return "prosystem"
        case .picoDrive: return "picoDrive"
        case .pcsxReARMed: return "pcsxReARMed"
        case .flycast: return "flycast"
        case .mupen64Plus: return "mupen64Plus"
        case .mame2003Plus: return "mame2003Plus"
        case .vecx: return "vecx"
        case .stella2014: return "stella2014"
        case .opera: return "opera"
        case .beetleVB: return "beetleVB"
        case .melonDS: return "melonDS"
        case .ppsspp: return "ppsspp"
        case .gw: return "gw"
        case .vemulator: return "vemulator"
        }
    }

    /// What the emulator picker calls this core. The two arcade cores
    /// use the same names the webview's own picker shows for the same
    /// emulators, so a person sees one name per emulator regardless of
    /// which player runs it.
    var displayName: String {
        switch self {
        case .fbneo: return "FinalBurn Neo"
        case .mame2003Plus: return "MAME 2003-Plus"
        case .beetleSaturn: return "Beetle Saturn"
        case .gambatte: return "Gambatte"
        case .mgba: return "mGBA"
        case .genesisPlusGX: return "Genesis Plus GX"
        case .beetlePCEFast: return "Beetle PCE Fast"
        case .snes9x: return "Snes9x"
        case .fceumm: return "FCEUmm"
        case .beetleNGP: return "Beetle NeoPop"
        case .prosystem: return "ProSystem"
        case .picoDrive: return "PicoDrive"
        case .pcsxReARMed: return "PCSX ReARMed"
        case .flycast: return "Flycast"
        case .mupen64Plus: return "Mupen64Plus"
        case .vecx: return "vecx"
        case .stella2014: return "Stella"
        case .opera: return "Opera"
        case .beetleVB: return "Beetle VB"
        case .melonDS: return "melonDS"
        case .ppsspp: return "PPSSPP"
        case .gw: return "GW"
        case .vemulator: return "VeMUlator"
        }
    }

    /// The webview hint slug for this core, where one exists. CoreHints
    /// speaks the webview catalogue's names; the two arcade cores exist
    /// in both worlds under these names.
    var hintSlug: String? {
        switch self {
        case .fbneo: return "fbneo"
        case .mame2003Plus: return "mame2003_plus"
        default: return nil
        }
    }

    /// The native core that can run this rom, if any. `canonicalSlug` must
    /// be `rom.canonicalPlatformSlug(platformsVersions:)`, never
    /// `rom.platformSlug`: see `NativePlatform.platform(for:canonicalSlug:)`
    /// for why matching against the raw metadata slug is wrong.
    static func core(for rom: Rom, canonicalSlug: String) -> NativeCore? {
        guard let platform = NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) else { return nil }
        // The experimental gate. Nil here is exactly the state these
        // platforms had before their cores graduated, so every caller,
        // the launch screen's picker, Home's resume, keep offers, the
        // offline library, falls back to its pre-graduation behavior
        // without knowing the gate exists. Deliberately not applied to
        // NativePlatform.platform() lookups: bookkeeping for already
        // kept files must keep resolving while availability is off.
        guard !platform.isExperimental || ExperimentalCores.enabled else { return nil }
        return NativeCoreChoice.resolved(for: rom, platform: platform)
    }

    /// The native core for an already-resolved slug, for callers with no
    /// rom or live session in hand, only what was persisted at keep time.
    static func core(bySlug slug: String, isArcade: Bool) -> NativeCore? {
        guard let platform = NativePlatform.platform(bySlug: slug, isArcade: isArcade) else { return nil }
        // Same gate as above, same reasoning.
        guard !platform.isExperimental || ExperimentalCores.enabled else { return nil }
        return platform.core
    }
}

/// A platform with a native implementation. Settings and the Settings >
/// Native cores list key off this, not off the core: several platforms
/// share one core binary (Genesis Plus GX serves five), and a pad-type
/// change made for Genesis must not silently carry into Game Gear.
enum NativePlatform: String, CaseIterable {
    case arcade
    case saturn
    case gb
    case gbc
    case gba
    case genesis
    case segaCD
    case masterSystem
    case gameGear
    case sega32X
    case tg16
    case tgCD
    case snes
    case nes
    case ngpc
    case atari7800
    case psx
    case dreamcast
    case n64
    case vectrex
    case atari2600
    case threeDO
    case virtualBoy
    case nds
    case psp
    case gameAndWatch

    /// Every core that can run this platform, default first. Arcade is
    /// the only platform with a real set; everywhere else this is the
    /// one-member wrapper around `core`, so no other platform's behavior
    /// can change by construction.
    var cores: [NativeCore] {
        switch self {
        case .arcade: return [.fbneo, .mame2003Plus]
        default: return [core]
        }
    }

    var core: NativeCore {
        switch self {
        case .arcade: return .fbneo
        case .saturn: return .beetleSaturn
        case .gb, .gbc: return .gambatte
        case .gba: return .mgba
        case .genesis, .segaCD, .masterSystem, .gameGear:
            return .genesisPlusGX
        case .sega32X: return .picoDrive
        case .tg16, .tgCD: return .beetlePCEFast
        case .snes: return .snes9x
        case .nes: return .fceumm
        case .ngpc: return .beetleNGP
        case .atari7800: return .prosystem
        case .psx: return .pcsxReARMed
        case .dreamcast: return .flycast
        case .n64: return .mupen64Plus
        case .vectrex: return .vecx
        case .atari2600: return .stella2014
        case .threeDO: return .opera
        case .virtualBoy: return .beetleVB
        case .nds: return .melonDS
        case .psp: return .ppsspp
        case .gameAndWatch: return .gw
        }
    }

    /// Whether this platform's in-game saves ride RETRO_MEMORY_SAVE_RAM,
    /// the standard libretro battery-save call the player's memory card
    /// sync captures, uploads and restores. This is the gate for that
    /// whole path, so a platform is only listed once its core's wiring
    /// actually exports the memory API and the mechanism is confirmed in
    /// the core's own source (docs/native-in-game-saves.md holds the
    /// per-core findings).
    ///
    /// The platforms left out each have a real reason, not a gap:
    /// - arcade: no save-and-resume concept in these games; FBNeo's
    ///   high-score/NVRAM files are a different mechanism entirely.
    /// - atari7800: no retail cartridge could save, and the core
    ///   implements nothing.
    /// - dreamcast: the VMU is a real battery save but Flycast hands it
    ///   over as a file, `captureVMUSave()`'s own separate path.
    /// - segaCD, ngpc: their cores write real files (Sega CD's .brm
    ///   backup RAM, Neo Geo Pocket's .flash) instead of answering
    ///   SAVE_RAM, flushed only inside retro_unload_game. They sync
    ///   through their own file path: NativeLauncher places the file
    ///   before boot, the player captures it after the quit-time
    ///   unload.
    var savesOverSaveRAM: Bool {
        switch self {
        // vectrex: no Vectrex cartridge could save, and the core exposes
        // only RETRO_MEMORY_SYSTEM_RAM.
        // atari2600: same as atari7800, no retail cartridge could save;
        // the core exposes only the RIOT's 128 bytes of system RAM.
        // threeDO: the console's NVRAM is a real battery save, but Opera
        // answers RETRO_MEMORY_SAVE_RAM with NULL and writes a file at
        // retro_unload_game instead (opera/shared/nvram.0.srm under the
        // forced options), so it syncs through the segaCD/ngpc file
        // path, not this one.
        // virtualBoy: the one exclusion the core's own API argues
        // against, so it is written down rather than left to look like
        // an oversight. Beetle VB implements RETRO_MEMORY_SAVE_RAM and
        // reports 64KB of cartridge RAM for every game, because
        // GPRAM_Mask is set to 0xFFFF unconditionally at load rather
        // than from the cartridge header. No commercial Virtual Boy
        // game shipped with battery backup; the machine's games used
        // passwords or nothing. So that 64KB is scratch the console
        // wired up and no game ever kept anything in, and syncing it
        // would upload a buffer of noise per game forever. Checked
        // against the core's source 2026-08-28, not assumed.
        // nds: melonDS answers RETRO_MEMORY_SAVE_RAM with NULL and
        // manages the cartridge save itself, writing <save dir>/
        // <game>.sav through its own NDSCart_SRAMManager, debounce
        // flushed during play and force flushed at unload (Cabinet's
        // own patch, see build-core.sh). Synced through the
        // segaCD/ngpc file path: restored by NativeLauncher before
        // boot, captured by MemoryCardSync after the quit-time unload.
        // psp: PSP games save to memory-stick SAVEDATA directories,
        // whole folders of files under the save directory, which
        // neither SAVE_RAM nor the single-file capture path models.
        // Save sync for PSP is its own future feature.
        case .arcade, .atari7800, .atari2600, .dreamcast, .segaCD, .ngpc, .vectrex,
             .threeDO, .virtualBoy, .nds, .psp, .gameAndWatch:
            return false
        default:
            return true
        }
    }

    /// Whether this platform can save and restore states at all. True
    /// for everything but Game & Watch: gw-libretro's retro_serialize
    /// returns false and its serialize_size is zero, a fact of the core
    /// rather than a choice here, so offering slot buttons would offer
    /// something that cannot work. The games are minute-long score
    /// chasers; nothing of value is lost.
    var supportsSaveStates: Bool {
        self != .gameAndWatch
    }

    /// Whether a second local player's controller has anywhere to plug
    /// into. Defaults to yes: consoles and arcade boards genuinely have a
    /// second port, and arcade in particular is a core 2-player use case
    /// (Metal Slug, Neo Geo titles), not the single-player exception it
    /// might look like next to the twin-stick digitizing FBNeo also does.
    /// The exception is handhelds, which physically have exactly one
    /// player's worth of controls no matter what core drives them: Game
    /// Boy, Game Boy Color, Game Boy Advance, Game Gear (even though it
    /// shares Genesis Plus GX with console platforms that do get a second
    /// port), and Neo Geo Pocket Color.
    var supportsSecondPlayer: Bool {
        switch self {
        case .gb, .gbc, .gba, .gameGear, .ngpc, .nds, .psp, .gameAndWatch: return false
        // A headset with one pad attached: there is no second port.
        case .virtualBoy: return false
        // Not a handheld, but off for a different, documented reason:
        // Opera's own opera_active_devices option defaults to 1 because
        // of a known bug where more than one emulated controller makes
        // some games ignore gamepad input entirely, and this app forces
        // that default. Offering a second controller that the core is
        // configured not to read would look broken; revisit only with
        // the bug re-tested on real games.
        case .threeDO: return false
        default: return true
        }
    }

    /// What the row in Settings > Native cores says. Platform names, not
    /// core names: the person changing a Sega CD option is thinking about
    /// Sega CD, not about which binary happens to serve it.
    var displayName: String {
        switch self {
        case .arcade: return "Arcade"
        case .saturn: return "Sega Saturn"
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .gba: return "Game Boy Advance"
        case .genesis: return "Sega Genesis/Mega Drive"
        case .segaCD: return "Sega CD"
        case .masterSystem: return "Sega Master System"
        case .gameGear: return "Sega Game Gear"
        case .sega32X: return "Sega 32X"
        case .tg16: return "TurboGrafx-16"
        case .tgCD: return "TurboGrafx-CD"
        case .snes: return "SNES"
        case .nes: return "NES"
        case .ngpc: return "Neo Geo Pocket Color"
        case .atari7800: return "Atari 7800"
        case .psx: return "PlayStation"
        case .dreamcast: return "Dreamcast"
        case .n64: return "Nintendo 64"
        case .vectrex: return "Vectrex"
        case .atari2600: return "Atari 2600"
        case .threeDO: return "3DO"
        case .virtualBoy: return "Virtual Boy"
        case .nds: return "Nintendo DS"
        case .psp: return "PSP"
        case .gameAndWatch: return "Game & Watch"
        }
    }

    /// The UserDefaults namespace for this platform's option values. The
    /// first two match the core storage keys options were saved under
    /// before settings became platform-keyed, so nothing anyone already
    /// set is lost; new platforms use their own raw value.
    var storageKey: String {
        switch self {
        case .arcade: return "fbneo"
        case .saturn: return "beetleSaturn"
        default: return rawValue
        }
    }

    /// The platform for a rom. `canonicalSlug` must be
    /// `rom.canonicalPlatformSlug(platformsVersions:)`, the same value
    /// `ControlLayout.forPlatform` and `CoreCatalog` are already keyed
    /// by, never `rom.platformSlug`. That property is IGDB's metadata
    /// slug, a different, unrelated string RomM happens to also carry;
    /// matching bundled data against it worked for Saturn by pure
    /// coincidence (IGDB's own slug for Sega Saturn happens to be
    /// literally "saturn") and silently failed for every other platform
    /// whose IGDB slug and folder-derived slug diverge, which is most of
    /// them. Found 2026-08-08: a kept TurboGrafx-CD game never showing
    /// in Offline, traced to this exact mismatch.
    static func platform(for rom: Rom, canonicalSlug: String) -> NativePlatform? {
        if let known = platform(bySlug: canonicalSlug, isArcade: rom.isArcade) { return known }
        // The file can answer when the folder name cannot. A custom
        // platform keeps whatever name someone typed, and this library
        // is not really Nintendo-only (16 of 59 are; the rest are VTech,
        // Gakken, Coleco, Elektronika and friends), so the folder may
        // fairly be renamed to something like "LCD Handhelds". No
        // rename should cost the core: .mgw belongs to gw-libretro and
        // to nothing else in this app, so the extension is a stronger
        // identifier here than the slug is.
        if rom.fsName.lowercased().hasSuffix(".mgw") {
            #if os(tvOS)
            return nil
            #else
            return .gameAndWatch
            #endif
        }
        return nil
    }

    /// The platform for an already-resolved slug, matched on the same
    /// slug families the control layout switch uses, sourced from
    /// Resources/cores.json. Split from `platform(for:canonicalSlug:)` so
    /// callers with no live rom or session, only a slug persisted at keep
    /// time, can still resolve correctly while fully offline.
    static func platform(bySlug slug: String, isArcade: Bool) -> NativePlatform? {
        resolvedPlatform(bySlug: slug, isArcade: isArcade)
    }

    private static func resolvedPlatform(bySlug slug: String, isArcade: Bool) -> NativePlatform? {
        if isArcade { return .arcade }
        switch slug {
        case "saturn":
            return .saturn
        case "gb", "dmg", "game-boy-light", "game-boy-pocket":
            return .gb
        case "gbc":
            return .gbc
        case "gba", "game-boy-adavance-sp", "game-boy-micro":
            return .gba
        case "genesis", "sega-mega-drive-2-slash-genesis", "sega-nomad",
             "mega-pc", "sega-mega-jet", "tera-drive":
            return .genesis
        case "segacd":
            return .segaCD
        case "sms", "sega-mark-iii", "sega-master-system-ii",
             "master-system-girl", "master-system-super-compact",
             "sega-game-box-9":
            return .masterSystem
        case "gamegear":
            return .gameGear
        case "sega32":
            return .sega32X
        case "tg16", "supergrafx":
            return .tg16
        case "turbografx-cd":
            return .tgCD
        case "snes", "sfam", "new-style-super-nes-model-sns-101",
             "super-famicom-jr-model-shvc-101", "super-famicom-shvc-001",
             "super-nintendo-original-european-version":
            return .snes
        case "nes", "famicom", "fds", "new-style-nes", "game-televisison":
            return .nes
        case "neo-geo-pocket", "neo-geo-pocket-color":
            return .ngpc
        case "atari7800":
            return .atari7800
        case "psx":
            return .psx
        case "dc":
            return .dreamcast
        case "n64", "ique-player":
            return .n64
        case "vectrex":
            return .vectrex
        case "atari2600", "atari-2600-plus":
            return .atari2600
        case "3do":
            return .threeDO
        case "virtualboy":
            return .virtualBoy
        case "nds":
            return .nds
        case "psp":
            return .psp
        // A custom platform on RomM keeps whatever slug its folder had:
        // Marcus's is literally "Game & Watch", lowercased to
        // "game & watch" by canonicalPlatformSlug. Accept the tidy
        // metadata slug and the folder spellings alike.
        //
        // Not on tvOS, and here rather than only at the frontend: this
        // resolver is what makes Play buttons exist, so failing it is
        // what keeps the television from offering a core it does not
        // link. The exception's reasoning lives in docs/building.md.
        case "game-and-watch", "game & watch", "game and watch", "gameandwatch":
            #if os(tvOS)
            return nil
            #else
            return .gameAndWatch
            #endif
        default:
            return nil
        }
    }
}
