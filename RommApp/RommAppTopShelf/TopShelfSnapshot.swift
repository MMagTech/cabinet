#if os(tvOS)
import Foundation

/// What the app leaves behind for the top shelf extension to read.
///
/// Compiled into both targets, which is why it lives in the extension's
/// own folder rather than in `RommAppTV/`: the extension is a separate
/// process and cannot see the app's files, so this is the one piece of
/// code both sides genuinely share. It deliberately depends on nothing
/// but Foundation. The extension links no part of the app, not `Session`,
/// not the models, not a core, and this file is what keeps that true.
///
/// The split between where the list lives and where the images live is
/// not arbitrary, it is the tvOS file system:
///
/// - Inside a shared app group container, **only `Library/Caches` is
///   writable**, and everything in it is purgeable by the system at any
///   time. That is where the posters go, because an image is
///   regenerable and a purged one heals the next time the app runs.
/// - Real persistent storage on tvOS is 500KB of `UserDefaults` and
///   nothing else. That is where the list goes, because the list is what
///   must not vanish. Eight entries of an id, a title and a filename is
///   a kilobyte or two, and the app shares that budget with
///   `TVProfileStore`, so this stays deliberately small: no summaries,
///   no platform metadata, no anything the shelf does not draw.
enum TopShelfSnapshot {
    /// Must match the App Groups capability on both the tvOS app and the
    /// extension. Not derived from the bundle id on purpose: Debug and
    /// Release ship under two different bundle ids
    /// (`com.mmagtech.CabinetDev.tv` and `com.mmagtech.Cabinet`) and both
    /// need to reach the same container, or a dev build would write a
    /// snapshot the release build's extension cannot see.
    static let appGroup = "group.com.mmagtech.Cabinet"

    private static let snapshotKey = "com.mmagtech.RommAppTV.topShelfSnapshot"

    /// One game on the shelf. `posterFile` is a filename inside the
    /// posters directory, never a full path: the container URL differs
    /// per process and per install, so a stored absolute path would be
    /// wrong the moment anything moved.
    struct Game: Codable, Equatable {
        let romId: Int
        let title: String
        /// Both scales are stored by name rather than one name with the
        /// other derived by appending "@2x". Deriving it would put the
        /// same string-building rule in two processes and let them drift
        /// apart silently, which is the sort of bug that shows up as
        /// half a shelf having no art.
        let posterFile: String
        let posterFile2x: String
    }

    struct Payload: Codable, Equatable {
        /// Bumped only if this shape changes incompatibly. A snapshot is
        /// derived data, so the migration for a version the reader does
        /// not know is to ignore it and let the app write a fresh one,
        /// never to crash and never to guess.
        var version: Int = 1
        var games: [Game]
    }

    /// Not private: the writer keys its own rules-version stamp off the
    /// same suite, so a change in what BELONGS on the shelf can clear a
    /// stale snapshot without waiting on a network round trip.
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    // MARK: Reading, which is all the extension ever does

    static func load() -> Payload? {
        guard let data = defaults?.data(forKey: snapshotKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1
        else { return nil }
        return payload
    }

    /// Where a game's two posters actually are, or nil if the system has
    /// purged either one. The caller has to handle nil rather than
    /// assume they survived; that is the whole point of it being a
    /// cache. Both or neither, because a shelf item that has art at one
    /// screen scale and not the other is a worse answer than one that
    /// stands aside until the app can write them again.
    static func existingPosterURLs(_ game: Game) -> (oneX: URL, twoX: URL)? {
        guard let directory = postersDirectory else { return nil }
        let oneX = directory.appendingPathComponent(game.posterFile)
        let twoX = directory.appendingPathComponent(game.posterFile2x)
        let manager = FileManager.default
        guard manager.fileExists(atPath: oneX.path), manager.fileExists(atPath: twoX.path) else {
            return nil
        }
        return (oneX, twoX)
    }

    static var postersDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            // Not the container root, which is not writable on tvOS.
            .appendingPathComponent("Library/Caches/TopShelfPosters", isDirectory: true)
    }

    // MARK: Writing, which only the app ever does

    static func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults?.set(data, forKey: snapshotKey)
    }

    /// Signing out and switching profiles both land here. A shelf left
    /// behind after either one is showing somebody else's games on the
    /// household's home screen.
    static func clear() {
        defaults?.removeObject(forKey: snapshotKey)
        if let directory = postersDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

}
#endif
