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
    let slug: String
    let romCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, slug
        case romCount = "rom_count"
    }
}

/// Scopes are fixed at pair time. Adding one later means the person has to pair
/// again, so this list is deliberately in one place and should change rarely.
enum RommScopes {
    static let required = [
        "roms.read",
        "platforms.read",
        "firmware.read",
        "assets.read",
        "assets.write",
    ]
}
