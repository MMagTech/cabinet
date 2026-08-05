import Foundation

/// The last few things that went wrong anywhere in the app, for Debug to
/// surface. Exists because `RommError` cases were already typed and
/// thrown all over the app but nothing centrally remembered them, so a
/// bug report had nothing to point to beyond "it didn't work" unless it
/// happened to be reproduced live with someone watching.
///
/// A plain ring buffer, not a crash reporter: this records handled
/// errors the app already displayed or recovered from, nothing about
/// personal data, and nothing sent anywhere on its own. Debug's "Copy
/// diagnostics" is the only thing that ever reads it out.
enum DiagnosticsLog {
    private static let key = "com.mmagtech.RommApp.diagnosticsLog"
    private static let limit = 10

    struct Entry: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let context: String
        let message: String
        let romVersion: String?

        init(context: String, message: String, romVersion: String?) {
            id = UUID()
            timestamp = Date()
            self.context = context
            self.message = message
            self.romVersion = romVersion
        }
    }

    /// - Parameters:
    ///   - context: what was happening, plain and short, "Export",
    ///     "Data Saver", "Library load", not a stack trace.
    ///   - message: the same user-facing text already shown, if any.
    ///     Reusing it rather than a raw exception keeps this log free of
    ///     anything that was not already visible in the app.
    static func record(context: String, message: String, romVersion: String?) {
        var entries = recent
        entries.insert(Entry(context: context, message: message, romVersion: romVersion), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static var recent: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
            let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
