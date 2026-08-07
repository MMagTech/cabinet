import Foundation

/// The nested object RomM attaches to a save or a state: a nullable
/// `screenshot` whose `download_path` resolves like any other asset path.
/// Confirmed against the live server's OpenAPI schema.
private struct AssetScreenshot: Decodable {
    let downloadPath: String
    enum CodingKeys: String, CodingKey { case downloadPath = "download_path" }
}

/// A saved game, the cartridge battery kind. Survives changing cores.
struct GameSave: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let updatedAt: String?
    let emulator: String?
    let screenshotPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case updatedAt = "updated_at"
        case emulator
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        emulator = try container.decodeIfPresent(String.self, forKey: .emulator)
        screenshotPath = try container.decodeIfPresent(AssetScreenshot.self, forKey: .screenshot)?.downloadPath
    }
}

/// A save state, a snapshot of memory. Tied to the core that wrote it, which
/// is why the launch screen greys out states from a different emulator rather
/// than letting someone load one that cannot work. Its screenshot is a real
/// frame from the moment saved, captured on the way into the pause menu
/// (see `__cabinetPauseWithCapture` in PlayerView) rather than after, since
/// a paused WebGL canvas reads back blank.
struct GameState: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let updatedAt: String?
    let emulator: String?
    let screenshotPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case updatedAt = "updated_at"
        case emulator
        case screenshot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        fileName = try container.decode(String.self, forKey: .fileName)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        emulator = try container.decodeIfPresent(String.self, forKey: .emulator)
        screenshotPath = try container.decodeIfPresent(AssetScreenshot.self, forKey: .screenshot)?.downloadPath
    }

    /// A state that exists on this screen because `KeptGameStore`
    /// downloaded it, not because the server was just asked. Built
    /// straight from the kept game's manifest so the Resume-from list
    /// carries a real, selectable row with zero network, whether that is
    /// the only state available (offline) or one already covered by a
    /// fresher live fetch (online, where it is filtered out instead, see
    /// `GameLaunchView.load`). No filename or screenshot: nothing local
    /// stores either, and the row degrades to a plain date-only entry
    /// with no Screenshot option, which the row menu already handles.
    init(localStateId: Int, updatedAt: String?, emulator: String) {
        id = localStateId
        fileName = ""
        self.updatedAt = updatedAt
        self.emulator = emulator
        screenshotPath = nil
    }
}

/// A BIOS file the platform may require. The app never manages these, it only
/// picks among what the server reports.
struct Firmware: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String
    let isVerified: Bool
    let missingFromFS: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case isVerified = "is_verified"
        case missingFromFS = "missing_from_fs"
    }
}

/// Which emulator cores can run a given platform.
///
/// RomM's API has no endpoint for this. The only real source is
/// `_EJS_CORES_MAP` in RomM's own frontend, which is what its player reads
/// to build its core picker, so this file is generated from that constant
/// rather than typed by hand. Regenerate with tools/generate_cores_map.py
/// whenever RomM's core support moves on.
///
/// A first attempt at correcting this file by hand on 2026-08-02 made
/// things worse before it made them better: two entries, bsnes and
/// genesis_plus_gx_wide, were removed believing them fabricated, having
/// been checked against the wrong source, EmulatorJS's own generic core
/// registry rather than RomM's. They are real. RomM's file also carries a
/// second map, `_EJS_NIGHTLY_CORES_MAP`, layered in only when a server has
/// netplay enabled, an admin toggle this app cannot see. bsnes and
/// genesis_plus_gx_wide live only there, along with 3ds, new-nintendo-3ds
/// and intellivision entirely. The generator deliberately reads only the
/// stable map: seeding a nightly only core against a server that does not
/// have it would reproduce exactly the bug this exists to prevent,
/// EmulatorJS actually attempting to download a core file that is not
/// there, which shows as a red "Error downloading core" rather than a
/// clean fallback.
///
/// Falling back to an empty list is safe: the launch screen then offers no
/// core choice and RomM's own page picks, exactly as it does for every
/// platform this map excludes today.
enum CoreCatalog {
    private static let map: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "cores", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [:] }
        return parsed
    }()

    static func cores(for platformSlug: String) -> [String] {
        map[platformSlug] ?? []
    }

    /// Friendlier than the raw core id, which means nothing to most people.
    static func displayName(_ core: String) -> String {
        switch core {
        case "fbneo": return "FinalBurn Neo"
        case "mame2003": return "MAME 2003"
        case "mame2003_plus": return "MAME 2003 Plus"
        case "fbalpha2012_cps1": return "FB Alpha, CPS1"
        case "fbalpha2012_cps2": return "FB Alpha, CPS2"
        case "snes9x": return "Snes9x"
        case "bsnes": return "bsnes"
        case "gambatte": return "Gambatte"
        case "mgba": return "mGBA"
        case "mupen64plus_next": return "Mupen64Plus Next"
        case "pcsx_rearmed": return "PCSX ReARMed"
        case "genesis_plus_gx": return "Genesis Plus GX"
        case "picodrive": return "PicoDrive"
        case "melonds": return "melonDS"
        case "desmume2015": return "DeSmuME"
        case "opera": return "Opera"
        case "puae": return "PUAE"
        case "handy": return "Handy"
        case "prosystem": return "ProSystem"
        case "stella2014": return "Stella"
        default: return core
        }
    }

    /// A hint for the ones where the default is a trap. RomM offers the oldest
    /// MAME first for arcade, which cannot run anything newer than 2003.
    static func note(_ core: String) -> String? {
        switch core {
        case "mame2003":
            return "MAME 0.78 from 2003. Games newer than that will not start."
        case "mame2003_plus":
            return "Wider compatibility than MAME 2003, still an old set."
        case "fbneo":
            return "Best for Neo Geo, CPS and most arcade boards."
        case "fbalpha2012_cps1", "fbalpha2012_cps2":
            return "Specialised for Capcom CPS hardware."
        default:
            return nil
        }
    }
}
