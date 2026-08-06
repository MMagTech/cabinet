import Foundation

/// Debug-only smoke test for the native player spike: finds a test game
/// (and its BIOS, for families that need one) in the library, downloads
/// through the same request-building code the webview player uses, and
/// hands them to `FBNeoBridge` to confirm the core actually loads the game.
///
/// This is deliberately not wired through `GameLaunchView`/`PlayerView`.
/// Per docs/scope-native-player-spike.md the spike's entry point is a
/// hidden Debug-screen button hardcoded to specific test titles, not a real
/// player choice in the UI.
enum NativeSpike {
    enum SpikeError: LocalizedError {
        case romNotFound(String)
        case biosNotFound(String)

        var errorDescription: String? {
            switch self {
            case .romNotFound(let name): return "No \"\(name)\" ROM found in the library"
            case .biosNotFound(let name): return "No \(name) firmware found for that platform"
            }
        }
    }

    /// FBNeo/MAME short names for titles proven to have the webview leak
    /// (Neo Geo) or, for Deathsmiles, the separate slowness problem the
    /// webview showed without leaking. `biosFileName` is nil for families
    /// like CV1000 that boot standalone with no shared BIOS.
    enum TestGame: String, CaseIterable {
        case metalSlug = "mslug"
        case shockTroopers2ndSquad = "shocktr2"
        case deathsmiles = "deathsml"

        var displayName: String {
            switch self {
            case .metalSlug: return "Metal Slug"
            case .shockTroopers2ndSquad: return "Shock Troopers 2nd Squad"
            case .deathsmiles: return "Deathsmiles"
            }
        }

        var biosFileName: String? {
            switch self {
            case .metalSlug, .shockTroopers2ndSquad: return "neogeo.zip"
            case .deathsmiles: return nil
            }
        }
    }

    @discardableResult
    static func load(_ game: TestGame, session: Session) async throws -> Rom {
        let page = try await session.roms(searchTerm: game.displayName)
        // Match on the exact FBNeo/MAME short name, not a substring of the
        // display name, so "Metal Slug" doesn't grab Metal Slug 2/X/3/5 and
        // "Shock Troopers" doesn't grab the first game in that series.
        guard let rom = page.items.first(where: { $0.fsNameNoExt.lowercased() == game.rawValue }) else {
            throw SpikeError.romNotFound(game.displayName)
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-spike-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let romURL = workDir.appendingPathComponent(rom.fsName)
        try await download(session.romContentRequest(rom), to: romURL)

        if let biosFileName = game.biosFileName {
            let firmwareList = try await session.firmware(platformId: rom.platformId)
            guard let bios = firmwareList.first(where: { $0.fileName.lowercased() == biosFileName }) else {
                throw SpikeError.biosNotFound(biosFileName)
            }
            let biosURL = workDir.appendingPathComponent(biosFileName)
            try await download(session.firmwareContentRequest(bios), to: biosURL)
        }

        if let failure = FBNeoBridge.loadGame(romURL.path, systemDirectory: workDir.path) {
            throw NSError(domain: "NativeSpike", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }

        return rom
    }

    private static func download(_ request: URLRequest, to url: URL) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "NativeSpike",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"]
            )
        }
        try data.write(to: url)
    }
}
