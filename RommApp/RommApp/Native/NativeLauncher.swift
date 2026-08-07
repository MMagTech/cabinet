import Foundation

/// Downloads a game (and whatever firmware its platform carries) through
/// the same request-building code the webview player uses, then activates
/// the rom's native core and hands the files to `LibretroFrontend`. This
/// is the native player's launch path, reached from the normal launch
/// screen; the Debug-screen smoke tests that predated it (a hardcoded
/// FBNeo test title list, a free-text Saturn search box) are gone, their
/// job done once the real flow existed to test instead.
enum NativeLauncher {
    enum LaunchError: LocalizedError {
        case noNativeCore
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .noNativeCore: return "No native core exists for this platform"
            case .unsupportedFormat(let detail): return detail
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

        // Saturn stays chd-only, deliberately, matching RomM's own
        // recommended format for CD platforms. cue/bin is real work
        // (a cue sheet plus per-track bins, multi-file download, the
        // core reading references between them) that has nothing to do
        // with the go/no-go's one question, whether Beetle Saturn holds
        // full speed, and a cue/bin failure would be indistinguishable
        // from a real performance failure. Revisit only if a concrete
        // library needs it once the core itself is a known quantity.
        if core == .beetleSaturn {
            guard !rom.hasMultipleFiles, rom.fsName.lowercased().hasSuffix(".chd") else {
                throw LaunchError.unsupportedFormat(
                    "Only .chd is supported for Saturn right now, not \"\(rom.fsName)\". Re-rip or re-add the game as chd."
                )
            }
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-player-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let romURL = workDir.appendingPathComponent(rom.fsName)
        try await download(session.romContentRequest(rom), to: romURL)

        var downloadedFirmwareURLs: [URL] = []
        if let firmwareList = try? await session.firmware(platformId: rom.platformId) {
            for firmware in firmwareList where !firmware.missingFromFS {
                let url = workDir.appendingPathComponent(firmware.fileName)
                if (try? await download(session.firmwareContentRequest(firmware), to: url)) != nil {
                    downloadedFirmwareURLs.append(url)
                }
            }
        }

        // Beetle Saturn hardcodes the exact filename it looks for
        // ("sega_101.bin" for Japan, "mpr-17933.bin" for NA/EU), no
        // fallback, and RomM's own firmware filenames are whatever
        // whoever uploaded them called the file. EmulatorJS's bundled
        // Saturn core clearly does the equivalent of this under the
        // hood, since the same file plays fine in the webview under
        // any name; this is that adaptation for the native side.
        // Copied under both region names rather than picked, since
        // there is no reliable region signal in what the API reports
        // (Firmware carries a filename, not a region) and the real
        // check is the disc's own region at runtime, not the file's:
        // both slots pointing at a same-sized BIOS lets whichever one
        // the disc actually asks for resolve correctly.
        if core == .beetleSaturn {
            for url in downloadedFirmwareURLs {
                guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                      size == 524_288
                else { continue }
                for name in ["sega_101.bin", "mpr-17933.bin"] {
                    let target = workDir.appendingPathComponent(name)
                    guard target != url, !FileManager.default.fileExists(atPath: target.path) else { continue }
                    try? FileManager.default.copyItem(at: url, to: target)
                }
            }
        }

        LibretroFrontend.shared.activateCore(core.coreID)
        if let failure = LibretroFrontend.shared.loadGame(romURL.path, systemDirectory: workDir.path) {
            throw NSError(domain: "NativeLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return core
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
