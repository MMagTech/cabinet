import Foundation

/// Downloads a game (and whatever firmware its platform carries) through
/// the same request-building code the webview player uses, then hands the
/// files to `FBNeoBridge`. This is the native player's launch path; the
/// `TestGame` list and its Debug-screen buttons remain as the quick smoke
/// test they were during the spike.
enum NativeLauncher {
    enum LaunchError: LocalizedError {
        case romNotFound(String)

        var errorDescription: String? {
            switch self {
            case .romNotFound(let name): return "No \"\(name)\" ROM found in the library"
            }
        }
    }

    /// Downloads and loads any arcade rom into the native core. Fetches
    /// every firmware file the platform lists rather than assuming which
    /// one the board wants: FBNeo looks BIOS files up by name in the
    /// system directory, ignores what it does not need, and boards like
    /// CV1000 need none at all, so extra files are harmless and missing
    /// ones are the only failure that matters.
    static func prepare(rom: Rom, session: Session) async throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-player-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let romURL = workDir.appendingPathComponent(rom.fsName)
        try await download(session.romContentRequest(rom), to: romURL)

        if let firmwareList = try? await session.firmware(platformId: rom.platformId) {
            for firmware in firmwareList where !firmware.missingFromFS {
                let url = workDir.appendingPathComponent(firmware.fileName)
                try? await download(session.firmwareContentRequest(firmware), to: url)
            }
        }

        if let failure = FBNeoBridge.loadGame(romURL.path, systemDirectory: workDir.path) {
            throw NSError(domain: "NativeLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }

    /// FBNeo/MAME short names for the spike's original test titles, kept
    /// as Debug-screen smoke tests.
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
    }

    @discardableResult
    static func load(_ game: TestGame, session: Session) async throws -> Rom {
        let page = try await session.roms(searchTerm: game.displayName)
        // Match on the exact FBNeo/MAME short name, not a substring of the
        // display name, so "Metal Slug" doesn't grab Metal Slug 2/X/3/5 and
        // "Shock Troopers" doesn't grab the first game in that series.
        guard let rom = page.items.first(where: { $0.fsNameNoExt.lowercased() == game.rawValue }) else {
            throw LaunchError.romNotFound(game.displayName)
        }
        try await prepare(rom: rom, session: session)
        return rom
    }

    private static func download(_ request: URLRequest, to url: URL) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "NativeLauncher",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"]
            )
        }
        try data.write(to: url)
    }
}
