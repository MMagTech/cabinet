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

    var id: Int { rom.id }
    var romId: Int { rom.id }
    var displayName: String { rom.displayName }
    var fsName: String { rom.fsName }
    var platformFsSlug: String { rom.platformFsSlug }
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
    private static let internalOnly: Set<String> = ["manifest.json", stateFileName]

    var totalBytes: Int64 {
        games.reduce(0) { $0 + $1.totalBytes }
    }

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("KeptGames", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        documentsRoot = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
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
            .filter { NativeCore.core(for: $0.rom) != nil }
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
    static func isKeepable(_ rom: Rom) -> Bool {
        if let core = NativeCore.core(for: rom) {
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
        guard let core = NativeCore.core(for: rom), let game = kept(romId: rom.id) else { return }
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
                stateId: newest.id, stateUpdatedAt: newest.updatedAt
            )
            self.games[index] = updated
            if let manifestData = try? JSONEncoder().encode(updated) {
                try? manifestData.write(to: dir.appendingPathComponent("manifest.json"))
            }
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
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
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
            if NativeCore.core(for: rom) == .beetleSaturn {
                NativeLauncher.stageSaturnBIOS(from: firmwareURLs, in: staging)
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
            if let core = NativeCore.core(for: rom),
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

            let manifest = KeptGame(
                rom: rom, totalBytes: Self.directorySize(staging), keptAt: Date(),
                fileId: webFile?.id, webFileName: webFile?.fileName, contentLength: contentLength,
                stateId: cachedStateId, stateUpdatedAt: cachedStateUpdatedAt
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

    private static func loadManifests(in root: URL) -> [KeptGame] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return entries
            .compactMap { entry -> KeptGame? in
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
                // A manifest that exists but no longer decodes is from
                // before `KeptGame` embedded the full `Rom` (this build's
                // structural change, not a format this app can migrate
                // in place, since the fields a Rom needs are not
                // reconstructable from the old flat manifest alone).
                // Wiped rather than left as untracked storage; re-keeping
                // is one tap.
                try? FileManager.default.removeItem(at: entry)
                return nil
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func directorySize(_ dir: URL) -> Int64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
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
