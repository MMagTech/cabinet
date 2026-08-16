#if os(tvOS)
import Foundation
import TVServices
import UIKit

/// Keeps the top shelf snapshot up to date. The app writes, the
/// extension only ever reads. See `docs/scope-tvos-top-shelf.md` for why
/// the extension does not just fetch this itself.
///
/// Deliberately not driven from `HomeView.load()`, which already has
/// recents in hand. Two reasons: `HomeView.swift` is shared with iOS and
/// this is tvOS-only work, and Home is not guaranteed to be visited at
/// all, so a session spent entirely in Library and the player would
/// leave the Home screen showing a stale shelf. The cost is one extra
/// recents call per foreground, eight items, which is nothing next to
/// the cover art it avoids refetching.
enum TVTopShelfWriter {
    /// Matches `Session.recentlyPlayed`'s own default. Six posters fit
    /// across a 1080p shelf, so this fills the visible row and leaves a
    /// little to scroll rather than padding it out for its own sake.
    private static let limit = 8

    /// Serialised, because two of these can genuinely overlap: the app
    /// foregrounds while the report of the session that just ended is
    /// still in flight. Without this they race on the same poster
    /// directory and the same defaults key.
    private static var inFlight: Task<Void, Never>?

    @MainActor
    static func refresh(session: Session) {
        inFlight?.cancel()
        // Read here, where the main actor already is, rather than deep
        // inside the write: `platformsVersions` is main-actor isolated,
        // and the rest of this runs off it on purpose so that rendering
        // eight posters never touches the frame the UI is drawing.
        let platformsVersions = session.platformsVersions
        inFlight = Task { await write(session: session, platformsVersions: platformsVersions) }
    }

    /// Sign out and profile switch both land here. A shelf left standing
    /// after either one is showing one person's games to whoever picks
    /// up the remote next.
    static func wipe() {
        inFlight?.cancel()
        TopShelfSnapshot.clear()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func write(session: Session, platformsVersions: [String: String]) async {
        // Same ordering fix Home makes: a session that just ended has to
        // reach the server before recents are asked for, or the game
        // played a moment ago sorts under the one before it. No-op when
        // nothing is pending.
        await session.waitForPendingPlayReport()

        guard let page = try? await session.recentlyPlayed(limit: limit) else {
            // Left exactly as it was. A failed fetch is usually a server
            // that is asleep or a connection that dropped, and yesterday's
            // shelf is a far better answer to that than an empty one.
            return
        }
        guard !Task.isCancelled else { return }

        // Recents come from the account, not from this device, so
        // somebody who plays DS or PS2 on their phone has recents this
        // Apple TV has no core for and no webview to fall back on. A
        // shelf item that leads to "this platform isn't supported on
        // Apple TV yet" is a broken promise on the Home screen, so those
        // are filtered out here rather than explained later.
        let playable = page.items.filter { rom in
            let slug = rom.canonicalPlatformSlug(platformsVersions: platformsVersions)
            return NativePlatform.platform(for: rom, canonicalSlug: slug) != nil
        }

        guard let directory = TopShelfSnapshot.postersDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var games: [TopShelfSnapshot.Game] = []
        var written: Set<String> = []

        for rom in playable {
            guard !Task.isCancelled else { return }
            guard let files = await posters(for: rom, in: directory, session: session) else { continue }
            written.insert(files.oneX)
            written.insert(files.twoX)
            games.append(
                TopShelfSnapshot.Game(
                    romId: rom.id,
                    title: rom.displayName,
                    posterFile: files.oneX,
                    posterFile2x: files.twoX
                )
            )
        }

        guard !Task.isCancelled else { return }

        prune(directory: directory, keeping: written)
        TopShelfSnapshot.save(TopShelfSnapshot.Payload(games: games))
        // A hint, not a command. tvOS refreshes the shelf when it
        // decides to, so nothing here should assume the Home screen is
        // current to the second, because it will not be.
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// The poster file for one game, written if it is not already there.
    ///
    /// The filename carries a hash of the cover path, and RomM's cover
    /// paths already carry the timestamp of the last artwork change
    /// (`...small.png?ts=2025-03-11 06:50:19`), so replacing a game's art
    /// on the server changes the filename and rewrites the poster by
    /// itself, while unchanged art costs nothing at all. That is what
    /// keeps the steady state of this whole feature at zero network
    /// requests for images: only a game whose art is new, or whose
    /// poster the system purged, is ever fetched.
    private static func posters(
        for rom: Rom, in directory: URL, session: Session
    ) async -> (oneX: String, twoX: String)? {
        let coverPath = rom.pathCoverSmall ?? rom.pathCoverLarge
        let stem = fingerprint(coverPath ?? "none-\(rom.id)")
        let names = (oneX: "\(stem).png", twoX: "\(stem)@2x.png")
        let urls = (
            oneX: directory.appendingPathComponent(names.oneX),
            twoX: directory.appendingPathComponent(names.twoX)
        )
        let manager = FileManager.default
        if manager.fileExists(atPath: urls.oneX.path), manager.fileExists(atPath: urls.twoX.path) {
            return names
        }

        var image: UIImage?
        if let coverPath {
            image = await CoverCache.shared.image(forKey: coverPath)
            if image == nil, let data = try? await session.coverData(path: coverPath) {
                image = UIImage(data: data)
            }
        }

        // Most of arcade has no cover art at all, and those games are
        // exactly the ones anyone is most likely to have played
        // recently. They get the same titled placeholder `CoverImage`
        // already draws everywhere else in the app, rendered here so the
        // extension never has to decide anything or draw anything.
        guard
            let oneX = render(image, title: rom.displayName, size: Self.posterSize).pngData(),
            let twoX = render(image, title: rom.displayName, size: Self.posterSize2x).pngData(),
            (try? oneX.write(to: urls.oneX, options: .atomic)) != nil,
            (try? twoX.write(to: urls.twoX, options: .atomic)) != nil
        else { return nil }
        return names
    }

    /// The poster shape the top shelf documents, at both screen scales.
    /// Apple's safe zone inside it is 380 by 570, which box art does not
    /// need: the whole point of a cover is that it fills its own edges.
    private static let posterSize = CGSize(width: 404, height: 608)
    private static let posterSize2x = CGSize(width: 808, height: 1216)

    /// RomM's covers are already about 2:3, the same shape the poster
    /// wants, so a real cover is drawn to fill with almost nothing
    /// cropped. Anything oddly proportioned is cropped rather than
    /// letterboxed: a poster with bars down its sides reads as a broken
    /// tile next to five that do not have them.
    ///
    /// The 1x and 2x files are each rendered from the original cover
    /// rather than one being a resize of the other, so neither is a
    /// scaled copy of an already-scaled image.
    private static func render(_ cover: UIImage?, title: String, size: CGSize) -> UIImage {
        // Scale pinned to 1, not left to the default. The default is the
        // screen's own scale, which would silently multiply the pixel
        // dimensions of the written file and make the 1x file secretly
        // a 2x one on some hardware. Here the numbers passed in are the
        // pixels that come out, on every device.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            guard let cover else {
                drawPlaceholder(title: title, in: size, context: context)
                return
            }
            let scale = max(size.width / cover.size.width, size.height / cover.size.height)
            let scaled = CGSize(width: cover.size.width * scale, height: cover.size.height * scale)
            cover.draw(in: CGRect(
                x: (size.width - scaled.width) / 2,
                y: (size.height - scaled.height) / 2,
                width: scaled.width,
                height: scaled.height
            ))
        }
    }

    /// The app's own panel colour, the same one `TVLibraryView` uses,
    /// with the title on it. Kept in sync by hand rather than shared,
    /// since that value lives in a private constant on a view.
    private static func drawPlaceholder(
        title: String, in size: CGSize, context: UIGraphicsImageRendererContext
    ) {
        UIColor(red: 0.14, green: 0.10, blue: 0.24, alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        // Sized off the poster rather than fixed, since this draws at
        // both scales: a point size tuned for the 808-wide file would
        // be twice as large as intended on the 404-wide one.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size.width * 0.08, weight: .semibold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            .paragraphStyle: style,
        ]
        let inset = size.width * 0.075
        let bounds = CGRect(
            x: inset, y: 0, width: size.width - inset * 2, height: size.height
        )
        let measured = (title as NSString).boundingRect(
            with: CGSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
        (title as NSString).draw(
            with: CGRect(
                x: bounds.minX,
                y: (size.height - measured.height) / 2,
                width: bounds.width,
                height: measured.height
            ),
            options: [.usesLineFragmentOrigin],
            attributes: attributes,
            context: nil
        )
    }

    /// Posters for games that have dropped off the shelf, and stale ones
    /// for games whose art changed, are deleted on every write. The
    /// system can purge this directory whenever it likes, but that is
    /// not a reason to leave it growing in the meantime.
    private static func prune(directory: URL, keeping: Set<String>) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where !keeping.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Same cheap djb2 hash `CoverCache` uses on the same kind of value,
    /// for the same reason: a cover path is a URL path with slashes and
    /// a query string, so it cannot be a filename as is.
    private static func fingerprint(_ key: String) -> String {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return String(hash, radix: 16)
    }
}
#endif
