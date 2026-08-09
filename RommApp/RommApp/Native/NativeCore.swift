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
        }
    }

    /// The native core that can run this rom, if any. `canonicalSlug` must
    /// be `rom.canonicalPlatformSlug(platformsVersions:)`, never
    /// `rom.platformSlug`: see `NativePlatform.platform(for:canonicalSlug:)`
    /// for why matching against the raw metadata slug is wrong.
    static func core(for rom: Rom, canonicalSlug: String) -> NativeCore? {
        NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug)?.core
    }

    /// The native core for an already-resolved slug, for callers with no
    /// rom or live session in hand, only what was persisted at keep time.
    static func core(bySlug slug: String, isArcade: Bool) -> NativeCore? {
        NativePlatform.platform(bySlug: slug, isArcade: isArcade)?.core
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
        platform(bySlug: canonicalSlug, isArcade: rom.isArcade)
    }

    /// The platform for an already-resolved slug, matched on the same
    /// slug families the control layout switch uses, sourced from
    /// Resources/cores.json. Split from `platform(for:canonicalSlug:)` so
    /// callers with no live rom or session, only a slug persisted at keep
    /// time, can still resolve correctly while fully offline.
    static func platform(bySlug slug: String, isArcade: Bool) -> NativePlatform? {
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
        default:
            return nil
        }
    }
}
