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

    static func controls(forShortname raw: String) -> AnalogControls? {
        let name = raw.lowercased()
        if let hit = table[name] { return hit }
        // "progear (world)" style names happen; first token is the
        // romset, the same fallback CoreHints and the profile map use.
        if let token = name.split(separator: " ").first.map(String.init), token != name {
            return table[token]
        }
        return nil
    }

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
