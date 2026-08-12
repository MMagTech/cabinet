import Foundation
import UIKit

/// Everything that talks to a RomM server.
///
/// An actor because the access token is mutable shared state and the pairing
/// poll runs concurrently with whatever the UI is doing.
///
/// URLSession and Codable only. No networking library, no generated client.
actor RommClient {
    private let baseURL: URL
    private let session: URLSession
    private var accessToken: String?

    var host: String { baseURL.host ?? baseURL.absoluteString }

    init(baseURL: URL, accessToken: String? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken

        let config = URLSessionConfiguration.default
        // Deliberately false. With it on, a request made with no signal
        // sits waiting for a connection that is not coming, so every
        // screen showed a spinner for the full timeout before admitting
        // anything was wrong. Failing immediately is what lets the UI say
        // "you're offline" and offer a retry while the person still has
        // the patience to use it.
        config.waitsForConnectivity = false
        // Fifteen, not thirty. This is the ceiling on how long someone
        // stares at a screen before being told anything is wrong, and no
        // list request here is slow enough to need more: a server that has
        // not answered a page of games in fifteen seconds is not about to.
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    func setAccessToken(_ token: String?) {
        accessToken = token
    }

    // MARK: Reachability

    /// Confirms an address is actually a RomM instance and reports its version.
    /// Needs no authentication, so it runs before pairing.
    func heartbeat() async throws -> Heartbeat {
        try await send(request(path: "/api/heartbeat"), decoding: Heartbeat.self)
    }

    // MARK: Device authorization

    /// Step one. Asks the server to start a pairing and hand back a short code
    /// for the person to approve in the RomM web UI.
    func startDeviceAuth() async throws -> DeviceAuthInit {
        var req = request(path: "/api/auth/device/init", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "client_device_identifier": Self.deviceIdentifier,
            "name": await UIDevice.current.name,
            "client": "romm-ios",
            "platform": "iOS",
            "client_version": Self.appVersion,
            "requested_scopes": RommScopes.required,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await send(req, decoding: DeviceAuthInit.self)
    }

    /// Step two. Polls until the person approves, denies, or the code expires.
    ///
    /// The server dictates the poll interval and can ask us to back off, so the
    /// delay is taken from its responses rather than hardcoded.
    func awaitDeviceApproval(_ start: DeviceAuthInit) async throws -> DeviceAuthToken {
        let deadline = Date().addingTimeInterval(TimeInterval(start.expiresIn))
        var interval = TimeInterval(max(start.interval, 1))

        while true {
            guard Date() < deadline else { throw RommError.pairingExpired }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            try Task.checkCancellation()

            var req = request(path: "/api/auth/device/token", method: "POST")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(
                withJSONObject: ["device_code": start.deviceCode]
            )

            do {
                let token = try await send(req, decoding: DeviceAuthToken.self)
                accessToken = token.accessToken
                return token
            } catch RommError.authorizationPending {
                continue
            } catch RommError.slowDown {
                interval += 5
                continue
            }
        }
    }

    /// tvOS account switching only, for right now: defaults a newly paired
    /// profile's label to whoever is actually signed in rather than the
    /// server address. `me.read` is already in `RommScopes.required`, so
    /// every token this app ever holds can already call this.
    func currentUser() async throws -> RommUser {
        try await send(request(path: "/api/users/me"), decoding: RommUser.self)
    }

    /// tvOS account switching only: the same account's avatar photo, so a
    /// profile can show the real picture instead of a generic person
    /// icon, confirmed live as a direct image response (not `avatar_path`,
    /// a relative path this same call's user object also carries but
    /// that a plain asset fetch cannot resolve the way `assetData` does
    /// for a cover's timestamped path).
    func avatarData(userId: Int) async throws -> Data {
        try await assetData(path: "/api/users/\(userId)/avatar")
    }

    // MARK: Library

    func platforms() async throws -> [Platform] {
        try await send(request(path: "/api/platforms"), decoding: [Platform].self)
    }

    /// Tells the server a game is being played, which is what puts it at
    /// the top of everything ordered by last played.
    ///
    /// RomM's own web player reports this over a socket, emitting an
    /// activity heartbeat while a game runs. That socket does not survive
    /// this app's webview, so nothing was ever recorded: a game played here
    /// never reached Home's own resume list, and never showed as played in
    /// RomM's web UI either, which is how the gap was noticed.
    ///
    /// This is the endpoint RomM publishes for exactly that situation,
    /// described in its own docs as being for external devices, and it
    /// needs only the scope this app already pairs with. A plain POST is
    /// also a great deal easier to keep working than a socket.
    func reportPlaying(romId: Int) async {
        var req = request(path: "/api/activity/heartbeat", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "rom_id": romId,
            "device_id": Self.deviceIdentifier,
        ])
        // Deliberately silent. Failing to record a play is not worth
        // interrupting one over.
        _ = try? await session.data(for: req)
    }

    /// Records a finished session, which is what actually gives a game a
    /// last played time.
    ///
    /// The heartbeat above is presence, answering "what is being played
    /// right now" and living in Redis. This is history, and the two are
    /// separate: sending only heartbeats left games with no last played
    /// time at all, so a game played here never reached Home's resume list
    /// or RomM's own.
    /// Returns whether the report actually reached the server, not just
    /// whether the request was sent: `Session` queues a session to disk
    /// the moment it ends and only clears that queue entry on a real
    /// success, the same durability the save-state queue already
    /// guarantees, so a lost connection mid-report never silently drops
    /// history the way this used to.
    @discardableResult
    func reportPlaySession(romId: Int, start: Date, end: Date) async -> Bool {
        var req = request(path: "/api/play-sessions", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": Self.deviceIdentifier,
            "sessions": [[
                "rom_id": romId,
                "start_time": stamp.string(from: start),
                "end_time": stamp.string(from: end),
                "duration_ms": max(0, Int(end.timeIntervalSince(start) * 1000)),
            ]],
        ])
        guard let (_, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// Maps a platform's folder name to the short name EmulatorJS's core
    /// catalogue actually uses, admin edited per install at Settings >
    /// Platforms on the server. RomM's own page reads this from the same
    /// endpoint before picking a core; skipping it is exactly what let a
    /// TurboGrafx-16 library named anything other than the one folder name
    /// this app happened to guess load no core at all. `/api/config` needs
    /// no scope beyond being logged in, and decodes only the one field this
    /// app uses out of a much larger response, so a future RomM adding
    /// fields here cannot break this.
    func platformsVersions() async throws -> [String: String] {
        let req = request(path: "/api/config")
        return try await send(req, decoding: PlatformsVersionsResponse.self).platformsVersions
    }

    private struct PlatformsVersionsResponse: Decodable {
        let platformsVersions: [String: String]
        enum CodingKeys: String, CodingKey {
            case platformsVersions = "PLATFORMS_VERSIONS"
        }
    }

    /// The ceiling EmulatorJS applies to its own on-device cache writes
    /// (`EmulatorJS-roms`, an IndexedDB database inside the player
    /// webview's origin), in bytes. Server config (`emulatorjs.cache_limit`
    /// in RomM's `config.yml`), not a RomM UI toggle. In EmulatorJS 4.2.3,
    /// the version RomM 5.1.0 pins, this is a per-file write threshold:
    /// a file whose `content-length` is at or over the limit still plays
    /// but is never cached; there is no whole-cache total and no eviction.
    /// `nil` when unset, in which case EmulatorJS falls back to its own
    /// hardcoded 1 GiB (1073741824 byte) default rather than any value
    /// RomM chose.
    func cacheLimitBytes() async throws -> Int64? {
        let req = request(path: "/api/config")
        return try await send(req, decoding: CacheLimitResponse.self).cacheLimitBytes
    }

    private struct CacheLimitResponse: Decodable {
        let cacheLimitBytes: Int64?
        enum CodingKeys: String, CodingKey {
            case cacheLimitBytes = "EJS_CACHE_LIMIT"
        }
    }

    /// The games with play history, most recent first. Same query RomM's own
    /// home screen makes (frontend getRecentPlayedRoms), so this app's Home
    /// agrees with the web UI about what you were last playing.
    func recentlyPlayed(limit: Int = 8, offset: Int = 0) async throws -> RomPage {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/roms"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "order_by", value: "last_played"),
            URLQueryItem(name: "order_dir", value: "desc"),
            URLQueryItem(name: "last_played", value: "true"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }

        var req = URLRequest(url: url)
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req, decoding: RomPage.self)
    }

    /// One page of games, optionally narrowed to a platform or a search term.
    /// Search runs on the server, matching the scope doc.
    /// `orderBy`/`orderDir` default to the alphabetical ordering every
    /// existing caller already got, so adding them changes nothing for
    /// anyone who does not pass them. The library's platform tiles pass
    /// `created_at`/`desc` to show what was added to a platform most
    /// recently, confirmed supported by RomM's own /api/roms parameters.
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
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order_by", value: orderBy),
            URLQueryItem(name: "order_dir", value: orderDir),
        ]
        // RomM's own "matched" flag means the game resolved against a
        // metadata provider, and on this server that is exactly the set
        // with cover art: checked across Arcade, Game Boy, Dreamcast and
        // Genesis, every matched game had a cover and every unmatched one
        // did not. Filtering server side beats fetching a window and
        // discarding the gaps.
        if matchedOnly {
            query.append(URLQueryItem(name: "matched", value: "true"))
        }
        if let platformId {
            query.append(URLQueryItem(name: "platform_ids", value: String(platformId)))
        }
        if let collectionId {
            query.append(URLQueryItem(name: "collection_id", value: String(collectionId)))
        }
        if let searchTerm, !searchTerm.isEmpty {
            query.append(URLQueryItem(name: "search_term", value: searchTerm))
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/roms"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }

        var req = URLRequest(url: url)
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req, decoding: RomPage.self)
    }

    // MARK: Favorites

    /// Every collection this account owns. Used only to find the one
    /// carrying `is_favorite`, never listed as a collections feature.
    func collections() async throws -> [Collection] {
        try await send(request(path: "/api/collections"), decoding: [Collection].self)
    }

    /// Creates the favorite collection the first time someone favorites a
    /// game on a server where nobody, on any client, has favorited one
    /// before. `is_public`/`is_favorite` are query parameters, not body
    /// fields, confirmed against RomM's own frontend
    /// (`services/api/collection.ts`'s `createCollection`), which is also
    /// why an empty multipart body with just a name is enough: every other
    /// field defaults server side.
    func createFavoriteCollection(name: String = "Favorites") async throws -> Collection {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/collections"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "is_public", value: "false"),
            URLQueryItem(name: "is_favorite", value: "true"),
        ]
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(name)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        return try await send(req, decoding: Collection.self)
    }

    func addRom(_ romId: Int, toCollection collectionId: Int) async throws -> Collection {
        try await sendCollectionRoms(collectionId, romId: romId, method: "POST")
    }

    func removeRom(_ romId: Int, fromCollection collectionId: Int) async throws -> Collection {
        try await sendCollectionRoms(collectionId, romId: romId, method: "DELETE")
    }

    private func sendCollectionRoms(_ collectionId: Int, romId: Int, method: String) async throws -> Collection {
        var req = request(path: "/api/collections/\(collectionId)/roms", method: method)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["rom_ids": [romId]])
        return try await send(req, decoding: Collection.self)
    }

    /// Roms in the favorite collection, same shape and paging as the
    /// library's own roms() call, for the Home screen's favorites rail.
    func favoriteRoms(limit: Int = 10) async throws -> [Rom] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/roms"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "favorite", value: "true"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }
        var req = URLRequest(url: url)
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req, decoding: RomPage.self).items
    }

    /// Saves, states and firmware for the launch screen. Each is a plain
    /// list the server already models, so nothing here reinterprets RomM.
    /// Uploads a save state the same way the webview player's injected
    /// JavaScript does (POST /api/states?rom_id=&emulator=, multipart with
    /// a `stateFile` part and an optional `screenshotFile`), but natively
    /// with bearer auth instead of riding the webview's cookies. The bytes
    /// are opaque to RomM; what matters for later loads is the `emulator`
    /// tag, which the launch screen uses to grey out states that the
    /// running core cannot restore.
    func uploadState(
        romId: Int,
        emulator: String,
        fileName: String,
        stateData: Data,
        screenshotName: String? = nil,
        screenshotData: Data? = nil
    ) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/states"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "rom_id", value: String(romId)),
            URLQueryItem(name: "emulator", value: emulator),
        ]
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"stateFile\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(stateData)
        body.append("\r\n".data(using: .utf8)!)
        if let screenshotName, let screenshotData {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"screenshotFile\"; filename=\"\(screenshotName)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
            body.append(screenshotData)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RommError.transport("The server sent a response the app could not read.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RommError(status: http.statusCode, body: data)
        }
    }

    func saves(romId: Int) async throws -> [GameSave] {
        try await sendQuery("/api/saves", [URLQueryItem(name: "rom_id", value: String(romId))])
    }

    /// Uploads a battery save (POST /api/saves, multipart with a `saveFile`
    /// part), the endpoint RomM keeps distinct from states for exactly this
    /// kind of data. `overwrite` replaces the server's copy of the same
    /// file name instead of stacking a new row per upload, which is what
    /// keeps a PS1 game at one memory card rather than one per session.
    /// Both the parameter and the part name are confirmed against the live
    /// server's OpenAPI schema, not assumed.
    func uploadSave(
        romId: Int,
        emulator: String,
        fileName: String,
        saveData: Data
    ) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/api/saves"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "rom_id", value: String(romId)),
            URLQueryItem(name: "emulator", value: emulator),
            URLQueryItem(name: "overwrite", value: "true"),
        ]
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"saveFile\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(saveData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RommError.transport("The server sent a response the app could not read.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RommError(status: http.statusCode, body: data)
        }
    }

    /// The raw bytes of one battery save, the same content-endpoint
    /// pattern as states, covers and firmware.
    func saveContent(_ save: GameSave) async throws -> Data {
        let req = request(path: "/api/saves/\(save.id)/content")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RommError.transport("The server sent a response the app could not read.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RommError(status: http.statusCode, body: data)
        }
        return data
    }

    func states(romId: Int) async throws -> [GameState] {
        try await sendQuery("/api/states", [URLQueryItem(name: "rom_id", value: String(romId))])
    }

    /// The raw bytes of one save state, confirmed real and standalone
    /// (`/api/states/{id}/content`, `assets.read`) rather than assumed:
    /// the launch screen used to seed a `state_id` into RomM's own
    /// localStorage and trust its page to notice and load it, and nothing
    /// ever confirmed that page actually did. It does not. This is the
    /// same content-endpoint pattern as covers and firmware, fetched
    /// directly and loaded through the emulator's own JavaScript API,
    /// the one path already proven to work: the pause menu's Load button.
    func stateContent(_ state: GameState) async throws -> Data {
        let req = request(path: "/api/states/\(state.id)/content")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RommError.transport("The server sent a response the app could not read.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RommError(status: http.statusCode, body: data)
        }
        return data
    }

    func firmware(platformId: Int) async throws -> [Firmware] {
        try await sendQuery(
            "/api/firmware", [URLQueryItem(name: "platform_id", value: String(platformId))]
        )
    }

    /// The individual files behind a ROM, each with its own flat
    /// `file_name` fetchable through `/api/roms/{id}/files/content/{file_name}`.
    /// Export uses this instead of the single-file content endpoint
    /// whenever `rom.hasMultipleFiles` is true, and instead of
    /// `/api/roms/download` (the zip endpoint), which the scope doc's
    /// Open items flags as broken through the reverse proxy. Data Saver
    /// uses it too, for a single-file ROM's own file ID, needed to match
    /// the `file_ids` query parameter RomM's real player attaches.
    ///
    /// `/api/roms/{id}/files` is a real endpoint, confirmed from RomM's
    /// own OpenAPI spec, but it is NOT a list: its `id` is a *file's own*
    /// internal id, not the rom's, and it returns one `RomFileSchema`,
    /// not an array, `GET /api/roms/{id}/files/{id}` would have been the
    /// honest read of that path. The actual list lives on the rom's own
    /// detail response, confirmed via `DetailedRomSchema.files`, an
    /// `[RomFileSchema]` array included when fetching the rom itself.
    /// Found on device: the wrong assumption first shipped as a decode
    /// failure ("does not look like a RomM server"), not a network error,
    /// this app's own `Rom` model deliberately ignores unlisted fields
    /// (see its doc comment), so decoding the wrong shape as `[RomFile]`
    /// failed outright rather than silently returning nothing.
    func romFiles(romId: Int) async throws -> [RomFile] {
        try await send(request(path: "/api/roms/\(romId)"), decoding: RomFilesResponse.self).files
    }

    /// The same rom detail response `romFiles` reads, decoded as `Rom`
    /// itself this time: the one place a kept game's full record can be
    /// rebuilt from nothing but its id, for a manifest that survived a
    /// past format change with only a stub `Rom` to show for it.
    func rom(id: Int) async throws -> Rom {
        try await send(request(path: "/api/roms/\(id)"), decoding: Rom.self)
    }

    private struct RomFilesResponse: Decodable {
        let files: [RomFile]
    }

    private func sendQuery<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        )
        components?.queryItems = query
        guard let url = components?.url else {
            throw RommError.transport("Could not build the request address.")
        }
        var req = URLRequest(url: url)
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return try await send(req, decoding: T.self)
    }

    /// Raw bytes of a cover image.
    ///
    /// `path_cover_small` arrives as a complete server relative URL, prefix,
    /// query string and all, for example
    /// `/assets/romm/resources/roms/2/50/cover/small.png?ts=2025-03-11 06:50:19`.
    /// Resolve it against the base URL verbatim. Do not prepend anything: the
    /// prefix is already in it. The timestamp query holds a literal space, so
    /// the string needs percent encoding before it parses as a URL at all.
    /// The request carries the token so this works whether or not the
    /// instance protects its assets.
    func coverData(path: String) async throws -> Data {
        do {
            return try await assetData(path: path)
        } catch {
            #if DEBUG
            print("COVER_MISS \(error) path=\(path)")
            #endif
            throw RommError.notFound
        }
    }

    /// The screenshot attached to a save or a state, resolved exactly like
    /// a cover: a server relative `download_path`, not a content-by-id
    /// endpoint.
    func screenshotData(path: String) async throws -> Data {
        try await assetData(path: path)
    }

    /// Shared by every asset fetched through a raw relative path rather
    /// than a `/content` endpoint: percent-encode (the timestamp query
    /// RomM's cover paths carry has a literal space in it), resolve
    /// against the base URL, attach the bearer token so this works whether
    /// or not the instance protects its assets.
    private func assetData(path: String) async throws -> Data {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        guard let url = URL(string: encoded, relativeTo: baseURL) else {
            throw RommError.transport("The server sent an asset address the app could not read.")
        }
        var req = URLRequest(url: url)
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RommError.notFound
        }
        return data
    }

    /// Deletes one or more states. `assets.write`, already required for
    /// pairing, so no re-pair is needed for this.
    func deleteStates(ids: [Int]) async throws {
        try await deleteAssets(path: "/api/states/delete", key: "states", ids: ids)
    }

    /// Deletes one or more saves, the cartridge battery kind. Same
    /// endpoint shape as states, a different resource entirely.
    func deleteSaves(ids: [Int]) async throws {
        try await deleteAssets(path: "/api/saves/delete", key: "saves", ids: ids)
    }

    private func deleteAssets(path: String, key: String, ids: [Int]) async throws {
        var req = request(path: path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [key: ids])
        _ = try await send(req, decoding: [Int].self)
    }

    /// An authenticated request for a file endpoint that is not JSON, ROM
    /// and firmware content in particular. The caller drives the actual
    /// transfer, this only builds the request, since a real download needs
    /// a delegate for progress that does not belong on this actor.
    func fileRequest(path: String) -> URLRequest {
        request(path: path)
    }

    // MARK: Plumbing

    private func request(path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest, decoding: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            throw RommError(urlError: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RommError.transport("The server sent a response the app could not read.")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw RommError(status: http.statusCode, body: data)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RommError.decoding(String(describing: T.self))
        }
    }

    /// Stable per install. Reinstalling produces a new one, which shows up as a
    /// new entry in RomM's device list rather than silently reusing the old.
    private static var deviceIdentifier: String {
        let key = "com.mmagtech.RommApp.deviceIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }
}

enum RommError: LocalizedError, Equatable {
    /// The person has not approved in the browser yet. Expected, keep polling.
    case authorizationPending
    /// The server wants a longer gap between polls.
    case slowDown
    case accessDenied
    case pairingExpired
    /// The credential itself is bad or gone. Pairing again is the fix.
    case unauthorized
    /// A valid credential that lacks permission for this request. Pairing
    /// again can help, since scopes are fixed at pair time, but nothing is
    /// wrong with the device's sign in.
    case forbidden
    /// Refused with no explanation, which RomM itself does not do. Something
    /// in front of it is blocking this device or network. Never advise
    /// unpairing for this: the pairing is fine and destroying it fixes
    /// nothing.
    case blocked
    case notFound
    /// No usable connection, or one that died mid request. Distinct from
    /// every other case here because it is the only one the person can
    /// fix themselves by moving somewhere with signal, so the UI answers
    /// it with a retry rather than an explanation.
    case offline
    /// A reverse proxy in front of RomM rejecting an oversized request
    /// body, most often a save state. The webview player's injected JS
    /// already catches this on its own upload path; this is the same
    /// case for RommClient.uploadState's native path, which had no
    /// specific handling and fell through to the generic HTTP message.
    case stateTooLarge
    case http(Int)
    case transport(String)
    case decoding(String)

    /// Separates "there is no connection" from every other networking
    /// failure. A server that is genuinely unreachable at a good address
    /// counts as offline too: from where the person is standing, an
    /// unplugged server and an empty signal bar are the same problem with
    /// the same answer, try again later.
    init(urlError: URLError) {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .cannotFindHost, .cannotConnectToHost, .timedOut,
            .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
            self = .offline
        default:
            self = .transport(urlError.localizedDescription)
        }
    }

    /// RomM signals device flow states as HTTP 400 with an OAuth style
    /// `detail` string, which the OpenAPI spec does not document.
    init(status: Int, body: Data) {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?
            .flatMap { $0["detail"] as? String }

        switch (status, detail) {
        case (400, "authorization_pending"): self = .authorizationPending
        case (400, "slow_down"): self = .slowDown
        case (400, "access_denied"): self = .accessDenied
        case (400, "expired_token"): self = .pairingExpired
        // RomM's own docs draw the line: 401 is a bad or missing credential,
        // 403 is a good credential without the required scope. A 403 that
        // carries no RomM error body at all did not come from RomM, it came
        // from a proxy or security filter in front of it, which is a
        // completely different problem with a completely different fix.
        case (401, _): self = .unauthorized
        case (403, .some): self = .forbidden
        case (403, .none): self = .blocked
        case (404, _): self = .notFound
        case (413, _): self = .stateTooLarge
        default: self = .http(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .authorizationPending: return "Waiting for approval."
        case .slowDown: return "Slowing down requests."
        case .accessDenied: return "The request was denied in RomM."
        case .pairingExpired: return "The pairing code expired. Start again to get a new one."
        case .unauthorized:
            return "This device is signed out. Pair it again from Settings."
        case .forbidden:
            return "The server accepted this device but refused the request. It may need pairing again to be granted the permissions this app uses."
        case .blocked:
            return "The server refused the connection without explaining why. RomM itself may be fine: something in front of it, like a reverse proxy or a security filter, is likely blocking this device or your network. Nothing is wrong with your pairing, so signing out will not help."
        case .notFound:
            return "That address answered, but it does not look like a RomM server."
        case .offline:
            return "No connection to your server."
        case .stateTooLarge:
            return "That save state is too large for the server to accept. Saturn states run big; check your server's upload size limit."
        case .http(let code): return "The server returned an error. Code \(code)."
        case .transport(let message): return message
        case .decoding(let type):
            return "The server sent \(type) in a form this app did not expect. It may be running a RomM version this app has not been tested against."
        }
    }
}
