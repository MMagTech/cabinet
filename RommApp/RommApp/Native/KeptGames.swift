import Foundation

/// One game deliberately stored on this phone for offline, native play.
/// Not a cache entry: nothing evicts it, and it exists because someone
/// asked for it by name. The manifest carries what the Storage screen's
/// kept section and offline navigation both need without a server round
/// trip.
///
/// Embeds the whole `Rom` it was kept from, captured once at keep time,
/// rather than a hand-picked subset of fields. Offline navigation (a
/// kept game reached from Home with no connection) needs everything a
/// live library fetch would have given it, cover paths and platform
/// identifiers included, and re-deriving a partial, patched-together
/// `Rom` later would only invite the fields to drift apart.
struct KeptGame: Codable, Identifiable {
    let rom: Rom
    let totalBytes: Int64
    let keptAt: Date
    /// What feeding the web player's cache needs, captured at keep time
    /// because building the cache key and passing its validation both
    /// depend on values only the server can provide: RomM's player
    /// always requests `?file_ids={id}` even for a single-file game, and
    /// EmulatorJS trusts a cached entry only when its stored
    /// Content-Length string equals a live HEAD response's header
    /// exactly. Optional: manifests written before this existed lack
    /// them, and a kept game without them still plays natively and
    /// exports fine, the web player just downloads organically instead.
    let fileId: Int?
    let webFileName: String?
    let contentLength: String?
    /// The newest save state downloaded for this game, native only:
    /// states are core-build-specific and states belong to RomM's
    /// database, not its filesystem layout, so unlike the ROM and BIOS
    /// they stay internal, never linked into the Files mirror, in
    /// keeping with this app modeling itself on RomM's own library
    /// shape. Nil means either nothing has ever been saved for this
    /// game, or the platform has no native core to write a state for.
    let stateId: Int?
    let stateUpdatedAt: String?
    /// `rom.canonicalPlatformSlug(platformsVersions:)`, resolved once at
    /// keep time when a live session guarantees the server's slug mapping
    /// is in hand, and persisted so every later native-core lookup for
    /// this game (`offlinePlatforms`, search, sync) works with zero
    /// network, matching a kept game's whole point. Optional because
    /// manifests written before this field existed lack it: those fall
    /// back to the raw, unmapped `platformFsSlug` via `resolvedCanonicalSlug`
    /// below, self-healing to the real value the next time this game's
    /// launch screen runs `refreshCachedState` online.
    let canonicalPlatformSlug: String?
    /// True only for an entry rebuilt from an older manifest format
    /// that could no longer decode as-is: its `rom` is a best-effort
    /// stand-in, real platform data missing, until the next moment
    /// this app is online replaces it with the genuine thing.
    /// `Bool?` rather than a plain `Bool` so every manifest already on
    /// disk before this field existed keeps decoding without change,
    /// nil reads as false everywhere this is checked.
    let needsMetadataRefresh: Bool?

    var id: Int { rom.id }
    var romId: Int { rom.id }
    var displayName: String { rom.displayName }
    var fsName: String { rom.fsName }
    var platformFsSlug: String { rom.platformFsSlug }

    /// The slug every offline-safe native-core lookup for this game
    /// should use. Falls back to the raw, unmapped folder slug for a
    /// manifest predating `canonicalPlatformSlug`, which is exactly what
    /// `Rom.canonicalPlatformSlug` itself falls back to for a platform
    /// with no server-side mapping, so this is never worse than the
    /// existing accepted fallback, only possibly stale until the next
    /// online refresh corrects it.
    var resolvedCanonicalSlug: String {
        canonicalPlatformSlug ?? rom.platformFsSlug.lowercased()
    }
}

/// Permanent on-device storage for kept games: the ROM plus every
/// firmware file its platform serves, one directory per rom id under
/// Application Support, each with a small manifest describing itself.
///
/// The whole tree is excluded from iOS backup. RomM is the source of
/// truth and every kept file is re-downloadable from it, so backing them
/// up would bloat iCloud backups to protect data that is not at risk.
/// Confirmed with Marcus 2026-08-07, no user-facing setting.
@MainActor
final class KeptGameStore: ObservableObject {
    static let shared = KeptGameStore()

    struct DownloadProgress: Equatable {
        var fraction: Double
        var receivedBytes: Int64
        var totalBytes: Int64
    }

    @Published private(set) var games: [KeptGame] = []
    @Published private(set) var downloading: [Int: DownloadProgress] = [:]
    @Published private(set) var errors: [Int: String] = [:]

    /// A whole platform being kept, one game after another. `keep`
    /// starts a task per game, which is right for a person tapping
    /// three toggles and wrong for a hundred and forty: this walks a
    /// list and awaits each download in turn, through the same
    /// performKeep, so the per-cover ring, the error text and the
    /// Downloaded count all behave exactly as they do for one. Cancel
    /// stops after the current file and keeps what finished. One at a
    /// time in the whole app; a second request while one runs is
    /// ignored rather than queued behind it.
    struct BulkDownload: Equatable {
        let platformId: Int
        var done: Int
        var total: Int
        var currentRomId: Int?
        var failed: Int
    }

    @Published private(set) var bulk: BulkDownload?
    private var bulkTask: Task<Void, Never>?

    func keepAll(_ roms: [Rom], platformId: Int, session: Session) {
        guard bulkTask == nil else { return }
        let queue = roms.filter { kept(romId: $0.id) == nil && tasks[$0.id] == nil }
        guard !queue.isEmpty else { return }
        bulk = BulkDownload(platformId: platformId, done: 0, total: queue.count, currentRomId: nil, failed: 0)
        bulkTask = Task { [weak self] in
            for rom in queue {
                guard let self, !Task.isCancelled else { break }
                self.errors[rom.id] = nil
                self.downloading[rom.id] = DownloadProgress(fraction: 0, receivedBytes: 0, totalBytes: rom.fsSizeBytes)
                self.bulk?.currentRomId = rom.id
                // The same shape `keep` gives a single download, so the
                // tasks table, cancel and the ring all see one of those.
                let task = Task<Void, Never> {
                    do {
                        try await self.performKeep(rom: rom, session: session)
                    } catch {
                        if !(error is CancellationError), !Task.isCancelled {
                            self.errors[rom.id] = "The download didn't finish. Turn Download on again to retry."
                            self.bulk?.failed += 1
                            DiagnosticsLog.record(
                                context: "Download all", message: "\(rom.displayName): \(error.localizedDescription)",
                                romVersion: session.serverVersion
                            )
                        }
                    }
                }
                self.tasks[rom.id] = task
                await task.value
                self.downloading[rom.id] = nil
                self.tasks[rom.id] = nil
                self.bulk?.done += 1
            }
            self?.bulk = nil
            self?.bulkTask = nil
        }
    }

    /// The Finder folder this platform's kept games are mirrored into,
    /// or nil until something is kept there. For the Mac's Show in Finder.
    func mirrorRomsFolder(platformFsSlug: String) -> URL? {
        let slug = platformFsSlug.isEmpty ? "unknown" : platformFsSlug
        let folder = documentsRoot
            .appendingPathComponent(Self.safeComponent(slug), isDirectory: true)
            .appendingPathComponent("roms", isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// Every kept game on a platform. Remove All's counterpart to keepAll.
    func removeAll(platformId: Int) {
        for game in games where game.rom.platformId == platformId {
            remove(romId: game.romId)
        }
    }

    func cancelBulk() {
        if let current = bulk?.currentRomId {
            tasks[current]?.cancel()
        }
        bulkTask?.cancel()
    }

    /// Bytes free on the volume the kept games live on, by the measure
    /// the system uses for a download it considers important, which
    /// counts purgeable space as free. Nil when the volume will not say.
    func availableCapacity() -> Int64? {
        #if os(tvOS)
        // The "important usage" measure, which counts purgeable space as
        // free, does not exist on tvOS; the plain figure does.
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
        #else
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }

    private var tasks: [Int: Task<Void, Never>] = [:]
    private let root: URL
    /// The person-facing mirror in the Files app, laid out as RomM's
    /// system-folder-first library structure, the one Marcus's server
    /// uses (RomM supports two; assuming the other one blind was caught
    /// and corrected): <platform folder>/roms/<server filename> and
    /// <platform folder>/bios/<firmware filename>, platform folders
    /// appearing directly under the app's root in Files. This app is a
    /// frontend to RomM, so browsing kept files reads like browsing the
    /// server's library on a PC, same folders, same split, same names.
    /// Hard links, so same physical bytes as the store, zero extra
    /// space; the private store under Application Support stays
    /// canonical and unexposed, so the public shape never needs to
    /// change as later phases grow the private side. Exists because the
    /// file someone kept is theirs: copy it to another emulator,
    /// AirDrop it, whatever, without asking Export's permission per
    /// game.
    private let documentsRoot: URL
    private static let linksMigratedKey = "romm.keptGames.linksMigrated"
    /// The locally cached state's fixed filename inside a kept game's
    /// private directory. Fixed, not per-state-id, since only the
    /// newest state is ever kept locally and a refresh simply
    /// overwrites it.
    private static let stateFileName = "state.dat"
    /// Files inside a kept game's private directory that never become a
    /// Files app link: the manifest is bookkeeping, and the cached state
    /// stays internal per the platform-shape decision above.
    private static let internalOnly: Set<String> = ["manifest.json", stateFileName, pendingStatesDirName]

    var totalBytes: Int64 {
        games.reduce(0) { $0 + $1.totalBytes }
    }

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("KeptGames", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        #if targetEnvironment(macCatalyst)
        // The Mac build is unsandboxed, so .documentDirectory is the
        // person's real ~/Documents. iOS scatters platform folders at
        // the top of the app's own scoped Documents, which is right
        // there and rude here: on the Mac everything gathers under one
        // Cabinet folder, browsable in Finder like any library.
        documentsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cabinet", isDirectory: true)
        #else
        documentsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        // Two builds shipped the mirror under earlier names before the
        // layout settled; anything inside was only ever hard links, so
        // deleting them loses no bytes. Platform folders are created
        // lazily at link time, so an empty library shows an empty root,
        // the same as browsing an empty server.
        try? fm.removeItem(at: documentsRoot.appendingPathComponent("Kept Games", isDirectory: true))
        try? fm.removeItem(at: documentsRoot.appendingPathComponent("Games", isDirectory: true))
        games = Self.loadManifests(in: root)
        reconcileFilesFolder()
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    func kept(romId: Int) -> KeptGame? {
        games.first { $0.romId == romId }
    }

    /// Kept, native-capable games grouped by platform: the one shape
    /// Offline Mode uses for browsing everywhere it appears, Home and
    /// the library both, so the two can never draw a different picture
    /// of the same underlying data (Marcus, 2026-08-07: Home's offline
    /// view "should essentially just be what the current library looks
    /// like"). Webview-only kept games are excluded, the rule used
    /// everywhere else tonight: their player still needs the server, so
    /// listing them would set up a tap that fails regardless of what is
    /// actually stored. A `Platform` built straight from the kept rom's
    /// own embedded fields, not fetched: the count is how many are
    /// kept, not the server's full catalog size, which would mean
    /// nothing without a connection to trust it.
    func offlinePlatforms() -> [(platform: Platform, roms: [Rom])] {
        let kept = games
            .filter { NativeCore.core(bySlug: $0.resolvedCanonicalSlug, isArcade: $0.rom.isArcade) != nil }
            .map(\.rom)
        return Dictionary(grouping: kept, by: \.platformId)
            .map { platformId, roms in
                let sample = roms[0]
                let platform = Platform(
                    id: platformId, name: sample.platformDisplayName, displayName: sample.platformDisplayName,
                    slug: sample.platformSlug, fsSlug: sample.platformFsSlug, romCount: roms.count
                )
                let sorted = roms.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                }
                return (platform, sorted)
            }
            .sorted { $0.platform.slug.localizedCaseInsensitiveCompare($1.platform.slug) == .orderedAscending }
    }

    /// Whether a game can be kept at all: the same gate
    /// `GameLaunchView`'s Storage card uses to decide whether its
    /// toggle appears, extracted here so the long-press context menu
    /// offers exactly the same games and the two can never drift apart.
    /// Native-capable games mirror `NativeLauncher.prepare`'s own gates
    /// (a Saturn game that is not a single-file chd gets nothing rather
    /// than a kept copy nothing can boot); everything else needs only
    /// to be a single file, matching the cache's one-entry-per-file
    /// schema.
    static func isKeepable(_ rom: Rom, canonicalSlug: String) -> Bool {
        if let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) {
            if core == .beetleSaturn {
                return !rom.hasMultipleFiles && rom.fsName.lowercased().hasSuffix(".chd")
            }
            return true
        }
        return !rom.hasMultipleFiles
    }

    /// The directory the native launcher can boot straight from, or nil
    /// when the game is not kept or its ROM file has gone missing under
    /// us, in which case launching falls back to a normal download rather
    /// than failing on a promise the disk no longer keeps.
    func launchDirectory(romId: Int) -> URL? {
        guard let game = kept(romId: romId) else { return nil }
        let dir = directory(for: romId)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(game.fsName).path) else {
            return nil
        }
        return dir
    }

    /// A file inside a kept game's directory, or nil when the game is not
    /// kept or that file is not part of it. Lets Export hand Files bytes
    /// already on this phone instead of downloading them a second time.
    func fileURL(romId: Int, fileName: String) -> URL? {
        guard kept(romId: romId) != nil else { return nil }
        let url = directory(for: romId).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The newest state downloaded for this kept game, read straight off
    /// disk: no network, whether asked offline or simply to skip a round
    /// trip online for the one state Keep already has. Nil when nothing
    /// has ever been cached, the ordinary case for a game never saved.
    func localState(for romId: Int) -> (stateId: Int, updatedAt: String?, data: Data)? {
        guard let game = kept(romId: romId), let stateId = game.stateId else { return nil }
        let url = directory(for: romId).appendingPathComponent(Self.stateFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (stateId, game.stateUpdatedAt, data)
    }

    /// Keeps a kept game's local state current for free, whenever the
    /// app already has a live states list in hand from an ordinary
    /// online visit to this game's launch screen. Nothing waits on
    /// this: it only means the next time this game plays with no
    /// connection, Resume reflects whatever was newest the last time
    /// Cabinet had a chance to look, not whatever was newest back when
    /// it was first kept.
    func refreshCachedState(rom: Rom, liveStates: [GameState], session: Session) {
        let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        guard let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug), let game = kept(romId: rom.id) else { return }
        let newest = liveStates
            .filter { $0.emulator == core.emulatorTag }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            .first
        guard let newest, newest.id != game.stateId else { return }
        Task { [weak self] in
            guard let self, let bytes = try? await session.stateContent(newest) else { return }
            guard let index = self.games.firstIndex(where: { $0.romId == rom.id }) else { return }
            let dir = self.directory(for: rom.id)
            guard (try? bytes.write(to: dir.appendingPathComponent(Self.stateFileName))) != nil else { return }
            let old = self.games[index]
            let updated = KeptGame(
                rom: old.rom, totalBytes: Self.directorySize(dir), keptAt: old.keptAt,
                fileId: old.fileId, webFileName: old.webFileName, contentLength: old.contentLength,
                stateId: newest.id, stateUpdatedAt: newest.updatedAt,
                canonicalPlatformSlug: old.rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions),
                needsMetadataRefresh: old.needsMetadataRefresh
            )
            self.games[index] = updated
            if let manifestData = try? JSONEncoder().encode(updated) {
                try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))
            }
        }
    }

    /// Save states made for a kept game that have not yet reached RomM,
    /// never linked into the Files mirror, same reasoning as the single
    /// cached state: core-format-specific, no use to another app. The
    /// directory itself is the queue, no separate manifest to keep in
    /// sync: a file existing here means it still owes an upload, its
    /// absence means the upload already succeeded. Append-only by
    /// construction, each file already carries the same timestamped
    /// name RomM itself would give it, so nothing here ever overwrites
    /// anything, sync is only ever "finish the uploads."
    private static let pendingStatesDirName = "pending-states"

    private func pendingStatesDirectory(for romId: Int) -> URL {
        directory(for: romId).appendingPathComponent(Self.pendingStatesDirName, isDirectory: true)
    }

    /// Every save still owed to RomM for this kept game, newest first.
    func pendingStates(for romId: Int) -> [(stem: String, stateURL: URL, screenshotURL: URL?, savedAt: Date)] {
        let dir = pendingStatesDirectory(for: romId)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "state" }
            .map { url -> (stem: String, stateURL: URL, screenshotURL: URL?, savedAt: Date) in
                let stem = url.deletingPathExtension().lastPathComponent
                let screenshot = dir.appendingPathComponent("\(stem).png")
                let savedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date.distantPast
                return (
                    stem, url,
                    FileManager.default.fileExists(atPath: screenshot.path) ? screenshot : nil, savedAt
                )
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func pendingStateCount(for romId: Int) -> Int {
        pendingStates(for: romId).count
    }

    /// Whichever save is genuinely newest for this game, the downloaded
    /// resume state or a still-queued local one, whichever has the
    /// later file date: what "Load latest state" and the launch
    /// screen's Resume-from list both mean by "latest" once nothing can
    /// be asked live.
    func newestLocalState(for romId: Int) -> Data? {
        let cachedURL = directory(for: romId).appendingPathComponent(Self.stateFileName)
        let cachedDate = try? cachedURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let newestPending = pendingStates(for: romId).first,
           cachedDate == nil || newestPending.savedAt > cachedDate! {
            return try? Data(contentsOf: newestPending.stateURL)
        }
        return try? Data(contentsOf: cachedURL)
    }

    /// Writes a save straight to local storage before any attempt to
    /// reach the server: the one guarantee this queue exists to make,
    /// losing signal mid-save must never mean losing the save.
    @discardableResult
    func queuePendingState(romId: Int, stem: String, stateData: Data, screenshotData: Data?) -> Bool {
        let dir = pendingStatesDirectory(for: romId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? stateData.write(to: dir.appendingPathComponent("\(stem).state"))) != nil else { return false }
        if let screenshotData {
            try? screenshotData.write(to: dir.appendingPathComponent("\(stem).png"))
        }
        touchTotalBytes(romId: romId)
        return true
    }

    /// Attempts every queued save across every kept game, each upload
    /// using the file's own already-timestamped name so RomM's list
    /// catches up exactly as if the save had happened online. A file
    /// that uploads successfully leaves the queue; one that fails stays,
    /// tried again next time this runs. Safe to call often and
    /// opportunistically: nothing here can duplicate an upload or lose a
    /// file, only remove one once RomM has confirmed it.
    /// Returns how many saves actually uploaded this pass, for the in-app
    /// confirmation Home shows; a no-op pass returns 0 and shows nothing.
    @discardableResult
    func syncPendingStates(session: Session) async -> Int {
        var uploaded = 0
        for game in games {
            guard let core = NativeCore.core(bySlug: game.resolvedCanonicalSlug, isArcade: game.rom.isArcade) else { continue }
            for pending in pendingStates(for: game.romId) {
                guard let stateData = try? Data(contentsOf: pending.stateURL) else { continue }
                let screenshotData = pending.screenshotURL.flatMap { try? Data(contentsOf: $0) }
                do {
                    try await session.uploadState(
                        romId: game.romId, emulator: core.emulatorTag,
                        fileName: pending.stateURL.lastPathComponent,
                        stateData: stateData,
                        screenshotName: pending.screenshotURL?.lastPathComponent,
                        screenshotData: screenshotData
                    )
                    try? FileManager.default.removeItem(at: pending.stateURL)
                    if let screenshotURL = pending.screenshotURL {
                        try? FileManager.default.removeItem(at: screenshotURL)
                    }
                    touchTotalBytes(romId: game.romId)
                    uploaded += 1
                } catch {
                    // Left queued on purpose; the next opportunity, a
                    // connection returning anywhere in the app or simply
                    // revisiting this game, tries it again.
                }
            }
        }
        return uploaded
    }

    /// Replaces a migrated entry's stand-in `Rom` with the real thing,
    /// for every kept game still flagged `needsMetadataRefresh`. The
    /// files on disk never needed this to be safe, they were never at
    /// risk; this is purely about a stub entry stopping looking like
    /// one, real cover art, exact platform data, the moment there is a
    /// connection to ask for it. A rom that fails to fetch (deleted
    /// from the server, momentarily unreachable) stays flagged and
    /// tries again next opportunity, the same tolerant shape as
    /// `syncPendingStates`.
    /// Recomputes and persists `canonicalPlatformSlug` for every kept
    /// game, not only ones missing it. No network round trip: `game.rom`
    /// is already the real thing, this only needs `session.platformsVersions`
    /// (already in memory once logged in), so it is cheap enough to run
    /// unconditionally on every foreground and connectivity change,
    /// matching where it is called from.
    ///
    /// Unconditional on purpose, not gated on `canonicalPlatformSlug ==
    /// nil` the way a first cut of this method had it. `performKeep`
    /// computes and permanently stores this slug at keep time, and
    /// `platformsVersions` is fetched asynchronously; a keep that
    /// happened to run before that fetch resolved got the empty-mapping
    /// fallback, the raw unmapped folder name, written to disk as a
    /// real, non-nil value, not a blank one. Found 2026-08-08: a real
    /// device's GBA folder is literally "Game Boy Advance", RomM's own
    /// display name rather than a slug, and with no mapping entry yet in
    /// hand that lowercased straight through to "game boy advance",
    /// matching nothing. A nil-only guard would never have corrected an
    /// already-wrong value, only ever filled in a blank one.
    func healCanonicalSlugs(session: Session) {
        guard !session.platformsVersions.isEmpty else { return }
        for game in games where game.needsMetadataRefresh != true {
            guard let index = games.firstIndex(where: { $0.romId == game.romId }) else { continue }
            let dir = directory(for: game.romId)
            let updated = KeptGame(
                rom: game.rom, totalBytes: game.totalBytes, keptAt: game.keptAt,
                fileId: game.fileId, webFileName: game.webFileName, contentLength: game.contentLength,
                stateId: game.stateId, stateUpdatedAt: game.stateUpdatedAt,
                canonicalPlatformSlug: game.rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions),
                needsMetadataRefresh: game.needsMetadataRefresh
            )
            games[index] = updated
            if let manifestData = try? JSONEncoder().encode(updated) {
                try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))
            }
        }
    }

    func refreshStaleMetadata(session: Session) async {
        for game in games where game.needsMetadataRefresh == true {
            guard let freshRom = try? await session.rom(id: game.romId) else { continue }
            guard let index = games.firstIndex(where: { $0.romId == game.romId }) else { continue }
            let dir = directory(for: game.romId)
            let old = games[index]
            let updated = KeptGame(
                rom: freshRom, totalBytes: old.totalBytes, keptAt: old.keptAt,
                fileId: old.fileId, webFileName: old.webFileName, contentLength: old.contentLength,
                stateId: old.stateId, stateUpdatedAt: old.stateUpdatedAt,
                canonicalPlatformSlug: freshRom.canonicalPlatformSlug(platformsVersions: session.platformsVersions),
                needsMetadataRefresh: nil
            )
            games[index] = updated
            if let manifestData = try? JSONEncoder().encode(updated) {
                try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))
            }
        }
    }

    /// Recomputes and persists a kept game's stored size after a queue
    /// write or upload changes what is actually on disk, so Storage
    /// stays honest about what a kept game costs rather than reporting
    /// whatever it measured back when it was first kept.
    private func touchTotalBytes(romId: Int) {
        guard let index = games.firstIndex(where: { $0.romId == romId }) else { return }
        let dir = directory(for: romId)
        let old = games[index]
        let updated = KeptGame(
            rom: old.rom, totalBytes: Self.directorySize(dir), keptAt: old.keptAt,
            fileId: old.fileId, webFileName: old.webFileName, contentLength: old.contentLength,
            stateId: old.stateId, stateUpdatedAt: old.stateUpdatedAt,
            canonicalPlatformSlug: old.canonicalPlatformSlug,
            needsMetadataRefresh: old.needsMetadataRefresh
        )
        games[index] = updated
        if let manifestData = try? JSONEncoder().encode(updated) {
            try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))
        }
    }

    /// Downloads the ROM and its platform's firmware into permanent
    /// storage. Strict about firmware where the launcher's own temp path
    /// is tolerant: a launch with a missing BIOS fails visibly right now,
    /// but a kept game with a missing BIOS fails weeks later in airplane
    /// mode, so every file the server claims to have must actually land
    /// or the keep fails as a whole.
    func keep(rom: Rom, session: Session) {
        guard tasks[rom.id] == nil, kept(romId: rom.id) == nil else { return }
        errors[rom.id] = nil
        downloading[rom.id] = DownloadProgress(fraction: 0, receivedBytes: 0, totalBytes: rom.fsSizeBytes)

        let task = Task { [weak self] in
            do {
                try await self?.performKeep(rom: rom, session: session)
            } catch {
                // Deliberate cancellation is judged by the task, not the
                // error: tearing down a mid-transfer connection surfaces
                // as whatever the network stack was feeling, "connection
                // lost" included, not reliably as the cancel code. If the
                // person toggled this off, no message is owed regardless
                // of which error the teardown produced.
                if !(error is CancellationError), !Task.isCancelled {
                    // The person sees the remedy, not the diagnosis: the
                    // raw system text ("The network connection was
                    // lost.") reads as a scolding and names no next
                    // step, while the retry is the very toggle this
                    // caption sits under. The real error still goes to
                    // diagnostics for debugging.
                    self?.errors[rom.id] = "The download didn't finish. Turn Download on again to retry."
                    DiagnosticsLog.record(
                        context: "Download for offline", message: error.localizedDescription,
                        romVersion: session.serverVersion
                    )
                }
            }
            self?.downloading[rom.id] = nil
            self?.tasks[rom.id] = nil
        }
        tasks[rom.id] = task
    }

    /// Removes a kept game, or cancels its in-flight download. One method
    /// on purpose: the toggle that added the game is the same control
    /// either way.
    func remove(romId: Int) {
        tasks[romId]?.cancel()
        errors[romId] = nil
        if let game = kept(romId: romId) {
            removeLinks(for: game)
        }
        try? FileManager.default.removeItem(at: directory(for: romId))
        try? FileManager.default.removeItem(at: stagingDirectory(for: romId))
        games.removeAll { $0.romId == romId }
    }

    // MARK: Files app mirror

    /// The inode, the identity that survives however many names a hard
    /// link gives a file, and however the person renames it in Files.
    private func inode(of url: URL) -> UInt64? {
        guard let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? NSNumber
        else { return nil }
        return number.uint64Value
    }

    private func storeFileURL(for game: KeptGame) -> URL {
        directory(for: game.romId).appendingPathComponent(game.fsName)
    }

    /// Every file anywhere under Documents, by inode: renames and moves
    /// between folders both leave the inode alone, so a kept game is
    /// recognized wherever the person dragged it. Foreign files someone
    /// dropped in are carried here too and simply never match a kept
    /// game, which is exactly the right amount of attention to pay
    /// them: none.
    private func filesFolderInodes() -> [UInt64: URL] {
        // Hidden entries skipped deliberately: deleting a file in the
        // Files app moves it into a hidden .Trash still inside
        // Documents, and counting trashed files as present made
        // deletion invisible to reconciliation, the toggle stayed on
        // after the person had thrown the game away.
        guard let enumerator = FileManager.default.enumerator(
            at: documentsRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var map: [UInt64: URL] = [:]
        for case let entry as URL in enumerator {
            guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if let id = inode(of: entry) { map[id] = entry }
        }
        return map
    }

    /// Files-app-hostile characters swapped, not stripped. Server names
    /// are already filesystem names so this is nearly always a no-op;
    /// the colon is the exception, legal on a Linux server and reserved
    /// on Apple filesystems.
    private static func safeComponent(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// <platform folder>/roms or <platform folder>/bios, the
    /// system-folder-first structure Marcus's server uses. No collision
    /// handling because the server's directories already guarantee
    /// uniqueness within a platform; a manifest from before the slug
    /// field existed lands under "unknown".
    private func mirrorFolder(for game: KeptGame, kind: String) -> URL {
        let slug = game.platformFsSlug.isEmpty ? "unknown" : game.platformFsSlug
        return documentsRoot
            .appendingPathComponent(Self.safeComponent(slug), isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)
    }

    /// Every file a kept game brought down, the ROM into its platform's
    /// roms folder, firmware into its bios folder, the same shelving the
    /// server itself uses. Firmware included on purpose: the BIOS is the
    /// file another emulator needs alongside the game, and carrying it
    /// here is what lets playable games have no export button at all.
    /// Idempotent, called at keep time and every reconcile: files are
    /// matched by inode so renames don't spawn duplicates, and a
    /// firmware name already present is left alone, whichever kept game
    /// originally provided it.
    private func ensureLinks(for game: KeptGame) {
        guard let storeFiles = try? FileManager.default.contentsOfDirectory(
            at: directory(for: game.romId), includingPropertiesForKeys: nil
        ) else { return }
        let existing = filesFolderInodes()
        for file in storeFiles where !Self.internalOnly.contains(file.lastPathComponent) {
            guard let fileInode = inode(of: file), existing[fileInode] == nil else { continue }
            let isROM = file.lastPathComponent == game.fsName
            let folder = mirrorFolder(for: game, kind: isROM ? "roms" : "bios")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(Self.safeComponent(file.lastPathComponent))
            // A file already sitting at this exact path, whose inode is
            // not the one we are about to link (confirmed above, this
            // file's inode matched nothing currently tracked), is debris
            // from an earlier incarnation of this same kept game, most
            // likely a manifest that stopped decoding after a past
            // structural change and left its Files copy behind with
            // nothing tracking it any more. Removed, not skipped: found
            // on device (Marcus, 2026-08-08) silently declining to link
            // here left a legitimately re-kept game permanently invisible
            // in Files, since nothing else ever revisits an occupied
            // path once this loop moves past it.
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try? FileManager.default.linkItem(at: file, to: target)
            Self.excludeFromBackup(target)
        }
    }

    private func removeLinks(for game: KeptGame) {
        // Firmware stays while any other kept game on the platform still
        // wants it; the last one out takes it along.
        let platformStillKept = games.contains {
            $0.romId != game.romId && $0.platformFsSlug == game.platformFsSlug
        }
        guard let storeFiles = try? FileManager.default.contentsOfDirectory(
            at: directory(for: game.romId), includingPropertiesForKeys: nil
        ) else { return }
        let folder = filesFolderInodes()
        for file in storeFiles where file.lastPathComponent != "manifest.json" {
            let isROM = file.lastPathComponent == game.fsName
            if !isROM && platformStillKept { continue }
            guard let fileInode = inode(of: file), let link = folder[fileInode] else { continue }
            try? FileManager.default.removeItem(at: link)
            // Folders that just emptied out go too, the roms or bios
            // level first, then the platform folder itself once both
            // sides are gone, so the mirror never accumulates husks.
            var parent = link.deletingLastPathComponent()
            while parent != documentsRoot,
                  let remaining = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
                  remaining.isEmpty {
                try? FileManager.default.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
    }

    /// Makes the visible folder and the store agree, in the direction
    /// the person's actions point. A kept game with no entry in the
    /// folder means they deleted it in Files, and deleting the file is
    /// removing the game: the store copy goes too, rather than lingering
    /// as invisible storage the folder claims is gone. Renames don't
    /// count as deletion, the inode survives them. The one exception is
    /// the first run after this mirror shipped, when pre-mirror kept
    /// games legitimately have no link yet and get one created instead.
    /// Runs at init, and again whenever a screen that shows kept state
    /// appears, since Files edits can happen any time this app is not
    /// looking.
    func reconcileFilesFolder() {
        let migrated = UserDefaults.standard.bool(forKey: Self.linksMigratedKey)
        let folder = filesFolderInodes()
        for game in games {
            guard let storeInode = inode(of: storeFileURL(for: game)) else {
                // The store file itself is gone; nothing left to honor.
                remove(romId: game.romId)
                continue
            }
            // A game kept moments ago cannot have been deleted in Files
            // yet, no matter how this check is answered: a person cannot
            // act faster than the download that just finished. Found on
            // device (Marcus, 2026-08-07): opening a game right after
            // keeping it from the long-press menu could read this check
            // before it was ready to answer, and un-kept a game that had
            // never been touched in Files at all. The grace period
            // removes the failure mode outright rather than chasing its
            // exact cause; a real deletion is never this fresh.
            let justKept = Date().timeIntervalSince(game.keptAt) < 30
            if folder[storeInode] == nil, migrated, !justKept {
                DiagnosticsLog.record(
                    context: "Kept games", message: "Un-kept \(game.displayName) (rom \(game.romId)): its file wasn't found in the Files mirror.",
                    romVersion: nil
                )
                remove(romId: game.romId)
            }
        }
        // Whoever survived gets any missing links restored, firmware
        // included: only deleting the ROM itself reads as intent, a
        // deleted BIOS file is platform infrastructure and comes back.
        for game in games {
            ensureLinks(for: game)
        }
        UserDefaults.standard.set(true, forKey: Self.linksMigratedKey)
    }

    // MARK: Internals

    private func directory(for romId: Int) -> URL {
        root.appendingPathComponent(String(romId), isDirectory: true)
    }

    private func stagingDirectory(for romId: Int) -> URL {
        root.appendingPathComponent("\(romId).partial", isDirectory: true)
    }

    private func performKeep(rom: Rom, session: Session) async throws {
        // No-op once already populated; a real retry otherwise, so the
        // slug this keep permanently stores is computed against a real
        // mapping rather than the empty-fallback race healCanonicalSlugs
        // exists to correct after the fact.
        await session.loadPlatformConfigIfNeeded()
        let staging = stagingDirectory(for: rom.id)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            let romRequest = try await session.romContentRequest(rom)
            let contentLength = try await FileDownloader.download(
                romRequest, to: staging.appendingPathComponent(rom.fsName)
            ) { [weak self] received, total in
                let expected = total > 0 ? total : rom.fsSizeBytes
                self?.downloading[rom.id] = DownloadProgress(
                    fraction: expected > 0 ? Double(received) / Double(expected) : 0,
                    receivedBytes: received, totalBytes: expected
                )
            }

            var firmwareURLs: [URL] = []
            let firmwareList = try await session.firmware(platformId: rom.platformId)
            for firmware in firmwareList where !firmware.missingFromFS {
                let url = staging.appendingPathComponent(firmware.fileName)
                _ = try await FileDownloader.download(session.firmwareContentRequest(firmware), to: url, onProgress: nil)
                firmwareURLs.append(url)
            }
            let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
            if let platform = NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) {
                NativeLauncher.stageFirmware(from: firmwareURLs, in: staging, platform: platform)
            }

            // Tolerated on failure, unlike everything above: without a
            // file id the kept game merely cannot pre-fill the web
            // player's cache, which the web player recovers from by
            // downloading once, organically.
            let webFile = try? await session.romFiles(romId: rom.id).first

            // The newest state, so a kept game can resume real progress
            // with zero network rather than only booting fresh. Native
            // only, and entirely tolerant of failure: a game that has
            // never been saved has nothing to cache here, which is the
            // ordinary case, not an error.
            var cachedStateId: Int?
            var cachedStateUpdatedAt: String?
            if let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug),
               let liveStates = try? await session.states(romId: rom.id) {
                let newest = liveStates
                    .filter { $0.emulator == core.emulatorTag }
                    .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                    .first
                if let newest, let bytes = try? await session.stateContent(newest) {
                    try? bytes.write(to: staging.appendingPathComponent(Self.stateFileName))
                    cachedStateId = newest.id
                    cachedStateUpdatedAt = newest.updatedAt
                }
            }

            // The newest in-game save comes down at keep time too, into
            // the same local store the launch sync reads, so a game kept
            // and taken straight offline has its progress with it even
            // when that progress was made on another device or in the
            // web player. Tolerant of failure like the state cache
            // above: the launch sync re-checks whenever it can reach the
            // server anyway, this only makes sure offline is not empty.
            if let platform = NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) {
                await MemoryCardStore.shared.prefetchFromServer(rom: rom, platform: platform, session: session)
            }

            let manifest = KeptGame(
                rom: rom, totalBytes: Self.directorySize(staging), keptAt: Date(),
                fileId: webFile?.id, webFileName: webFile?.fileName, contentLength: contentLength,
                stateId: cachedStateId, stateUpdatedAt: cachedStateUpdatedAt,
                canonicalPlatformSlug: canonicalSlug, needsMetadataRefresh: nil
            )
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: staging.appendingPathComponent("manifest.json"))

            try Task.checkCancellation()
            let final = directory(for: rom.id)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: staging, to: final)
            games.append(manifest)
            games.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            ensureLinks(for: manifest)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// `KeptGame`'s shape before it embedded the whole `Rom`, kept only
    /// so a manifest written in that era still has somewhere to land.
    /// Never constructed by anything but `loadManifests`'s fallback.
    private struct LegacyKeptGameV1: Decodable {
        let romId: Int
        let displayName: String
        let fsName: String
        let totalBytes: Int64
        let keptAt: Date
        let fileId: Int?
        let webFileName: String?
        let contentLength: String?
        let platformFsSlug: String?
    }

    /// A stand-in `Rom` from whatever a legacy manifest actually knew.
    /// Good enough to show the game as kept, its size, and its ROM
    /// file's own name; not good enough to know its real platform,
    /// which `refreshStaleMetadata` corrects at the next connection.
    /// `platformSlug` borrows the folder name as a same-day guess where
    /// arcade and Saturn, the only two native platforms that existed
    /// when this legacy shape did, commonly share that name with their
    /// real IGDB slug; wrong only narrows a brief window before the
    /// real value replaces it, never loses a file.
    private static func stubRom(from legacy: LegacyKeptGameV1) -> Rom {
        let slugGuess = legacy.platformFsSlug ?? ""
        return Rom(
            id: legacy.romId, name: legacy.displayName, fsName: legacy.fsName,
            fsNameNoTags: legacy.displayName,
            fsNameNoExt: (legacy.fsName as NSString).deletingPathExtension,
            platformId: 0, platformSlug: slugGuess, platformFsSlug: slugGuess,
            platformDisplayName: nil, summary: nil, pathCoverSmall: nil, pathCoverLarge: nil,
            fsSizeBytes: legacy.totalBytes, hasMultipleFiles: false,
            md5Hash: nil
        )
    }

    /// Never deletes a real kept game just because its manifest no
    /// longer decodes: a `.partial` staging leftover is safe to clean
    /// up, it was never a finished keep, but a manifest that once
    /// described a real, completed download is preserved either as a
    /// direct decode, a migrated legacy one, or, failing both, left
    /// entirely alone on disk rather than destroyed. The failure that
    /// taught this (Marcus, 2026-08-07): a structural change to this
    /// exact struct wiped real kept games outright, their files
    /// surviving only by accident through an already-made Files link,
    /// which then caused a second, separate bug of its own.
    private static func loadManifests(in root: URL) -> [KeptGame] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        var migrated: [(entry: URL, game: KeptGame)] = []

        let games = entries.compactMap { entry -> KeptGame? in
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("manifest.json")) else {
                // A leftover ".partial" from a keep that died mid-move,
                // or anything else unrecognised: not a kept game, and
                // partials are re-created from scratch anyway.
                if entry.lastPathComponent.hasSuffix(".partial") {
                    try? FileManager.default.removeItem(at: entry)
                }
                return nil
            }
            if let game = try? decoder.decode(KeptGame.self, from: data) {
                return game
            }
            if let legacy = try? decoder.decode(LegacyKeptGameV1.self, from: data) {
                let game = KeptGame(
                    rom: stubRom(from: legacy), totalBytes: legacy.totalBytes, keptAt: legacy.keptAt,
                    fileId: legacy.fileId, webFileName: legacy.webFileName, contentLength: legacy.contentLength,
                    stateId: nil, stateUpdatedAt: nil,
                    canonicalPlatformSlug: nil, needsMetadataRefresh: true
                )
                migrated.append((entry, game))
                return game
            }
            // Genuinely unrecognised, neither the current shape nor the
            // one shape this app has ever migrated from: left alone on
            // disk. Invisible to this launch, exactly as safe as
            // deleting it and strictly more recoverable, since the
            // files are still there for a future, smarter migration or
            // a person's own inspection in Files to find.
            return nil
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        // Rewritten to the current shape immediately, not left to
        // re-migrate on every future launch until a connection happens
        // to arrive.
        for (entry, game) in migrated {
            if let data = try? JSONEncoder().encode(game) {
                try? data.write(to: entry.appendingPathComponent("manifest.json"))
            }
        }
        return games
    }

    /// Recursive, not a shallow listing: the pending-states queue lives
    /// in its own subdirectory, and a shallow count would silently
    /// undercount a kept game's real size the moment a save queued up
    /// inside it.
    private static func directorySize(_ dir: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

/// Streams one file to disk through a download task, with byte progress.
/// A download task rather than `URLSession.data`: a Saturn CHD runs to
/// hundreds of megabytes, and buffering that in memory next to a running
/// app invited exactly the pressure kills the native player exists to
/// avoid.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (@MainActor (Int64, Int64) -> Void)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    /// The raw Content-Length header from the response, exactly as sent:
    /// EmulatorJS validates cached entries by strict string comparison
    /// against a live HEAD response, so recomputing it from byte count
    /// is not the same thing.
    private var contentLengthHeader: String?

    private init(destination: URL, onProgress: (@MainActor (Int64, Int64) -> Void)?) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Returns the response's Content-Length header string, when present.
    @discardableResult
    static func download(
        _ request: URLRequest, to destination: URL,
        onProgress: (@MainActor (Int64, Int64) -> Void)?
    ) async throws -> String? {
        let downloader = FileDownloader(destination: destination, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                downloader.continuation = cont
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
        return downloader.contentLengthHeader
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let onProgress else { return }
        Task { @MainActor in
            onProgress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temp file only exists for the duration of this callback, so
        // the move happens here, synchronously, and any failure is carried
        // to didCompleteWithError which always fires after.
        contentLengthHeader = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length")
        if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode,
           !(200...299).contains(status) {
            moveError = NSError(
                domain: "KeptGames", code: status,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(status) for \(destination.lastPathComponent)"]
            )
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = continuation
        continuation = nil
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                cont?.resume(throwing: CancellationError())
            } else {
                cont?.resume(throwing: error)
            }
        } else if let moveError {
            cont?.resume(throwing: moveError)
        } else {
            cont?.resume()
        }
    }
}
