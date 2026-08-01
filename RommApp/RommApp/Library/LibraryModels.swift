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
    let platformSlug: String
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
}

/// `GET /api/roms` wraps results in limit and offset pagination.
struct RomPage: Decodable {
    let items: [Rom]
    let total: Int
    let limit: Int
    let offset: Int
}
