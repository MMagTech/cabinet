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

/// Whether the native player's last session ended on purpose.
///
/// A webview crash kills only the WebContent process, so the app is still
/// alive to count it. A native core crash takes the whole app, so the only
/// witness is a note left behind: set while a native game runs, cleared on
/// every deliberate exit, checked at the next launch. A note alone is not
/// a crash, though. iOS evicts backgrounded apps routinely and that is not
/// the core's fault, so the note also records whether the app ever left
/// the foreground mid-game. Died in the foreground means the core (or the
/// app around it) went down mid-play, and that is what gets counted.
enum NativeSessionMarker {
    private static let runningKey = "com.mmagtech.RommApp.nativeGameInProgress"
    private static let backgroundedKey = "com.mmagtech.RommApp.nativeGameBackgrounded"

    static func recordGameRunning(romId: Int) {
        UserDefaults.standard.set(romId, forKey: runningKey)
        UserDefaults.standard.removeObject(forKey: backgroundedKey)
    }

    static func recordBackgrounded() {
        guard UserDefaults.standard.object(forKey: runningKey) != nil else { return }
        UserDefaults.standard.set(true, forKey: backgroundedKey)
    }

    static func recordCleanExit() {
        UserDefaults.standard.removeObject(forKey: runningKey)
        UserDefaults.standard.removeObject(forKey: backgroundedKey)
    }

    /// Called once at app launch. Counts a native crash only for a session
    /// that died without ever leaving the foreground, then clears the note
    /// either way so one death is never counted twice.
    @MainActor
    static func settleAtLaunch() {
        guard UserDefaults.standard.object(forKey: runningKey) != nil else { return }
        let romId = UserDefaults.standard.integer(forKey: runningKey)
        let wasBackgrounded = UserDefaults.standard.bool(forKey: backgroundedKey)
        if !wasBackgrounded {
            Compatibility.shared.recordNativeCrash(romId: romId)
        }
        recordCleanExit()
    }
}
