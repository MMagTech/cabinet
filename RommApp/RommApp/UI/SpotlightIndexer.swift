#if os(iOS)
import CoreSpotlight
import UIKit

/// Puts the library into Spotlight, so typing a game's name on the home
/// screen finds it.
///
/// The whole library, not only kept games: search answers "do I have
/// Progear", and answering no because it happens not to be downloaded
/// right now would be a wrong answer. A result opens the game's launch
/// screen rather than booting it, the same call every other way into
/// the app makes, because a search result that silently began a
/// gigabyte download would be a poor surprise. The tap itself lands in
/// `DeepLink.swift`.
enum SpotlightIndexer {
    private static let domain = "games"
    private static let stampKey = "spotlight.lastIndexed"
    private static let serverKey = "spotlight.indexedServer"
    private static let pageSize = 200

    /// How often the whole library is walked again. Libraries change on
    /// the scale of days, not minutes, and the walk is a real cost, a
    /// page per couple hundred games, so once a day is plenty. Anything
    /// added since simply is not searchable until tomorrow, which is
    /// what its own library screen is for.
    private static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// Entries expire on their own a week out. That is how a game
    /// deleted from the server leaves Spotlight without this code ever
    /// having to notice the deletion: the daily walk keeps live games
    /// fresh, and anything the walk stops seeing ages out.
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    @MainActor private static var running = false

    @MainActor
    static func refresh(session: Session) {
        guard session.stage == .ready else { return }
        guard !running else { return }

        let host = session.serverURL?.host ?? ""
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: stampKey) as? Date ?? .distantPast
        let sameServer = defaults.string(forKey: serverKey) == host
        if sameServer, Date().timeIntervalSince(last) < refreshInterval { return }

        running = true
        Task {
            await index(session: session, host: host)
            running = false
        }
    }

    /// Pairing again, or with a different server: whatever was indexed
    /// describes an account this phone no longer speaks for, and a
    /// search result naming somebody else's games is a small privacy
    /// leak with a delete-all fix.
    static func wipe() {
        UserDefaults.standard.removeObject(forKey: stampKey)
        UserDefaults.standard.removeObject(forKey: serverKey)
        CSSearchableIndex.default().deleteAllSearchableItems()
    }

    private static func index(session: Session, host: String) async {
        // Read once, same as the widget writer and for the same reason:
        // the label baked into each entry is whatever the person has
        // chosen to see platforms called.
        let labelSource = PlatformLabelSource(
            rawValue: UserDefaults.standard.string(forKey: PlatformLabelSource.key) ?? ""
        ) ?? .platformName
        let names = await MainActor.run { session.platformNames }

        var offset = 0
        var total = Int.max
        while offset < total {
            // A failed page abandons the walk without stamping it done,
            // so the next foreground tries again. Whatever was already
            // indexed stands; half a library beats none.
            guard let page = try? await session.roms(limit: pageSize, offset: offset) else { return }
            guard !page.items.isEmpty else { break }
            total = page.total

            let items = await searchableItems(
                for: page.items, session: session, labelSource: labelSource, names: names
            )
            do {
                try await CSSearchableIndex.default().indexSearchableItems(items)
            } catch {
                NSLog("[spotlight] indexing failed at offset %d: %@", offset, "\(error)")
                return
            }
            offset += page.items.count
        }

        UserDefaults.standard.set(Date(), forKey: stampKey)
        UserDefaults.standard.set(host, forKey: serverKey)
        NSLog("[spotlight] indexed %d games", offset)
    }

    private static func searchableItems(
        for roms: [Rom], session: Session,
        labelSource: PlatformLabelSource, names: [Int: String]
    ) async -> [CSSearchableItem] {
        var items: [CSSearchableItem] = []
        for rom in roms {
            let attributes = CSSearchableItemAttributeSet(contentType: .item)
            attributes.title = rom.displayName
            attributes.contentDescription = rom.platformLabel(source: labelSource, platformNames: names)
            // Art comes from the cover cache or not at all. Fourteen
            // hundred cover downloads to decorate search results nobody
            // has asked for yet is not a bill worth running up; a game
            // browsed even once has its cover here already, and the rest
            // show the app icon, which iOS does on its own.
            if let path = rom.pathCoverSmall ?? rom.pathCoverLarge,
               let image = await CoverCache.shared.image(forKey: path) {
                attributes.thumbnailData = image.jpegData(compressionQuality: 0.7)
            }
            // The same shape the top shelf uses for its item identifiers,
            // parsed back apart in DeepLink.swift.
            let item = CSSearchableItem(
                uniqueIdentifier: "rom-\(rom.id)",
                domainIdentifier: domain,
                attributeSet: attributes
            )
            item.expirationDate = Date().addingTimeInterval(lifetime)
            items.append(item)
        }
        return items
    }
}
#endif
