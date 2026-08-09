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
    ///
    /// A kept game skips all of that: its directory already holds the ROM
    /// and firmware, so the core boots straight from it with zero network.
    @discardableResult
    @MainActor
    static func prepare(rom: Rom, session: Session) async throws -> NativeCore {
        let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        guard let platform = NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) else {
            throw LaunchError.noNativeCore
        }
        let core = platform.core

        // Saturn stays chd-only, deliberately, matching RomM's own
        // recommended format for CD platforms. cue/bin is real work
        // (a cue sheet plus per-track bins, multi-file download, the
        // core reading references between them) that has nothing to do
        // with the go/no-go's one question, whether Beetle Saturn holds
        // full speed, and a cue/bin failure would be indistinguishable
        // from a real performance failure. Revisit only if a concrete
        // library needs it once the core itself is a known quantity.
        if core == .beetleSaturn || core == .pcsxReARMed {
            guard !rom.hasMultipleFiles, rom.fsName.lowercased().hasSuffix(".chd") else {
                throw LaunchError.unsupportedFormat(
                    "Only .chd is supported for \(platform.displayName) right now, not \"\(rom.fsName)\". Re-rip or re-add the game as chd."
                )
            }
        }

        // Stale directories from earlier launches (crashes included, since
        // an exit cleanup never runs for those) go first, so temp space
        // holds at most the one game about to load.
        cleanUpTempDirectories()

        if let keptDir = KeptGameStore.shared.launchDirectory(romId: rom.id) {
            return try activate(platform: platform, romURL: keptDir.appendingPathComponent(rom.fsName), workDir: keptDir)
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

        stageFirmware(from: downloadedFirmwareURLs, in: workDir, platform: platform)

        return try activate(platform: platform, romURL: romURL, workDir: workDir)
    }

    private static func activate(platform: NativePlatform, romURL: URL, workDir: URL) throws -> NativeCore {
        let core = platform.core
        let loadURL = try extractedIfArchived(romURL, core: core, in: workDir)
        LibretroFrontend.shared.activateCore(core.coreID)
        LibretroFrontend.shared.setCoreOptions(NativeCoreOptionsStore.dictionary(for: platform))
        LibretroFrontend.shared.setControllerPortDevice(NativeCoreOptionsStore.padDevice(for: platform))
        if let failure = LibretroFrontend.shared.loadGame(loadURL.path, systemDirectory: workDir.path) {
            throw NSError(domain: "NativeLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        return core
    }

    /// Every cartridge-style core here expects a raw ROM, either a path it
    /// opens itself or bytes this app reads and hands over directly; none
    /// of them decompress .zip/.7z archives on their own. FBNeo is the one
    /// exception, its own arcade-set loader reads zips natively (arcade
    /// ROMs are always zipped), so extracting first would only get in its
    /// way. RomM serves cartridge platforms compressed, so without this a
    /// core silently receives archive bytes as if they were the ROM, no
    /// error, no crash, just garbage: found 2026-08-08 from a real device
    /// test, a Genesis Plus GX game that ran a few frames on compressed
    /// noise, produced one stray sound register write, then sat on a
    /// permanently blank VDP state for the rest of the session.
    private static func extractedIfArchived(_ romURL: URL, core: NativeCore, in workDir: URL) throws -> URL {
        let ext = romURL.pathExtension.lowercased()
        guard core != .fbneo, ext == "zip" || ext == "7z" else { return romURL }
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        let ok = romURL.path.withCString { archivePath in
            workDir.path.withCString { destDir in
                archive_extract_first_file(archivePath, destDir, &nameBuffer, Int32(nameBuffer.count)) != 0
            }
        }
        guard ok, let extractedName = String(validatingCString: nameBuffer), !extractedName.isEmpty else {
            throw LaunchError.unsupportedFormat(
                "Couldn't extract \"\(romURL.lastPathComponent)\". The archive may be corrupt or in an unsupported format."
            )
        }
        return workDir.appendingPathComponent(extractedName)
    }

    /// The BIOS filenames a platform's core looks for, and the exact size
    /// the real file is, since that is the only signal available to tell
    /// one downloaded firmware file from another.
    ///
    /// Every core here hardcodes the filenames it will try and gives up if
    /// none are present, while RomM's firmware filenames are whatever
    /// whoever uploaded them called the file. Copying under every name the
    /// core might ask for is what bridges the two.
    ///
    /// Copied under all of a platform's names rather than picked between
    /// them, because there is no reliable region signal in what the API
    /// reports (Firmware carries a filename, not a region) and the real
    /// check is the disc's own region at runtime, not the file's. Genesis
    /// Plus GX, like Beetle Saturn, selects a CD BIOS purely from the
    /// disc's region code with no fallback if that one file is absent, so
    /// every slot pointing at a same-sized BIOS is what lets whichever one
    /// the disc actually asks for resolve.
    private static let firmwareNames: [NativePlatform: (size: Int, names: [String])] = [
        // Saturn: Japan and NA/EU, 512KB.
        .saturn: (524_288, ["sega_101.bin", "mpr-17933.bin"]),
        // Sega CD: NTSC-U, PAL and NTSC-J, a fixed 128KB boot ROM.
        .segaCD: (131_072, ["bios_CD_U.bin", "bios_CD_E.bin", "bios_CD_J.bin"]),
        // TurboGrafx-CD: Beetle PCE Fast defaults to System Card 3, 256KB.
        .tgCD: (262_144, ["syscard3.pce"]),
    ]

    /// Copies whichever downloaded firmware file matches a platform's BIOS
    /// size into place under every name that platform's core will look for.
    /// A platform with no entry needs no BIOS and does nothing here.
    ///
    /// Shared with `KeptGameStore`, which runs it once at keep time so a
    /// kept game's directory is boot-ready with no work at launch.
    static func stageFirmware(from firmwareURLs: [URL], in dir: URL, platform: NativePlatform) {
        guard let expected = firmwareNames[platform] else { return }
        for url in firmwareURLs {
            guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
                  size == expected.size
            else { continue }
            for name in expected.names {
                let target = dir.appendingPathComponent(name)
                guard target != url, !FileManager.default.fileExists(atPath: target.path) else { continue }
                try? FileManager.default.copyItem(at: url, to: target)
            }
        }
    }

    /// Removes every temp directory a native launch ever created. Called
    /// on the way into a new launch and on the way out of the player, so
    /// an un-kept game's files live exactly as long as its session instead
    /// of waiting for iOS to purge them. Kept games live elsewhere and are
    /// never touched by this. Deleting under the still-active core is safe:
    /// the file stays readable through its open handle until the core
    /// unloads, POSIX semantics, only the directory entry goes now.
    static func cleanUpTempDirectories() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("native-player-") {
            try? fm.removeItem(at: entry)
        }
    }

    /// Streams straight to disk rather than materializing the whole
    /// response as one `Data` blob: found 2026-08-08 from a real device
    /// crash on a PS1 .chd, `NSMallocException: Failed to grow buffer to
    /// 3632512361` (roughly 3.6GB), `URLSession.data(for:)` trying to hold
    /// an entire multi-gigabyte file in memory at once on a phone. Every
    /// ROM/firmware download in this app went through that one call;
    /// arcade sets and cartridge ROMs never got big enough to hit the
    /// ceiling, PS1 discs are the first platform here that reliably do.
    private static func download(_ request: URLRequest, to url: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "NativeLauncher",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"]
            )
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}
