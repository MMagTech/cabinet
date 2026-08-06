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
            self.platformsVersions = (try? await client.platformsVersions()) ?? [:]
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

    func reportPlaySession(romId: Int, start: Date, end: Date) async {
        await client?.reportPlaySession(romId: romId, start: start, end: end)
    }

    func roms(
        platformId: Int? = nil,
        collectionId: Int? = nil,
        searchTerm: String? = nil,
        limit: Int = 60,
        offset: Int = 0
    ) async throws -> RomPage {
        guard let client else { throw RommError.transport("No server selected.") }
        return try await client.roms(
            platformId: platformId, collectionId: collectionId,
            searchTerm: searchTerm, limit: limit, offset: offset
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
