import Foundation

/// One file inside a multi-file ROM, fetchable individually through
/// `/api/roms/{id}/files/content/{file_name}`. Used for export instead of
/// the single-file content endpoint whenever `Rom.hasMultipleFiles` is
/// true, and instead of the zip endpoint, which the scope doc's Open items
/// flags as broken through the reverse proxy.
struct RomFile: Decodable, Identifiable, Hashable {
    let id: Int
    let fileName: String

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
    }
}

/// One game, decoding only what the library screens use. The server sends far
/// more; everything unlisted is ignored on purpose so RomM version bumps that
/// add or rename unrelated fields cannot break decoding.
///
/// Encodable too, purely for `KeptGameStore`: a kept game's manifest embeds
/// the full `Rom` it was kept from, captured once at keep time, so offline
/// navigation (Home's resume list, cover art, arcade control resolution)
/// has everything a live library fetch would have given it, with no new
/// round trip. Round-tripping through this app's own local JSON only; never
/// sent back to the server, so reusing the snake_case CodingKeys is harmless.
struct Rom: Codable, Identifiable, Hashable {
    let id: Int
    let name: String?
    /// The actual filename on disk, extension included. What
    /// `/api/roms/{id}/content/{file_name}` expects as its last path
    /// component.
    let fsName: String
    let fsNameNoTags: String
    /// For arcade this is the romset shortname, the join key into the
    /// bundled MAME control profile map.
    let fsNameNoExt: String
    let platformId: Int
    /// The IGDB metadata slug. Namespaces the localStorage keys RomM's own
    /// player reads and writes, `player:{platformSlug}:core` among them, so
    /// this app must seed and clear those keys under exactly this value to
    /// agree with RomM about which game they belong to. Not safe to use for
    /// anything else: IGDB disambiguates near duplicate platform entries
    /// with a trailing "--1", TurboGrafx-16 among them, and that string
    /// appears nowhere in EmulatorJS's own core catalogue.
    let platformSlug: String
    /// The platform's folder name on the server's filesystem, chosen by
    /// whoever set the instance up and free to be anything. This is the key
    /// into RomM's admin editable PLATFORMS_VERSIONS mapping, which is the
    /// only reliable way to reach the short name EmulatorJS's core
    /// catalogue actually indexes by.
    let platformFsSlug: String
    let platformDisplayName: String?
    let summary: String?
    let pathCoverSmall: String?
    let pathCoverLarge: String?
    let fsSizeBytes: Int64
    let hasMultipleFiles: Bool
    /// RomM's content hash for the rom, the filename-proof identity the
    /// Vectrex overlay matching keys on. Optional twice over: older
    /// RomM versions may omit it, and kept-game manifests written
    /// before it existed decode cleanly to nil, so nothing persisted
    /// needs migrating.
    let md5Hash: String?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return fsNameNoTags
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary
        case fsName = "fs_name"
        case fsNameNoTags = "fs_name_no_tags"
        case fsNameNoExt = "fs_name_no_ext"
        case platformId = "platform_id"
        case platformSlug = "platform_slug"
        case platformFsSlug = "platform_fs_slug"
        case platformDisplayName = "platform_display_name"
        case pathCoverSmall = "path_cover_small"
        case pathCoverLarge = "path_cover_large"
        case fsSizeBytes = "fs_size_bytes"
        case hasMultipleFiles = "has_multiple_files"
        case md5Hash = "md5_hash"
    }

    /// RomM's ARCADE_SYSTEMS: platforms whose games run on MAME or FBNeo
    /// cores and resolve controls per game through the profile map.
    var isArcade: Bool {
        PlatformSupport.arcadeSlugs.contains(platformSlug)
    }

    /// The short name EmulatorJS's own core catalogue actually indexes by,
    /// resolved the same way RomM's own page resolves it: look the folder
    /// name up in the server's admin editable mapping, and only fall back
    /// to the folder name itself, lowercased, when nothing is mapped. Every
    /// lookup this app makes against its bundled core and control data
    /// belongs on this value, never on `platformSlug`, which is IGDB's
    /// metadata slug and answers a different question.
    func canonicalPlatformSlug(platformsVersions: [String: String]) -> String {
        (platformsVersions[platformFsSlug] ?? platformFsSlug).lowercased()
    }

    /// What to put in front of someone for this rom's platform. Never used
    /// for a lookup, only for a label: `canonicalPlatformSlug` above is the
    /// value anything that talks to RomM or this app's own bundled data
    /// must use instead.
    ///
    /// Metadata name and folder name can each be wrong in ways the other is
    /// not: a platform matched against an ambiguous IGDB entry gets a
    /// mangled metadata name with no folder involved, a platform someone
    /// named badly on disk has a clean metadata name sitting right next to
    /// it. Neither wrong answer is rare enough to hardcode a fix for, so
    /// which one leads is a setting rather than a fallback order this app
    /// decides alone. Both sides still fall back toward the raw slug
    /// before ever failing to show anything.
    func platformLabel(source: PlatformLabelSource, platformNames: [Int: String]) -> String {
        let metadataName = { () -> String? in
            if let name = platformNames[platformId], !name.isEmpty { return name }
            if let display = platformDisplayName, !display.isEmpty { return display }
            return nil
        }
        let folderName = { !platformFsSlug.isEmpty ? platformFsSlug : nil }

        switch source {
        case .platformName:
            return metadataName() ?? folderName() ?? platformSlug
        case .folderName:
            return folderName() ?? metadataName() ?? platformSlug
        }
    }
}

/// Which name wins when showing a platform: RomM's own metadata name, the
/// same one its own web UI shows once an admin sets a custom name, or the
/// folder it was scanned from, which is usually what someone already calls
/// it. A setting because either can be the wrong one for a given server,
/// and there is no way to know which without asking.
enum PlatformLabelSource: String, CaseIterable {
    case platformName, folderName

    static let key = "com.mmagtech.RommApp.platformLabelSource"

    var label: String {
        switch self {
        case .platformName: return "Platform name"
        case .folderName: return "Folder name"
        }
    }
}

/// `GET /api/roms` wraps results in limit and offset pagination.
struct RomPage: Decodable {
    let items: [Rom]
    let total: Int
    let limit: Int
    let offset: Int
}
