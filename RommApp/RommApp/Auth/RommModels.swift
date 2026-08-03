import Foundation

/// Response shapes for the handful of calls this app makes.
///
/// Hand written on purpose. Generating a client from openapi.json is what makes
/// the existing third party iOS client break across RomM versions, so these
/// decode only the fields the app actually uses and ignore everything else.

/// `GET /api/heartbeat`, unauthenticated. Used to check that an address someone
/// typed is really a RomM instance before asking them to pair with it.
struct Heartbeat: Decodable {
    let system: System

    struct System: Decodable {
        let version: String

        enum CodingKeys: String, CodingKey { case version = "VERSION" }
    }

    enum CodingKeys: String, CodingKey { case system = "SYSTEM" }
}

/// `POST /api/auth/device/init` returns this with HTTP 201.
struct DeviceAuthInit: Decodable {
    let deviceCode: String
    /// Short code the person types into the RomM web UI, for example "V8CFTDW9".
    let userCode: String
    /// Server relative, for example "/pair/device?user_code=V8CFTDW9".
    let verificationPathComplete: String
    let expiresIn: Int
    /// Seconds the server wants between polls. Honour it rather than guessing.
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationPathComplete = "verification_path_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// `POST /api/auth/device/token` once the person has approved in the browser.
struct DeviceAuthToken: Decodable {
    let accessToken: String
    let deviceId: String
    let scopes: [String]

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case deviceId = "device_id"
        case scopes
    }
}

struct Platform: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    /// RomM's own computed `custom_name or name`: whatever an admin set at
    /// Settings > that platform's info drawer, or the metadata name when
    /// nobody has. RomM's own UI shows this, never the raw `name` on its
    /// own, so a display screen should read this and not `name` directly,
    /// or an admin's fix in that drawer would silently go unseen here.
    let displayName: String?
    let slug: String
    let fsSlug: String
    let romCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case displayName = "display_name"
        case fsSlug = "fs_slug"
        case romCount = "rom_count"
    }
}

/// A user collection, decoding only what favoriting needs. RomM marks the
/// one collection a person favorites into with `is_favorite`, distinct from
/// `/api/collections/virtual`'s metadata groupings: this is a real,
/// server-provisioned collection, found by that flag, never assumed to be
/// named "Favourites" or any other string.
struct Collection: Decodable, Identifiable {
    let id: Int
    let name: String
    let isFavorite: Bool
    let romIds: [Int]

    enum CodingKeys: String, CodingKey {
        case id, name
        case isFavorite = "is_favorite"
        case romIds = "rom_ids"
    }
}

/// Scopes are fixed at pair time. Adding one later means the person has to pair
/// again, so this list is deliberately in one place and should change rarely.
///
/// The webview player raises the bar beyond plain library browsing: RomM's
/// frontend asks `/api/users/me` (me.read) before it renders anything, marks
/// the game as last played through user rom props (roms.user.write), and
/// ingests play sessions the same way. Verified against protected_route
/// declarations in RomM's backend/endpoints.
///
/// collections.read is not for a collections feature. RomM's web frontend
/// treats any 403 from any endpoint as a dead session and bounces to its
/// login screen (frontend/src/services/api/index.ts), and its boot sequence
/// always fetches collections. Without the scope, the player loads and is
/// immediately kicked out. Any scope the SPA's startup path touches must be
/// granted, or the webview cannot host it.
enum RommScopes {
    static let required = [
        "me.read",
        "roms.read",
        "roms.user.read",
        "roms.user.write",
        "platforms.read",
        "firmware.read",
        "assets.read",
        "assets.write",
        "collections.read",
        // Favoriting a game, added 2026-08-03. Every existing pairing
        // predates this and must pair again once it hits a write to
        // /api/collections: see RommError.forbidden's message, which
        // already covers exactly this case.
        "collections.write",
    ]
}
