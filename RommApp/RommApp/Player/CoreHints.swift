import Foundation

/// Which core a particular arcade board is best played on.
///
/// FinalBurn Neo is the right default for arcade generally: it runs the
/// widest range of boards and it is what most of a library wants. But
/// breadth is not free here. The webview's content process runs under a
/// memory ceiling that the app cannot raise, and CPS2 games on FBNeo sit
/// over it: Progear and Armored Warriors both died about a minute into
/// play, repeatedly, and the same deaths reproduce in Safari with none of
/// this app involved. On fbalpha2012_cps2, a core that knows one board and
/// nothing else, they are steady.
///
/// So the board picks the core. The map is keyed by romset shortname, the
/// same join key the control profiles use, and generated from MAME's own
/// driver sources by tools/core_hints.py rather than transcribed, because
/// a hand written list of five hundred romsets would be wrong within a
/// week.
///
/// This is a recommendation, never a lock: the launch screen still offers
/// every core RomM supports, and a choice made for a specific game always
/// wins over the hint.
enum CoreHints {
    private static let map: [String: String] = {
        guard let url = Bundle.main.url(forResource: "core_hints", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            assertionFailure("core_hints.json missing. Regenerate with tools/core_hints.py")
            return [:]
        }
        return parsed
    }()

    /// The recommended core for a romset, if one is known and the server
    /// actually offers it.
    static func core(forShortname raw: String, available: [String]) -> String? {
        let name = raw.lowercased()
        if let hint = map[name], available.contains(hint) { return hint }
        // Names like "progear (world)" happen; the first token is the
        // romset, same fallback the profile lookup uses.
        if let token = name.split(separator: " ").first.map(String.init),
           token != name, let hint = map[token], available.contains(hint) {
            return hint
        }
        return nil
    }
}
