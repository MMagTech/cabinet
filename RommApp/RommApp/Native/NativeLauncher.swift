import Foundation

/// Downloads a game (and whatever firmware its platform carries) through
/// the same request-building code the webview player uses, then activates
/// the rom's native core and hands the files to `LibretroFrontend`. This
/// is the native player's launch path; the `TestGame` list and its
/// Debug-screen buttons remain as the quick smoke test they were during
/// the spike.
enum NativeLauncher {
    enum LaunchError: LocalizedError {
        case romNotFound(String)
        case noNativeCore

        var errorDescription: String? {
            switch self {
            case .romNotFound(let name): return "No \"\(name)\" ROM found in the library"
            case .noNativeCore: return "No native core exists for this platform"
            }
        }
    }

    /// Downloads and loads a rom into its native core. Fetches every
    /// firmware file the platform lists rather than assuming which one
    /// the board wants: a core looks BIOS files up by name in the system
    /// directory, ignores what it does not need (Beetle Saturn wants one
    /// of two region BIOSes; FBNeo boards like CV1000 need none at all),
    /// so extra files are harmless and missing ones are the only failure
    /// that matters.
    @discardableResult
    static func prepare(rom: Rom, session: Session) async throws -> NativeCore {
        guard let core = NativeCore.core(for: rom) else {
            throw LaunchError.noNativeCore
        }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-player-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // CD systems are multi-file in ways arcade zips never were: a chd
        // is one file, but cue/bin is a cue sheet plus one bin per track,
        // and the cue sheet's own text references the bin filenames it
        // expects beside it. Downloading every listed file by its own
        // name, into the same directory, is what keeps that reference
        // valid; the single-file path below covers everything else,
        // arcade zips included.
        if rom.hasMultipleFiles {
            let files = try await session.romFiles(romId: rom.id)
            for file in files {
                let url = workDir.appendingPathComponent(file.fileName)
                try await download(session.romFileContentRequest(romId: rom.id, file: file), to: url)
            }
        } else {
            let romURL = workDir.appendingPathComponent(rom.fsName)
            try await download(session.romContentRequest(rom), to: romURL)
        }

        if let firmwareList = try? await session.firmware(platformId: rom.platformId) {
            for firmware in firmwareList where !firmware.missingFromFS {
                let url = workDir.appendingPathComponent(firmware.fileName)
                try? await download(session.firmwareContentRequest(firmware), to: url)
            }
        }

        // The core reads whichever file it starts from: the cue sheet for
        // cue/bin, the chd itself, or the rom's own single file. fsName
        // is that entry point in every case, cue/bin included, since
        // RomM's own fs_name for a multi-file CD rom is the cue file.
        let entryPath = workDir.appendingPathComponent(rom.fsName).path

        LibretroFrontend.shared.activateCore(core.coreID)
        if let failure = LibretroFrontend.shared.loadGame(entryPath, systemDirectory: workDir.path) {
            throw NSError(domain: "NativeLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return core
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

    /// The Saturn go/no-go's loader: there is no fixed test title the way
    /// FBNeo's TestGame has one, because that requires knowing what is
    /// actually in a given library ahead of time. This searches by name
    /// and takes the first Saturn result instead, crude on purpose, per
    /// docs/scope-native-saturn.md's "hidden Debug button, hardcoded
    /// game, no polish". The picking of which two titles (2D then 3D) is
    /// still a human call made once at the Debug screen, not code.
    @discardableResult
    static func loadSaturnGame(named name: String, session: Session) async throws -> Rom {
        let page = try await session.roms(searchTerm: name)
        guard let rom = page.items.first(where: { $0.platformSlug == "saturn" }) else {
            throw LaunchError.romNotFound(name)
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
