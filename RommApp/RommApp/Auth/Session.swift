import Foundation
import SwiftUI

/// Which screen the app should be showing, and the state behind it.
///
/// Nothing about any particular server is baked in. A fresh install knows no
/// address and no account, so everyone starts at the same place: type in your
/// own RomM address, then pair against it.
@MainActor
final class Session: ObservableObject {
    enum Stage: Equatable {
        /// No server address stored. Ask for one.
        case needsServer
        /// Server known, but this device is not paired with it.
        case needsPairing
        case ready
    }

    @Published private(set) var stage: Stage = .needsServer
    @Published private(set) var serverURL: URL?
    @Published private(set) var serverVersion: String?
    @Published private(set) var scopes: [String] = []
    /// An admin can rename any platform's folder to whatever they like, and
    /// RomM remembers the mapping from that folder name back to the short
    /// name EmulatorJS actually knows, admin editable at Settings > Platforms
    /// on the server. `/api/config` is where RomM's own page reads this, and
    /// it is the only place this app can learn it too: nothing about a
    /// platform's folder name can be assumed or bundled, it is chosen fresh
    /// on every install.
    @Published private(set) var platformsVersions: [String: String] = [:]
    /// Every platform's real name, by id, so a rom whose own display name
    /// is missing can borrow its platform's instead of falling straight to
    /// a slug. `/api/platforms` is fetched for this anyway to build the
    /// library's platform list, so this just keeps a second look up handy.
    @Published private(set) var platformNames: [Int: String] = [:]
    /// Ids of every rom in the favorite collection, kept in sync with every
    /// toggle so `isFavorite` never has to make a network call to answer.
    @Published private(set) var favoriteRomIds: Set<Int> = []
    /// The favorite collection itself, once found or created. Nil before
    /// the first load, or on a server nobody has favorited anything on yet.
    /// Published, not just private state, so Home's "Favorites" rail can
    /// link straight to it once it exists.
    @Published private(set) var favoriteCollection: Collection?

    private var client: RommClient?

    private let serverKey = "com.mmagtech.RommApp.serverURL"
    private let versionKey = "com.mmagtech.RommApp.serverVersion"

    init() {
        restore()
    }

    /// Swaps in a different account's server and token, and reloads as if
    /// the app had freshly launched against it.
    ///
    /// tvOS-only in practice: it exists for account switching there
    /// (`TVProfileStore`), which keeps every paired profile's own token in
    /// its own separate Keychain entry, and calls this to make one of them
    /// the active one. `Keychain.save(token:forHost:)` is the same public
    /// call pairing itself already makes; this does not change Keychain's
    /// format or how iOS reads it, and `serverKey`/`restore()` stay private
    /// to this class rather than duplicated as string literals in a second
    /// file. Nothing on iOS calls this today; iOS has no concept of
    /// switching which RomM account is active mid-session.
    func activateProfile(serverURL url: URL, token: String) throws {
        guard let host = url.host else {
            throw RommError.transport("That server address has no host.")
        }
        try Keychain.save(token: token, forHost: host)
        UserDefaults.standard.set(url.absoluteString, forKey: serverKey)
        restore()
    }

    // MARK: Restoring a previous pairing

    private func restore() {
        guard let stored = UserDefaults.standard.string(forKey: serverKey),
              let url = URL(string: stored)
        else { return }

        serverURL = url
        serverVersion = UserDefaults.standard.string(forKey: versionKey)

        guard let host = url.host, let token = Keychain.token(forHost: host) else {
            client = RommClient(baseURL: url)
            stage = .needsPairing
            return
        }

        client = RommClient(baseURL: url, accessToken: token)
        stage = .ready
        refreshPlatformConfig()
    }

    // MARK: Step one, the address

    /// Accepts what someone typed, works out a usable URL, and checks that a
    /// RomM instance actually answers there before moving on.
    func connect(toAddress raw: String) async throws {
        guard let url = Self.normalise(raw) else { throw RommError.transport(
            "That does not look like a web address. Try something like romm.example.com"
        ) }

        let candidate = RommClient(baseURL: url)
        let beat = try await candidate.heartbeat()

        client = candidate
        serverURL = url
        serverVersion = beat.system.version

        UserDefaults.standard.set(url.absoluteString, forKey: serverKey)
        UserDefaults.standard.set(beat.system.version, forKey: versionKey)

        // A token may already exist if this instance was paired before.
        if let host = url.host, let token = Keychain.token(forHost: host) {
            await candidate.setAccessToken(token)
            stage = .ready
            refreshPlatformConfig()
        } else {
            stage = .needsPairing
        }
    }

    /// People type "romm.example.com", or paste a URL with a trailing slash, or
    /// include a path. Normalise all of it, and assume https when no scheme is
    /// given so a typo does not silently send a token over plain http.
    static func normalise(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }

        guard let url = URL(string: text), let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }

        return url
    }

    // MARK: Step two, pairing

    func startPairing() async throws -> DeviceAuthInit {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.startDeviceAuth()
    }

    /// The full URL to open in a browser to approve this device.
    func approvalURL(for start: DeviceAuthInit) -> URL? {
        guard let serverURL else { return nil }
        return URL(string: serverURL.absoluteString + start.verificationPathComplete)
    }

    func completePairing(_ start: DeviceAuthInit) async throws {
        guard let client, let host = serverURL?.host else {
            throw RommError.transport("No server selected.")
        }

        let token = try await client.awaitDeviceApproval(start)
        try Keychain.save(token: token.accessToken, forHost: host)

        scopes = token.scopes
        stage = .ready
        refreshPlatformConfig()
    }

    /// Fire and forget: nothing blocks on this. A game screen opened before
    /// it lands just falls back to the platform's own folder name as its
    /// best guess, the same graceful fallback RomM's own page makes when it
    /// has no mapping either, and display screens fall back the same way
    /// down to whatever slug they already had.
    private func refreshPlatformConfig() {
        Task { [weak self] in
            guard let self, let client else { return }
            // A failure never overwrites a value that already worked.
            // Found on device (Marcus, 2026-08-07): this fetch runs once,
            // at launch, and its old fallback was an empty mapping on any
            // failure, network blip included. Empty means every platform
            // falls back to its raw folder name, and for any platform
            // whose folder name is not already cores.json's key, that
            // reads as no core at all, the whole library looking
            // Unsupported for the rest of the session with no retry. A
            // launch that starts genuinely offline still gets nothing
            // here, same as before, `loadPlatformConfigIfNeeded` below is
            // what recovers that case once there is a connection.
            if let versions = try? await client.platformsVersions() {
                self.platformsVersions = versions
            }
        }
        Task { [weak self] in
            guard let self, let client else { return }
            let platforms = (try? await client.platforms()) ?? []
            self.platformNames = Dictionary(
                uniqueKeysWithValues: platforms.compactMap { platform in
                    platform.displayName.map { (platform.id, $0) }
                }
            )
        }
        Task { [weak self] in
            guard let self, let client else { return }
            let collections = (try? await client.collections()) ?? []
            guard let favorites = collections.first(where: { $0.isFavorite }) else { return }
            self.favoriteCollection = favorites
            self.favoriteRomIds = Set(favorites.romIds)
        }
    }

    /// Retries the platform folder mapping if the app never managed to
    /// get one, the recovery path for a launch that started with no
    /// connection at all: `refreshPlatformConfig` only ever runs once,
    /// at launch, so without this a session that began offline would
    /// carry an empty mapping, and every platform whose folder name
    /// does not already equal its canonical slug, misread as
    /// Unsupported, for as long as the app stayed open. Called from the
    /// library screen's own load and pull-to-refresh, no new machinery
    /// needed: a no-op once a real mapping exists.
    func loadPlatformConfigIfNeeded() async {
        guard platformsVersions.isEmpty, let client else { return }
        if let versions = try? await client.platformsVersions() {
            platformsVersions = versions
        }
    }

    // MARK: Leaving

    /// Forgets the token but keeps the address, so pairing again is one step.
    func signOut() {
        if let host = serverURL?.host { Keychain.deleteToken(forHost: host) }
        scopes = []
        Task { await client?.setAccessToken(nil) }
        stage = .needsPairing
    }

    /// Forgets everything, back to a fresh install.
    func forgetServer() {
        if let host = serverURL?.host { Keychain.deleteToken(forHost: host) }
        UserDefaults.standard.removeObject(forKey: serverKey)
        UserDefaults.standard.removeObject(forKey: versionKey)
        client = nil
        serverURL = nil
        serverVersion = nil
        scopes = []
        stage = .needsServer
    }

    // MARK: Library calls

    func platforms() async throws -> [Platform] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.platforms()
    }

    func recentlyPlayed(limit: Int = 8, offset: Int = 0) async throws -> RomPage {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.recentlyPlayed(limit: limit, offset: offset)
    }

    func reportPlaying(romId: Int) async {
        await client?.reportPlaying(romId: romId)
    }

    @discardableResult
    func reportPlaySession(romId: Int, start: Date, end: Date) async -> Bool {
        await client?.reportPlaySession(romId: romId, start: start, end: end) ?? false
    }

    /// The in-flight end-of-session report, if any. The player fires its
    /// report the moment it closes and Home refetches recents the moment
    /// the launch screen closes; those two race, and when the fetch wins
    /// the game just played sorts under the one before it. Home awaits
    /// this before asking, which settles the race deterministically for
    /// every exit route in both players.
    private(set) var pendingPlayReport: Task<Void, Never>?

    /// Records a finished session as a task Home can wait on, rather than
    /// a fire-and-forget the recents fetch can outrun. Also queued to
    /// disk before the network is ever touched: found 2026-08-09 that a
    /// session ending offline (or racing a connection drop) used to just
    /// vanish, `RommClient.reportPlaySession` swallowed its own failure
    /// with `try?` and nothing remembered to retry, unlike saves, which
    /// already had a durable queue. Same fix, same shape: write first,
    /// clear the file only once RomM has actually confirmed it.
    func reportPlaySessionEnded(romId: Int, start: Date, end: Date) {
        let queuedURL = Self.queuePendingSession(romId: romId, start: start, end: end)
        pendingPlayReport = Task {
            let success = await reportPlaySession(romId: romId, start: start, end: end)
            if success, let queuedURL {
                try? FileManager.default.removeItem(at: queuedURL)
            }
        }
    }

    /// Blocks until any just-ended session has reached the server, then
    /// clears the marker. Returns immediately when nothing is pending.
    func waitForPendingPlayReport() async {
        await pendingPlayReport?.value
        pendingPlayReport = nil
    }

    // MARK: Offline play-session queue

    /// A flat directory of small per-session files, not nested under any
    /// particular kept game: unlike saves, a play-session report can fail
    /// for a rom that is not kept at all, it only needs to have started
    /// online and lost signal before ending. The directory itself is the
    /// queue, no separate manifest, same convention KeptGameStore's
    /// pending-states directory already uses.
    private static let pendingSessionsDir: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("PendingPlaySessions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private struct PendingSession: Codable {
        let romId: Int
        let start: Date
        let end: Date
    }

    /// Writes a session to disk before any attempt to reach the server,
    /// the same guarantee the save queue makes: losing signal around the
    /// report must never mean losing the record. Named for its own end
    /// time and rom, so nothing here ever overwrites anything real.
    @discardableResult
    private static func queuePendingSession(romId: Int, start: Date, end: Date) -> URL? {
        let stamp = Int(end.timeIntervalSince1970 * 1000)
        let url = pendingSessionsDir.appendingPathComponent("\(stamp)-\(romId).json")
        let pending = PendingSession(romId: romId, start: start, end: end)
        guard let data = try? JSONEncoder().encode(pending) else { return nil }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func pendingSessions() -> [(url: URL, session: PendingSession)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: pendingSessionsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (url: URL, session: PendingSession)? in
                guard let data = try? Data(contentsOf: url),
                      let pending = try? decoder.decode(PendingSession.self, from: data)
                else { return nil }
                return (url, pending)
            }
            .sorted { $0.session.end < $1.session.end }
    }

    /// Retries every queued play-session report, oldest first so history
    /// lands in the right order. Safe to call often and opportunistically:
    /// a report that succeeds leaves the queue, one that fails stays,
    /// tried again next time this runs. Returns how many actually went
    /// through, for the in-app confirmation Home shows.
    @discardableResult
    func syncPendingPlaySessions() async -> Int {
        var uploaded = 0
        for (url, pending) in Self.pendingSessions() {
            let success = await reportPlaySession(romId: pending.romId, start: pending.start, end: pending.end)
            if success {
                try? FileManager.default.removeItem(at: url)
                uploaded += 1
            }
        }
        return uploaded
    }

    /// Set only when a sync pass actually uploaded something, cleared by
    /// whoever shows it. Never shown for a no-op check, per the same
    /// "invisible when it applies to nothing" rule the Offline Mode
    /// toggle already follows.
    @Published var lastSyncSummary: String?

    func roms(
        platformId: Int? = nil,
        collectionId: Int? = nil,
        searchTerm: String? = nil,
        limit: Int = 60,
        offset: Int = 0,
        orderBy: String = "name",
        orderDir: String = "asc",
        matchedOnly: Bool = false
    ) async throws -> RomPage {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.roms(
            platformId: platformId, collectionId: collectionId,
            searchTerm: searchTerm, limit: limit, offset: offset,
            orderBy: orderBy, orderDir: orderDir, matchedOnly: matchedOnly
        )
    }

    func coverData(path: String) async throws -> Data {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.coverData(path: path)
    }

    // MARK: Collections

    /// Every collection this account owns, favorite one included, for the
    /// library's Collections tab. Not cached like `favoriteRomIds`: this is
    /// browsed on demand, not read on every launch screen.
    func collections() async throws -> [Collection] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.collections()
    }

    // MARK: Favorites

    func isFavorite(romId: Int) -> Bool {
        favoriteRomIds.contains(romId)
    }

    func favoriteRoms(limit: Int = 10) async throws -> [Rom] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.favoriteRoms(limit: limit)
    }

    /// Adds or removes a rom from the favorite collection, creating that
    /// collection the first time anyone on this server favorites anything.
    /// `favoriteRomIds` updates from the response rather than being guessed
    /// locally, so it always reflects what the server actually holds.
    func toggleFavorite(romId: Int) async throws {
        guard let client else { throw RommError.transport("No server selected.") }

        let collection: Collection
        if let favoriteCollection {
            collection = favoriteCollection
        } else {
            collection = try await client.createFavoriteCollection()
            self.favoriteCollection = collection
        }

        let updated = favoriteRomIds.contains(romId)
            ? try await client.removeRom(romId, fromCollection: collection.id)
            : try await client.addRom(romId, toCollection: collection.id)

        favoriteCollection = updated
        favoriteRomIds = Set(updated.romIds)
    }

    // MARK: Launch data

    func saves(romId: Int) async throws -> [GameSave] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.saves(romId: romId)
    }

    func states(romId: Int) async throws -> [GameState] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.states(romId: romId)
    }

    func stateContent(_ state: GameState) async throws -> Data {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.stateContent(state)
    }

    func saveContent(_ save: GameSave) async throws -> Data {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.saveContent(save)
    }

    func uploadSave(
        romId: Int,
        emulator: String,
        fileName: String,
        saveData: Data
    ) async throws {
        guard let client else { throw RommError.transport("No server selected.") }
        try await client.uploadSave(
            romId: romId, emulator: emulator, fileName: fileName, saveData: saveData
        )
    }

    func uploadState(
        romId: Int,
        emulator: String,
        fileName: String,
        stateData: Data,
        screenshotName: String? = nil,
        screenshotData: Data? = nil
    ) async throws {
        guard let client else { throw RommError.transport("No server selected.") }
        try await client.uploadState(
            romId: romId,
            emulator: emulator,
            fileName: fileName,
            stateData: stateData,
            screenshotName: screenshotName,
            screenshotData: screenshotData
        )
    }

    func screenshotData(path: String) async throws -> Data {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.screenshotData(path: path)
    }

    func deleteStates(ids: [Int]) async throws {
        guard let client else { throw RommError.transport("No server selected.") }
        try await client.deleteStates(ids: ids)
    }

    func deleteSaves(ids: [Int]) async throws {
        guard let client else { throw RommError.transport("No server selected.") }
        try await client.deleteSaves(ids: ids)
    }

    func firmware(platformId: Int) async throws -> [Firmware] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.firmware(platformId: platformId)
    }

    // MARK: Export

    func romContentRequest(_ rom: Rom) async throws -> URLRequest {
        guard let client else { throw RommError.transport("No server selected.") }
        return await client.fileRequest(path: "/api/roms/\(rom.id)/content/\(rom.fsName)")
    }

    func romFiles(romId: Int) async throws -> [RomFile] {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.romFiles(romId: romId)
    }

    func rom(id: Int) async throws -> Rom {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.rom(id: id)
    }

    func romFileContentRequest(romId: Int, file: RomFile) async throws -> URLRequest {
        guard let client else { throw RommError.transport("No server selected.") }
        return await client.fileRequest(path: "/api/roms/\(romId)/files/content/\(file.fileName)")
    }

    func firmwareContentRequest(_ firmware: Firmware) async throws -> URLRequest {
        guard let client else { throw RommError.transport("No server selected.") }
        return await client.fileRequest(path: "/api/firmware/\(firmware.id)/content/\(firmware.fileName)")
    }

    func cacheLimitBytes() async throws -> Int64? {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.cacheLimitBytes()
    }

    // MARK: Player

    /// Everything the player webview needs: where to go and how to prove who
    /// we are. The token is injected into the page's requests because RomM's
    /// backend accepts bearer authentication on every endpoint, while its web
    /// player normally rides on a session cookie this app does not have.
    func playerContext(for rom: Rom) async -> (url: URL, token: String)? {
        guard let serverURL, let host = serverURL.host,
              let token = Keychain.token(forHost: host),
              let url = URL(string: serverURL.absoluteString + "/rom/\(rom.id)/ejs")
        else { return nil }
        return (url, token)
    }
}
