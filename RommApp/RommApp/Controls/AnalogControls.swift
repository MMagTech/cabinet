import Foundation

/// Which analog mechanisms a given arcade game actually has, read from
/// analog-controls.json, which tools/gen_analog_controls.py derives from
/// the MAME 2003-Plus driver source itself. This exists because the
/// bundled profile map (profiles.json) flattens every dial, trackball,
/// paddle and gun game into one "special" bucket: it can say a game is
/// unusual but not what the game actually wants in your hands.
///
/// Keyed by romset shortname, like everything arcade. A miss means the
/// game has no analog controls, which for the overwhelming majority of
/// games is the truth and for the rest is indistinguishable from the
/// pre-analog app, so lookups fail toward exactly the old behavior.
struct AnalogControls: Decodable {
    var dial: Int?
    var paddle: Int?
    var trackball: Int?
    var lightgun: Int?
    var stick: Int?
    var axis: Int?
    var pedals: Int?
    /// A rotary joystick: the stick itself twists. Distinct from `dial`,
    /// which is a separate knob beside a stick.
    var rotary: Int?
    /// Whether the panel carried a joystick at all, stated rather than
    /// inferred. Nil means "decide from the profile", which is what every
    /// game did before this existed. Zero says the cabinet had none, and
    /// one says it did even though the rule would have removed it, which
    /// is the case a joystick-plus-spinner machine like Discs of Tron
    /// needs. A trackball cabinet defaults to zero without an entry here:
    /// the ball was the movement control and no machine in the library
    /// carried both.
    var joystick: Int?

    static func controls(forShortname raw: String) -> AnalogControls? {
        let name = raw.lowercased()
        // Curated cabinet facts beat generated inference, always. The
        // generated file records which input ports a board reads, which
        // is not the same question as what the player's hands were on:
        // inferring the second from the first split rotary joysticks in
        // half, handed out pedals nobody had, and missed Atari's rotary
        // games entirely. Anything in arcade-panels.json is a statement
        // about a real machine.
        if let curated = curatedTable[name] { return curated }
        if let hit = table[name] { return hit }
        // "progear (world)" style names happen; first token is the
        // romset, the same fallback CoreHints and the profile map use.
        if let token = name.split(separator: " ").first.map(String.init), token != name {
            return table[token]
        }
        return nil
    }

    private static let curatedTable: [String: AnalogControls] = {
        guard let url = Bundle.main.url(forResource: "arcade-panels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            assertionFailure("arcade-panels.json missing from the bundle")
            return [:]
        }
        // The file carries "_"-prefixed notes explaining each group, for
        // whoever corrects it next; they are not games.
        var out: [String: AnalogControls] = [:]
        for (key, value) in raw where !key.hasPrefix("_") {
            guard let dict = value as? [String: Int],
                  let encoded = try? JSONSerialization.data(withJSONObject: dict),
                  let decoded = try? JSONDecoder().decode(AnalogControls.self, from: encoded)
            else { continue }
            out[key] = decoded
        }
        return out
    }()

    private static let table: [String: AnalogControls] = {
        guard let url = Bundle.main.url(forResource: "analog-controls", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: AnalogControls].self, from: data)
        else {
            assertionFailure("analog-controls.json missing from the bundle. Regenerate with tools/gen_analog_controls.py")
            return [:]
        }
        return parsed
    }()
}
