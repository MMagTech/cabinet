#if targetEnvironment(macCatalyst)
import Foundation

/// Games already fetched for a platform or a collection, kept for as
/// long as the window is open.
///
/// The sidebar gives every source its own view identity, because without
/// it switching platforms left the previous platform's games on screen:
/// `RomListView` loads from `.task`, which runs once per instance, and
/// changing only the value passed in does not make a new one. The price
/// of that identity is that coming back to a platform builds a fresh
/// view, and a fresh view fetches from scratch.
///
/// This pays that price once. A source you have already opened paints
/// immediately from what was fetched before, and the server is asked
/// only whether anything changed.
///
/// Memory only, and deliberately not expired on a timer: it lives as
/// long as the window, and the screens that change a library from
/// inside the app (a download, a favourite) publish through their own
/// stores rather than through this list's fetch.
@MainActor
final class MacRomListCache {
    static let shared = MacRomListCache()

    struct Entry {
        var roms: [Rom]
        var total: Int
    }

    private var entries: [String: Entry] = [:]

    func entry(for key: String) -> Entry? { entries[key] }

    func store(_ roms: [Rom], total: Int, for key: String) {
        entries[key] = Entry(roms: roms, total: total)
    }

    func drop(_ key: String) { entries[key] = nil }
}
#endif
