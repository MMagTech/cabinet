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

/// Which generation's control data answers for a game.
///
/// `profiles.json` comes from a modern MAME listxml, and for FBNeo and
/// the webview player that is the right book. The native MAME core is a
/// 0.78 derivative, though, and twenty years of driver work separate the
/// two input databases: 872 of the games that core runs are absent from
/// the modern file entirely and fall through to the generic six button
/// guess, and hundreds more are described with buttons the 0.78 driver
/// never reads, which is dead glass under the player's thumb.
///
/// So that core's own listxml ships alongside, layered rather than
/// swapped in. Nothing consults it unless a caller asks for it by name,
/// which only the native player does and only while MAME is running.
enum ArcadeDataSet {
    /// The modern map alone, exactly as every caller has always had it.
    case modern
    /// The modern map, with the running core's own driver data filling
    /// its gaps and trimming buttons the driver cannot see.
    case mame2003Plus
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
    /// MAME 2003-Plus's own generation of the same data, read from that
    /// core's reference listxml by tools/gen_mame2003_profiles.py. Loaded
    /// lazily: a session that never launches a MAME game never pays for
    /// it, and on FBNeo it stays unread.
    private lazy var driverEntries: [String: [Any]] = {
        guard let url = Bundle.main.url(forResource: "mame2003-profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: [Any]]
        else {
            assertionFailure("mame2003-profiles.json missing from the bundle. Regenerate with tools/gen_mame2003_profiles.py")
            return [:]
        }
        return parsed
    }()

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
    func resolve(romId: Int, shortname: String, using set: ArcadeDataSet = .modern) -> ArcadeProfile {
        let base = resolve(shortname: shortname, using: set)
        guard let choice = ArcadeOverride.stored(for: romId) else { return base }
        return ArcadeProfile(
            profile: "override", buttons: choice.buttons, ways: choice.ways,
            coins: base.coins, parent: base.parent, vertical: base.vertical
        )
    }

    /// The data half of the chain: shortname, then the cloneof parent, then
    /// the generic default. The genre heuristic already ran at generation
    /// time on machines with no input data of their own.
    func resolve(shortname raw: String, using set: ArcadeDataSet = .modern) -> ArcadeProfile {
        let name = raw.lowercased()
        if let profile = profile(name, using: set) {
            return profile
        }
        // Not in the map at all. Try the tag-stripped name from the scope
        // doc's fallback list: "mslug2 (World)" style names happen.
        if let token = name.split(separator: " ").first.map(String.init),
           token != name, let profile = profile(token, using: set) {
            return profile
        }
        return .fallback
    }

    /// One name, against whichever books this caller opened.
    ///
    /// Two rules, both deliberately one-directional, because the two
    /// generations are each authoritative about a different question. The
    /// modern file describes the cabinet, refined over twenty years: it
    /// knows Galaga's stick was two way and that a mahjong panel is not a
    /// joystick with twenty six buttons. The core's own file describes
    /// what the running driver actually reads, which is the only thing
    /// that decides whether a drawn button does anything.
    ///
    /// So: the core's data answers for games the modern file has never
    /// heard of, and otherwise it may only lower a button count, never
    /// raise one and never change the shape of the panel. A game the
    /// modern file calls special stays special; ways, coins and TATE stay
    /// with the cabinet. Anything past that is a claim about what the
    /// player's hands were on, which belongs in arcade-panels.json as a
    /// stated fact rather than here as an inference.
    private func profile(_ name: String, using set: ArcadeDataSet) -> ArcadeProfile? {
        let modern = entry(name)
        guard set == .mame2003Plus, let driver = driverEntry(name) else { return modern }
        guard let modern else { return driver }
        guard modern.profile != "special", driver.buttons > 0,
              driver.buttons < modern.buttons
        else { return modern }
        return ArcadeProfile(
            profile: modern.profile, buttons: driver.buttons, ways: modern.ways,
            coins: modern.coins, parent: modern.parent, vertical: modern.vertical
        )
    }

    private func entry(_ name: String) -> ArcadeProfile? {
        guard let row = entries[name] else { return nil }
        return profile(from: row) { self.entry($0) }
    }

    private func driverEntry(_ name: String) -> ArcadeProfile? {
        guard let row = driverEntries[name] else { return nil }
        return profile(from: row) { self.driverEntry($0) }
    }

    /// Both files carry the same compact row, so one reader serves both.
    /// `inherited` is how a row follows its parent, kept a parameter so a
    /// row never crosses from one generation's file into the other's.
    private func profile(
        from row: [Any], inherited: (String) -> ArcadeProfile?
    ) -> ArcadeProfile? {
        let profile = row.first as? String ?? "six_button"
        let buttons = row.count > 1 ? (row[1] as? Int ?? 0) : 0
        let ways = row.count > 2 ? (row[2] as? String ?? "") : ""
        let coins = row.count > 3 ? (row[3] as? Int ?? 0) : 0
        let parent = row.count > 4 ? (row[4] as? String) : nil
        let vertical = row.count > 5 ? (row[5] as? Int ?? 0) == 1 : false

        // A machine whose input data lives on its parent still resolves,
        // because the generation step already inherited it. But a "special"
        // machine with a normal parent is worth following one hop.
        if profile == "special", let parent, let hop = inherited(parent) {
            return hop
        }

        return ArcadeProfile(
            profile: profile, buttons: buttons, ways: ways,
            coins: coins, parent: parent, vertical: vertical
        )
    }
}
