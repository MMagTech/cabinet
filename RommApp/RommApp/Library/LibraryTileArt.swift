import Foundation

/// Daily-stable cover picks for the library's artwork tiles, shared by the
/// iOS and tvOS library screens. Extracted from `TVLibraryView` when iOS
/// adopted the same tile treatment, rather than copy-pasted into it.
///
/// Covers are chosen at a random offset into each platform or collection
/// rather than from its first page, so a 141 game arcade set shows genuine
/// deep cuts instead of whatever sorts first alphabetically. The pick is
/// seeded by (id, day) rather than actually random: the same tile must
/// resolve to the same covers all day, or `CoverCache`'s disk store buys
/// nothing and the art pops in fresh on every visit. A new day rolls a
/// new pick.
enum LibraryTileArt {
    /// How many covers a finished tile carries. Anything short of this is
    /// treated as an incomplete result: not stored, and refetched next
    /// launch rather than cached as though it were correct.
    static let coversPerTile = 2

    /// Bumped whenever the art selection logic changes. Without it a
    /// stored pick from an earlier build keeps being restored for the rest
    /// of the day and the new logic never runs, which is exactly how a
    /// fixed Atari 7800 tile kept coming back with one cover.
    private static let schema = 2

    /// The day the art was last rolled, as a whole number of days.
    static var today: Int {
        Int(Date().timeIntervalSince1970 / 86_400)
    }

    /// Mosaic dictionary keys, namespaced so a platform can never collide
    /// with a collection that happens to share its integer id.
    static func key(platform: Platform) -> String { "p\(platform.id)" }
    static func key(collection: Collection) -> String { "c\(collection.id)" }

    /// Cover paths chosen on a previous launch, or empty if the stored
    /// pick is from another day. Restored before any network call so tiles
    /// are painted from the disk cache immediately; only a genuinely new
    /// roll has to wait on the server. Paths are short strings, a few KB
    /// for a whole library, which matters because tvOS gives an app only
    /// 500 KB of real persistent storage.
    ///
    /// The namespace keeps each platform's screen on its own storage keys:
    /// tvOS was here first with "tv", and iOS uses "ios" rather than
    /// inheriting a dictionary rolled for a different screen.
    static func restore(namespace: String) -> [String: [String]] {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: dayKey(namespace)) == today,
              let stored = defaults.dictionary(forKey: artKey(namespace)) as? [String: [String]]
        else { return [:] }
        // Only complete entries come back. A half filled tile from a
        // failed request must not be treated as settled for the day.
        return stored.filter { $0.value.count >= coversPerTile }
    }

    static func persist(_ mosaics: [String: [String]], namespace: String) {
        let defaults = UserDefaults.standard
        defaults.set(
            mosaics.filter { $0.value.count >= coversPerTile },
            forKey: artKey(namespace)
        )
        defaults.set(today, forKey: dayKey(namespace))
    }

    /// Fetches covers for every tile not already present in `existing`.
    /// Per tile, not all or nothing: a tile that was restored incomplete,
    /// or a platform never seen, gets its own request without disturbing
    /// the ones already settled. Returns only the new entries; the caller
    /// merges and persists.
    static func load(
        platforms: [Platform],
        collections: [Collection],
        existing: [String: [String]],
        session: Session
    ) async -> [String: [String]] {
        let day = today
        let wantPlatforms = platforms.filter { existing[key(platform: $0)] == nil }
        let wantCollections = collections.filter { existing[key(collection: $0)] == nil }
        guard !wantPlatforms.isEmpty || !wantCollections.isEmpty else { return [:] }

        var fresh: [String: [String]] = [:]
        await withTaskGroup(of: (String, [String]).self) { group in
            for platform in wantPlatforms {
                group.addTask {
                    let offset = seededOffset(id: platform.id, day: day, count: platform.romCount)
                    // matchedOnly means every game returned has art, so
                    // two requested is two shown, rather than a window of
                    // six with the coverless ones skipped and a half
                    // empty tile whenever several land in a row.
                    let page = try? await session.roms(
                        platformId: platform.id, limit: coversPerTile,
                        offset: offset, matchedOnly: true
                    )
                    var paths = page?.items.compactMap(\.pathCoverSmall) ?? []
                    if paths.isEmpty {
                        // matchedOnly guarantees art but demands a
                        // metadata match, and a custom platform can be
                        // full of hand-uploaded covers with no match at
                        // all: Game & Watch's 59 all have art and none
                        // had a match, so its tile drew bare. Ask again
                        // without the filter and keep whatever art is
                        // actually there.
                        let any = try? await session.roms(
                            platformId: platform.id, limit: 12,
                            offset: 0, matchedOnly: false
                        )
                        paths = Array((any?.items.compactMap(\.pathCoverSmall) ?? []).prefix(coversPerTile))
                    }
                    return (key(platform: platform), paths)
                }
            }
            for collection in wantCollections {
                group.addTask {
                    let offset = seededOffset(id: collection.id, day: day, count: collection.romCount)
                    let page = try? await session.roms(
                        collectionId: collection.id, limit: coversPerTile,
                        offset: offset, matchedOnly: true
                    )
                    return (key(collection: collection), page?.items.compactMap(\.pathCoverSmall) ?? [])
                }
            }
            for await (key, paths) in group where !paths.isEmpty {
                fresh[key] = paths
            }
        }
        return fresh
    }

    /// A stable pseudo-random offset. Deliberately not `Int.random`: the
    /// same tile must resolve to the same offset every time it is asked
    /// today, and to a different one tomorrow.
    static func seededOffset(id: Int, day: Int, count: Int) -> Int {
        guard count > 2 else { return 0 }
        var seed = UInt64(truncatingIfNeeded: id &* 2_654_435_761 &+ day &* 40_503)
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Int(seed % UInt64(count - 1))
    }

    private static func artKey(_ namespace: String) -> String {
        "com.mmagtech.RommApp.\(namespace).tileArt.v\(schema)"
    }

    private static func dayKey(_ namespace: String) -> String {
        "com.mmagtech.RommApp.\(namespace).tileArtDay.v\(schema)"
    }
}
