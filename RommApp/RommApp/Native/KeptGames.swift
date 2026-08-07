import Foundation

/// One game deliberately stored on this phone for offline, native play.
/// Not a cache entry: nothing evicts it, and it exists because someone
/// asked for it by name. The manifest carries what the Cache screen's
/// kept section needs to show without a server round trip.
struct KeptGame: Codable, Identifiable {
    let romId: Int
    let displayName: String
    let fsName: String
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
    /// The platform's folder name on the server's filesystem, so the
    /// Files app mirror can reproduce RomM's own directory layout:
    /// Games/<platform folder>/<server filename>, the same structure
    /// someone browsing the server's roms directory on a PC sees.
    let platformFsSlug: String?

    var id: Int { romId }
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
    /// The person-facing mirror: "On My iPhone > Cabinet > Games" in the
    /// Files app, one hard link per kept game, laid out exactly as
    /// RomM's own library directory: Games/<platform folder>/<server
    /// filename>. This app is a frontend to RomM, so browsing kept files
    /// here reads like browsing the server's roms directory on a PC,
    /// same folders, same names, Marcus's call. Same physical bytes as
    /// the store, zero extra space; the private store under Application
    /// Support stays canonical and unexposed, so the public shape never
    /// needs to change as later phases grow the private side. Exists
    /// because the file someone kept is theirs: copy it to another
    /// emulator, AirDrop it, whatever, without asking Export's
    /// permission per game.
    private let filesFolder: URL
    private static let linksMigratedKey = "romm.keptGames.linksMigrated"

    var totalBytes: Int64 {
        games.reduce(0) { $0 + $1.totalBytes }
    }

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("KeptGames", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        Self.excludeFromBackup(root)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        filesFolder = documents.appendingPathComponent("Games", isDirectory: true)
        try? fm.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        Self.excludeFromBackup(filesFolder)
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
            } catch is CancellationError {
                // Cancelled by the person; the partial directory is
                // already gone and no message is owed.
            } catch {
                self?.errors[rom.id] = error.localizedDescription
                DiagnosticsLog.record(
                    context: "Keep on this phone", message: error.localizedDescription,
                    romVersion: session.serverVersion
                )
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

    /// Every file anywhere under the visible folder, by inode, platform
    /// subfolders included: renames and moves between subfolders both
    /// leave the inode alone, so a kept game is recognized wherever the
    /// person dragged it. Foreign files someone dropped in are carried
    /// here too and simply never match a kept game, which is exactly the
    /// right amount of attention to pay them: none.
    private func filesFolderInodes() -> [UInt64: URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: filesFolder, includingPropertiesForKeys: [.isRegularFileKey]
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

    private func platformFolder(for game: KeptGame) -> URL {
        // RomM's own layout: <platform folder>/<server filename>. No
        // collision handling because the server's directory already
        // guarantees uniqueness within a platform folder; a manifest
        // from before this field existed just lands at the root.
        guard let slug = game.platformFsSlug, !slug.isEmpty else { return filesFolder }
        return filesFolder.appendingPathComponent(Self.safeComponent(slug), isDirectory: true)
    }

    /// Every file a kept game brought down, ROM and firmware alike,
    /// linked into its platform folder. Firmware included on purpose:
    /// the BIOS is the file another emulator needs alongside the game,
    /// this is how the server's own library carries it, and putting it
    /// here is what lets playable games have no export button at all.
    /// Idempotent, called at keep time and every reconcile: the ROM is
    /// matched by inode so renames don't spawn duplicates, and a
    /// firmware name already present is left alone, whichever kept game
    /// originally provided it.
    private func ensureLinks(for game: KeptGame) {
        let folder = platformFolder(for: game)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = filesFolderInodes()

        guard let storeFiles = try? FileManager.default.contentsOfDirectory(
            at: directory(for: game.romId), includingPropertiesForKeys: nil
        ) else { return }
        for file in storeFiles where file.lastPathComponent != "manifest.json" {
            guard let fileInode = inode(of: file), existing[fileInode] == nil else { continue }
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
            // A platform folder that just emptied out goes too, so the
            // mirror never accumulates husks of removed platforms.
            let parent = link.deletingLastPathComponent()
            if parent != filesFolder,
               let remaining = try? FileManager.default.contentsOfDirectory(atPath: parent.path),
               remaining.isEmpty {
                try? FileManager.default.removeItem(at: parent)
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
            if folder[storeInode] == nil, migrated {
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

            let manifest = KeptGame(
                romId: rom.id, displayName: rom.displayName, fsName: rom.fsName,
                totalBytes: Self.directorySize(staging), keptAt: Date(),
                fileId: webFile?.id, webFileName: webFile?.fileName, contentLength: contentLength,
                platformFsSlug: rom.platformFsSlug
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
                return try? decoder.decode(KeptGame.self, from: data)
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
