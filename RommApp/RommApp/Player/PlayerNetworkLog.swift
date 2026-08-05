import Foundation

/// Every request the real player's webview made last session, captured
/// automatically rather than requiring a live Web Inspector session to
/// watch. Exists specifically to verify Data Saver: whether a cached
/// game's `/content/` request appears here or not is the actual proof
/// EmulatorJS skipped re-fetching it, readable straight from Debug's
/// "Copy diagnostics" without anyone needing to be at a Mac watching in
/// real time.
///
/// `#if DEBUG` only, same as `isInspectable`: this is a developer tool,
/// not something worth shipping into a release build.
enum PlayerNetworkLog {
    private static let key = "com.mmagtech.RommApp.playerNetworkLog"
    // Was 40: too small. It trims from the *front*, oldest first, and
    // ~30 platform icon requests alone fire in the first moments of any
    // launch screen, silently evicting anything logged right at document
    // start, exactly where the cache-probe script's own messages land,
    // before a single genuinely useful line was ever read from Debug.
    private static let limit = 300

    static func append(_ line: String) {
        var lines = recent
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        UserDefaults.standard.set(lines, forKey: key)
    }

    static var recent: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Called once per player launch, right before the new session's
    /// requests start, so Debug always shows only the most recent game's
    /// traffic, not several sessions blurred together.
    static func startNewSession(romName: String) {
        UserDefaults.standard.set([], forKey: key)
        append("--- \(romName) ---")
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
