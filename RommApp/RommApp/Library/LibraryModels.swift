import Foundation

/// One game, decoding only what the library screens use. The server sends far
/// more; everything unlisted is ignored on purpose so RomM version bumps that
/// add or rename unrelated fields cannot break decoding.
struct Rom: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
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

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return fsNameNoTags
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary
        case fsNameNoTags = "fs_name_no_tags"
        case fsNameNoExt = "fs_name_no_ext"
        case platformId = "platform_id"
        case platformSlug = "platform_slug"
        case platformFsSlug = "platform_fs_slug"
        case platformDisplayName = "platform_display_name"
        case pathCoverSmall = "path_cover_small"
        case pathCoverLarge = "path_cover_large"
        case fsSizeBytes = "fs_size_bytes"
    }

    /// RomM's ARCADE_SYSTEMS: platforms whose games run on MAME or FBNeo
    /// cores and resolve controls per game through the profile map.
    var isArcade: Bool {
        ["arcade", "neogeoaes", "neogeomvs", "neo-geo-cd"].contains(platformSlug)
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
}

/// `GET /api/roms` wraps results in limit and offset pagination.
struct RomPage: Decodable {
    let items: [Rom]
    let total: Int
    let limit: Int
    let offset: Int
}
