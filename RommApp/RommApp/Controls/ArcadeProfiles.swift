import Foundation

/// The bundled arcade control profile map, derived offline from MAME's
/// listxml by tools/mame_profiles.py and slimmed to what the app reads.
///
/// Keyed by romset shortname, which is why arcade ROMs must be named by
/// shortname: it is the only join key MAME and FBNeo understand. Values are
/// compact arrays: [profile, buttons, ways, coins, parent], with empty and
/// zero values trimmed from the tail to keep the bundle near a megabyte.
struct ArcadeProfile {
    let profile: String
    let buttons: Int
    let ways: String
    let coins: Int
    let parent: String?
    /// A TATE cabinet: the monitor was mounted rotated, so the game is
    /// taller than wide. Vertical games keep portrait with controls below
    /// the canvas; orientation is a property of the game, not the device.
    let vertical: Bool
    /// True when the shortname matched nothing and this is the generic
    /// guess, which the launch screen says out loud: a wrong six button
    /// default is exactly what the manual override exists to fix.
    var unmapped: Bool = false

    /// The scope doc's generic default: six button, eight way.
    static let fallback = ArcadeProfile(
        profile: "six_button", buttons: 6, ways: "8", coins: 1, parent: nil,
        vertical: false, unmapped: true
    )

    var isFourWay: Bool { ways == "4" }

    /// MAME's own "doublejoy" control type, classified by
    /// tools/mame_profiles.py: two joysticks per player, Smash TV and
    /// Robotron the canonical shape, one for movement and one that both
    /// aims and fires by direction, often with no dedicated fire button at
    /// all. A tank-drive game like Battlezone is technically the same MAME
    /// control type with a different shape, forward/back per tread rather
    /// than an 8-way aim; it gets the same second stick here rather than
    /// its own case; the override picker is the fix for a game this guess
    /// is wrong for, the same as it is for anything else in this profile.
    var isDualStick: Bool { profile == "dual_stick" }
}

/// Step one of the scope doc's resolution chain: the user picked the
/// controls for this game, persisted by ROM id. Only the stick and button
/// count are the user's to change; vertical stays with the cabinet data,
/// because a TATE monitor is a fact, not a preference.
enum ArcadeOverride {
    private static func key(_ romId: Int) -> String {
        "com.mmagtech.RommApp.arcadeOverride.\(romId)"
    }

    static func save(buttons: Int, ways: String, for romId: Int) {
        UserDefaults.standard.set(
            ["buttons": buttons, "ways": ways], forKey: key(romId)
        )
    }

    static func clear(for romId: Int) {
        UserDefaults.standard.removeObject(forKey: key(romId))
    }

    static func stored(for romId: Int) -> (buttons: Int, ways: String)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key(romId)),
              let buttons = dict["buttons"] as? Int,
              let ways = dict["ways"] as? String
        else { return nil }
        return (buttons, ways)
    }
}

final class ArcadeProfileStore {
    static let shared = ArcadeProfileStore()

    private let entries: [String: [Any]]

    private init() {
        guard let url = Bundle.main.url(forResource: "profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]]
        else {
            assertionFailure("profiles.json missing from the bundle. Regenerate with tools/mame_profiles.py")
            entries = [:]
            return
        }
        entries = parsed
    }

    /// The full resolution chain from the scope doc: the person's own
    /// choice for this rom first, then the cabinet data.
    func resolve(romId: Int, shortname: String) -> ArcadeProfile {
        let base = resolve(shortname: shortname)
        guard let choice = ArcadeOverride.stored(for: romId) else { return base }
        return ArcadeProfile(
            profile: "override", buttons: choice.buttons, ways: choice.ways,
            coins: base.coins, parent: base.parent, vertical: base.vertical
        )
    }

    /// The data half of the chain: shortname, then the cloneof parent, then
    /// the generic default. The genre heuristic already ran at generation
    /// time on machines with no input data of their own.
    func resolve(shortname raw: String) -> ArcadeProfile {
        let name = raw.lowercased()
        if let profile = entry(name) {
            return profile
        }
        // Not in the map at all. Try the tag-stripped name from the scope
        // doc's fallback list: "mslug2 (World)" style names happen.
        if let token = name.split(separator: " ").first.map(String.init),
           token != name, let profile = entry(token) {
            return profile
        }
        return .fallback
    }

    private func entry(_ name: String) -> ArcadeProfile? {
        guard let row = entries[name] else { return nil }

        let profile = row.first as? String ?? "six_button"
        let buttons = row.count > 1 ? (row[1] as? Int ?? 0) : 0
        let ways = row.count > 2 ? (row[2] as? String ?? "") : ""
        let coins = row.count > 3 ? (row[3] as? Int ?? 0) : 0
        let parent = row.count > 4 ? (row[4] as? String) : nil
        let vertical = row.count > 5 ? (row[5] as? Int ?? 0) == 1 : false

        // A machine whose input data lives on its parent still resolves,
        // because the generation step already inherited it. But a "special"
        // machine with a normal parent is worth following one hop.
        if profile == "special", let parent, let inherited = entry(parent) {
            return inherited
        }

        return ArcadeProfile(
            profile: profile, buttons: buttons, ways: ways,
            coins: coins, parent: parent, vertical: vertical
        )
    }
}
