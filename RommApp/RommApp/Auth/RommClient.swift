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
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
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

    // MARK: Library

    func platforms() async throws -> [Platform] {
        try await send(request(path: "/api/platforms"), decoding: [Platform].self)
    }

    /// One page of games, optionally narrowed to a platform or a search term.
    /// Search runs on the server, matching the scope doc.
    func roms(
        platformId: Int? = nil,
        searchTerm: String? = nil,
        limit: Int = 60,
        offset: Int = 0
    ) async throws -> RomPage {
        var query = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "order_by", value: "name"),
            URLQueryItem(name: "order_dir", value: "asc"),
        ]
        if let platformId {
            query.append(URLQueryItem(name: "platform_ids", value: String(platformId)))
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
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        guard let url = URL(string: encoded, relativeTo: baseURL) else {
            throw RommError.transport("The server sent a cover address the app could not read.")
        }
        var req = URLRequest(url: url)
        if let accessToken {
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            #if DEBUG
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            print("COVER_MISS status=\(status) url=\(url.absoluteString)")
            #endif
            throw RommError.notFound
        }
        return data
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
        let (data, response) = try await session.data(for: req)

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
    case unauthorized
    case notFound
    case http(Int)
    case transport(String)
    case decoding(String)

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
        case (401, _), (403, _): self = .unauthorized
        case (404, _): self = .notFound
        default: self = .http(status)
        }
    }

    var errorDescription: String? {
        switch self {
        case .authorizationPending: return "Waiting for approval."
        case .slowDown: return "Slowing down requests."
        case .accessDenied: return "The request was denied in RomM."
        case .pairingExpired: return "The pairing code expired. Start again to get a new one."
        case .unauthorized: return "This device is no longer authorised. Pair it again."
        case .notFound:
            return "That address answered, but it does not look like a RomM server."
        case .http(let code): return "The server returned an error. Code \(code)."
        case .transport(let message): return message
        case .decoding(let type):
            return "The server sent \(type) in a form this app did not expect. It may be running a RomM version this app has not been tested against."
        }
    }
}
