#if os(iOS)
import SwiftUI
import UIKit
import WidgetKit

/// Keeps the home screen widget's data current.
///
/// The same shape as the Apple TV's top shelf writer and for the same
/// reason: the thing that draws cannot fetch, so the app has to leave it
/// something to draw. Recents come from the account rather than the
/// device, so there is no local list to read; the app has to ask the
/// server while it can and write the answer down.
enum WidgetWriter {
    /// Enough for the largest widget's grid with a little slack, and
    /// small enough that the covers cost a couple of megabytes rather
    /// than the library's worth.
    private static let limit = 8

    static func refresh(session: Session) {
        Task { await write(session: session) }
    }

    static func wipe() {
        WidgetSnapshot.clear()
        reloadTimelines()
    }

    /// Whether anybody has actually put one on a home screen.
    ///
    /// Without this the app fetches recents and writes eight cover images
    /// on every sync for everyone, including the majority who will never
    /// add a widget. That is a request they did not ask for and a few
    /// megabytes of pictures nobody will see.
    ///
    /// The cost of asking is one cheap call into WidgetKit. The cost of
    /// being wrong is small in the other direction too: a widget added
    /// while the app is closed shows its empty state until the next
    /// launch, which is one launch away and what its empty state is for.
    private static func anyWidgetInstalled() async -> Bool {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case .success(let widgets): continuation.resume(returning: !widgets.isEmpty)
                // Not "no", because failing to ask is not an answer. Erring
                // towards writing keeps a widget somebody does have from
                // going stale over a transient error.
                case .failure: continuation.resume(returning: true)
                }
            }
        }
    }

    private static func write(session: Session) async {
        guard await anyWidgetInstalled() else { return }

        // A session that just ended has to reach the server before
        // recents are asked for, or the game played a moment ago sorts
        // under the one before it. The same ordering fix Home and the top
        // shelf both make.
        await session.waitForPendingPlayReport()

        guard let page = try? await session.recentlyPlayed(limit: limit) else {
            // Left exactly as it was. A failed fetch is a sleeping server
            // or a dropped connection, and yesterday's widget is a much
            // better answer to that than an empty one.
            return
        }
        guard let directory = WidgetSnapshot.coversDirectory else {
            NSLog("[widget] no container URL for the app group")
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            NSLog("[widget] could not make %@: %@", directory.path, "\(error)")
        }

        // Read once rather than per game. The widget has no session to
        // resolve platform names with, so whatever the person has chosen
        // to see them called is baked in here.
        let labelSource = PlatformLabelSource(
            rawValue: UserDefaults.standard.string(forKey: PlatformLabelSource.key) ?? ""
        ) ?? .platformName
        let names = await MainActor.run { session.platformNames }

        var games: [WidgetSnapshot.Game] = []
        var kept: Set<String> = []

        for rom in page.items {
            let file = await cover(for: rom, in: directory, session: session)
            if let file { kept.insert(file) }
            games.append(WidgetSnapshot.Game(
                romId: rom.id,
                title: rom.displayName,
                // Whatever the person has chosen to see platforms
                // called, resolved here because the widget has no
                // session to resolve it with.
                platform: rom.platformLabel(source: labelSource, platformNames: names),
                coverFile: file
            ))
        }

        // Covers for games that have fallen off the end of recents, which
        // would otherwise accumulate forever in a container nobody looks
        // at.
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in existing where !kept.contains(name) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }

        WidgetSnapshot.write(.init(games: games, writtenAt: Date()))
        reloadTimelines()
    }

    /// One image per game, at a size a phone actually draws, written into
    /// the shared container because the widget cannot read the app's own
    /// cache. Named from the cover's path so an unchanged cover is not
    /// rewritten on every refresh.
    private static func cover(
        for rom: Rom, in directory: URL, session: Session
    ) async -> String? {
        guard let path = rom.pathCoverSmall ?? rom.pathCoverLarge else { return nil }
        let name = "\(fingerprint(path)).png"
        let url = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }

        var image = await CoverCache.shared.image(forKey: path)
        if image == nil, let data = try? await session.coverData(path: path) {
            image = UIImage(data: data)
        }
        guard let image, let png = image.pngData() else { return nil }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            NSLog("[widget] could not write %@: %@", url.path, "\(error)")
            return nil
        }
        return name
    }

    private static func fingerprint(_ s: String) -> String {
        var hash: UInt64 = 5381
        for byte in s.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 36)
    }

    private static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
