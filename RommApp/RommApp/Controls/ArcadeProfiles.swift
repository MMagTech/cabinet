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

    /// The scope doc's generic default: six button, eight way.
    static let fallback = ArcadeProfile(
        profile: "six_button", buttons: 6, ways: "8", coins: 1, parent: nil
    )

    var isFourWay: Bool { ways == "4" }
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

    /// The resolution chain from the scope doc, minus the manual override,
    /// which arrives with the layout editor. Shortname, then the cloneof
    /// parent, then the generic default. The genre heuristic already ran at
    /// generation time on machines with no input data of their own.
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

        // A machine whose input data lives on its parent still resolves,
        // because the generation step already inherited it. But a "special"
        // machine with a normal parent is worth following one hop.
        if profile == "special", let parent, let inherited = entry(parent) {
            return inherited
        }

        return ArcadeProfile(
            profile: profile, buttons: buttons, ways: ways,
            coins: coins, parent: parent
        )
    }
}
