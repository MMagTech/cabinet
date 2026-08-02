import Foundation

/// What the emulator actually did last time a game loaded.
///
/// Exists because the interesting facts live inside the webview, on a phone,
/// while it is being held and played. A console cannot be attached to that,
/// so the player records what it saw and Settings reads it back. It answers
/// one question honestly: did the multi threaded core load, or did something
/// quietly fall back to the single threaded one.
enum EmulationInfo {
    static let key = "com.mmagtech.RommApp.lastCoreInfo"
    static let recoveriesKey = "com.mmagtech.RommApp.playerRecoveries"

    /// How many times iOS killed the player's web process and the app
    /// recovered by reloading. Counted because the kill is invisible by
    /// design: if it happens often, that is worth knowing about, and the
    /// only place it can be observed is a phone in someone's hands.
    static var recoveries: Int {
        UserDefaults.standard.integer(forKey: recoveriesKey)
    }

    static func recordRecovery() {
        UserDefaults.standard.set(recoveries + 1, forKey: recoveriesKey)
    }

    private static let vitalsKey = "com.mmagtech.RommApp.vitals"
    private static let vitalsAtDeathKey = "com.mmagtech.RommApp.vitalsAtDeath"

    /// The emulator's memory picture at the last autosave. Overwritten
    /// constantly while a game runs; interesting only in hindsight.
    static func recordVitals(_ line: String) {
        UserDefaults.standard.set(line, forKey: vitalsKey)
    }

    /// Freezes the last reading when the web process dies, so the numbers
    /// leading up to a kill survive it. The kill itself reports nothing:
    /// iOS gives no reason, so the only evidence is what was true a moment
    /// before.
    static func freezeVitalsAtDeath() {
        guard let line = UserDefaults.standard.string(forKey: vitalsKey) else { return }
        UserDefaults.standard.set(line, forKey: vitalsAtDeathKey)
    }

    static var vitalsAtDeath: String? {
        UserDefaults.standard.string(forKey: vitalsAtDeathKey)
    }

    /// The raw line the player recorded, for example
    /// "core fbneo-thread-wasm.data isolated=true sab=true".
    static var raw: String? {
        UserDefaults.standard.string(forKey: key)
    }

    /// The core file the page fetched, without the packaging noise.
    static var coreName: String? {
        guard let raw, let field = raw.split(separator: " ").dropFirst().first
        else { return nil }
        return String(field)
            .replacingOccurrences(of: "-wasm.data", with: "")
            .replacingOccurrences(of: ".data", with: "")
    }

    /// True when the core that loaded was the multi threaded build.
    static var isThreaded: Bool {
        coreName?.contains("-thread") ?? false
    }

    /// True when the page was cross origin isolated, which is what the server
    /// headers are for and what threading depends on.
    static var isIsolated: Bool {
        raw?.contains("isolated=true") ?? false
    }

    /// A plain sentence for someone who does not want to parse any of this.
    static var summary: String {
        guard let coreName else {
            return "Nothing recorded yet. Play a game and come back."
        }
        if isThreaded {
            return "\(coreName) loaded, using multiple cores."
        }
        if isIsolated {
            return "\(coreName) loaded single threaded, even though the server allows threading. This core may have no threaded build."
        }
        return "\(coreName) loaded single threaded. The server is not sending the cross origin isolation headers that threading needs."
    }
}

/// Whether the player keeps a local autosave while a game runs.
///
/// On by default, because it is what makes a killed web process cost
/// seconds instead of a run. It is a setting rather than a constant
/// because the honest answer to "is the autosave what keeps killing my
/// game" is to switch it off and find out, and because someone who never
/// wants a background write is entitled to that.
enum PlayerAutosave {
    static let key = "com.mmagtech.RommApp.autosaveEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
