import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What the home screen widget is allowed to know.
///
/// A widget runs in its own process with no network and no sight of the
/// app's own storage, so everything it draws has to be written somewhere
/// both can reach. This is that: a small list of games and a folder of
/// cover images inside the shared app group.
///
/// Deliberately its own type rather than sharing the Apple TV's
/// TopShelfSnapshot. The shapes look alike but the needs differ, the shelf
/// wants a 1x and 2x poster pair sized for a television while a widget
/// wants one image per game sized for a phone, and folding them together
/// would mean refactoring a shipped feature to serve an unshipped one.
/// Worth revisiting once both have settled.
enum WidgetSnapshot {
    static let suite = "group.com.mmagtech.Cabinet"
    private static let key = "widget.snapshot"

    static var defaults: UserDefaults? { UserDefaults(suiteName: suite) }

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suite)
    }

    /// Covers live beside the snapshot rather than inside it. Embedding
    /// them would put megabytes into a preferences file that both
    /// processes read on every widget refresh.
    static var coversDirectory: URL? {
        container?.appendingPathComponent("WidgetCovers", isDirectory: true)
    }

    struct Game: Codable, Equatable, Identifiable {
        let romId: Int
        let title: String
        let platform: String
        /// File name inside coversDirectory, or nil when the app had no
        /// cover cached for this game. The widget draws a placeholder
        /// rather than dropping the row, since a nameless gap reads as a
        /// bug and a game with no art does not.
        let coverFile: String?

        var id: Int { romId }
    }

    struct Payload: Codable, Equatable {
        let games: [Game]
        /// Favourites ride along for widgets configured to show them.
        /// Optional because it arrived after the first snapshots were
        /// written: an old snapshot without it still decodes, and the
        /// migration is to show nothing until the app writes a fresh one,
        /// never to throw the recents away with it.
        var favorites: [Game]?
        let writtenAt: Date
    }

    static func read() -> Payload? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    static func write(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults?.set(data, forKey: key)
    }

    /// Everything, for signing out or switching profile. A widget still
    /// showing the last account's games would be a small privacy leak on
    /// a shared home screen.
    static func clear() {
        defaults?.removeObject(forKey: key)
        if let coversDirectory {
            try? FileManager.default.removeItem(at: coversDirectory)
        }
    }

    static func coverURL(_ file: String) -> URL? {
        coversDirectory?.appendingPathComponent(file)
    }
}
