import Foundation

/// Whether the last play session ended on purpose.
///
/// iOS evicts backgrounded apps whenever it wants the memory, and an evicted
/// app gets no callback, no warning, nothing. The only way to know it
/// happened is to leave a note while a game is running and clear it on the
/// one path that is a deliberate exit. A note still standing at the next
/// launch means the game was taken, not left, and that distinction is what
/// makes offering "continue where you left off" safe: a run someone walked
/// away from on purpose starts fresh, a run iOS killed gets offered back.
///
/// The autosave timestamps live here too, mirrored from the injected script,
/// because native code has to decide whether an offer is worth making before
/// any webview exists to ask.
/// When a state was last banked from the pause menu, per game.
///
/// The state itself lives in the webview's storage; this is only the fact
/// that one exists, which native code needs before the webview is asked
/// anything, to decide whether the pause menu should offer to go back.
enum ManualSave {
    private static func key(_ romId: Int) -> String {
        "com.mmagtech.RommApp.manualSave.\(romId)"
    }

    static func record(romId: Int) {
        UserDefaults.standard.set(Date(), forKey: key(romId))
    }

    static func date(romId: Int) -> Date? {
        UserDefaults.standard.object(forKey: key(romId)) as? Date
    }
}

enum SessionMarker {
    private static let runningKey = "com.mmagtech.RommApp.gameInProgress"
    private static func autosaveKey(_ romId: Int) -> String {
        "com.mmagtech.RommApp.lastAutosave.\(romId)"
    }

    static func recordGameRunning(romId: Int) {
        UserDefaults.standard.set(romId, forKey: runningKey)
    }

    static func recordCleanExit() {
        UserDefaults.standard.removeObject(forKey: runningKey)
    }

    /// The rom whose session died without a clean exit, if any.
    static var interruptedRomId: Int? {
        let id = UserDefaults.standard.integer(forKey: runningKey)
        return UserDefaults.standard.object(forKey: runningKey) == nil ? nil : id
    }

    static func recordAutosave(romId: Int) {
        UserDefaults.standard.set(Date(), forKey: autosaveKey(romId))
    }

    static func autosaveDate(romId: Int) -> Date? {
        UserDefaults.standard.object(forKey: autosaveKey(romId)) as? Date
    }

    /// True when this rom's last session was interrupted and a local autosave
    /// fresh enough to matter exists. Half a day, because an offer the user
    /// must accept can afford a wider window than a silent restore, and a
    /// run from last week is noise however it ended.
    static func offersResume(romId: Int) -> Bool {
        guard interruptedRomId == romId,
              let saved = autosaveDate(romId: romId)
        else { return false }
        return Date().timeIntervalSince(saved) < 12 * 60 * 60
    }
}
