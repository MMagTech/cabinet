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
