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
    ///
    /// tvOS only: `LibretroFrontend` currently only carries a real static
    /// library for PCSX ReARMed (the PS1 go/no-go performance test), the
    /// other eleven cores have never been rebuilt for tvOS. This function
    /// itself is generic and compiles for both platforms; a tvOS caller
    /// asking for anything but a PS1 rom hits `LaunchError.noNativeCore`
    /// the same way an unsupported platform does on iOS today.
    @discardableResult
    @MainActor
    static func prepare(
        rom: Rom, session: Session, onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> NativeCore {
        let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        guard let platform = NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) else {
            throw LaunchError.noNativeCore
        }
        let core = platform.core

        // Saturn and PS1 stay chd-only, deliberately, matching RomM's own
        // recommended format for CD platforms. cue/bin is real work
        // (a cue sheet plus per-track bins, multi-file download, the
        // core reading references between them) that has nothing to do
        // with the go/no-go's one question, whether Beetle Saturn holds
        // full speed, and a cue/bin failure would be indistinguishable
        // from a real performance failure. Revisit only if a concrete
        // library needs it once the core itself is a known quantity.
        // Dreamcast joined the same restriction 2026-08-10: it has no
        // CHD convention of its own the way PS1/Saturn do (its native
        // formats are GDI, multi-file, or CDI), but CHD is the format
        // the emulation community and RomM itself converged on to avoid
        // GDI's multi-file mess, and every Dreamcast rom on the real
        // server checked against was already .chd, so the same
        // single-file restriction applies rather than building GDI
        // multi-file support nothing in this library needs yet.
        if core == .beetleSaturn || core == .pcsxReARMed || core == .flycast {
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

        #if os(iOS)
        if let keptDir = KeptGameStore.shared.launchDirectory(romId: rom.id) {
            return try await finishLaunch(
                platform: platform, rom: rom, session: session,
                romURL: keptDir.appendingPathComponent(rom.fsName), workDir: keptDir
            )
        }
        #endif

        #if os(tvOS)
        // A soft, evictable cache, not a kept-games equivalent: tvOS's own
        // storage tier is explicitly built for exactly this ("Caching and
        // Purgeable Memory" / the App Programming Guide for tvOS both
        // describe writing into the cache directory and letting the OS
        // decide when to reclaim it, system-wide across every app, not
        // per-app). Every tvOS launch used to redownload into a fresh
        // temp directory deleted unconditionally on exit, so replaying a
        // game already on Recent or Favorites cost a full download every
        // single time even though nothing about the file had changed. A
        // stable directory keyed by rom id, left in place instead of
        // wiped, means a repeat play skips the network entirely (ROM and
        // firmware both, since firmware already staged here from the
        // first run needs no re-fetch either) until the OS actually
        // reclaims the space, at which point this falls straight back to
        // downloading fresh with no special handling needed.
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("native-rom-cache", isDirectory: true)
            .appendingPathComponent(String(rom.id), isDirectory: true)
        let cachedROMURL = cacheDir.appendingPathComponent(rom.fsName)
        if FileManager.default.fileExists(atPath: cachedROMURL.path) {
            return try await finishLaunch(
                platform: platform, rom: rom, session: session,
                romURL: cachedROMURL, workDir: cacheDir
            )
        }
        let workDir = cacheDir
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        #else
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-player-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        #endif

        let romURL = workDir.appendingPathComponent(rom.fsName)
        try await download(session.romContentRequest(rom), to: romURL, onProgress: onProgress)

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

        return try await finishLaunch(
            platform: platform, rom: rom, session: session, romURL: romURL, workDir: workDir
        )
    }

    /// The tail every launch path shares once the ROM is on disk:
    /// extract if archived, restore whatever saves belong in place before
    /// the core boots, then activate. Extraction happens first because
    /// the file-writing cores name their save after the loaded content
    /// (`<basename>.brm`, `<basename>.flash`), which for a zipped ROM is
    /// the extracted file's name, unknowable earlier.
    @MainActor
    private static func finishLaunch(
        platform: NativePlatform, rom: Rom, session: Session, romURL: URL, workDir: URL
    ) async throws -> NativeCore {
        // The person's pick where the platform offers one; the platform
        // default everywhere else, byte-identically.
        let core = NativeCoreChoice.resolved(for: rom, platform: platform)
        let loadURL = try extractedIfArchived(romURL, core: core, in: workDir)
        // On a platform with one core the directory is exactly what it
        // has always been. Only a multi-core platform namespaces by
        // core, so two arcade emulators can never write their NVRAM and
        // high scores over each other's. Existing arcade files are left
        // where they are on purpose (alpha, one user, high scores).
        let saveDir = coreSaveDirectory(
            romId: rom.id, core: platform.cores.count > 1 ? core : nil)
        await restoreVMUSaveIfNeeded(rom: rom, session: session, platform: platform, workDir: workDir)
        await restoreCoreFileSaveIfNeeded(
            rom: rom, session: session, platform: platform, core: core,
            loadURL: loadURL, saveDir: saveDir
        )
        // A gun cabinet's aim is absolute, so the core reads the pointer
        // channel; everything else reads relative mouse deltas.
        let gunCabinet = (AnalogControls.controls(forShortname: rom.fsNameNoExt)?.lightgun ?? 0) > 0
        return try activate(
            platform: platform, core: core, loadURL: loadURL,
            workDir: workDir, saveDir: saveDir, gunCabinet: gunCabinet)
    }

    /// The persistent per-game directory handed to the core as its save
    /// directory (RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY). This is where
    /// Sega CD writes its .brm, Neo Geo Pocket its .flash, FBNeo its
    /// NVRAM and high scores. Persistent on purpose, the way RetroArch's
    /// save directory is: this used to be the per-launch temp directory,
    /// so everything those cores flushed was deleted with the session,
    /// half of issue #5's stage 2. On tvOS it lives under Caches to
    /// match that platform's transient storage model; losing it there
    /// costs a re-download from RomM at worst, same deal as the ROM
    /// cache itself.
    static func coreSaveDirectory(romId: Int, core: NativeCore? = nil) -> URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        var dir = base
            .appendingPathComponent("CoreSaves", isDirectory: true)
            .appendingPathComponent(String(romId), isDirectory: true)
        if let core {
            dir = dir.appendingPathComponent(core.storageKey, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Throws away the emulator's own per-game settings, leaving the
    /// game's progress alone.
    ///
    /// MAME is the reason this exists. It keeps a per-game config file
    /// holding DIP switches and input assignments, writes it when the
    /// game exits, and reapplies it at every later launch, so one bad
    /// value makes a game permanently unplayable with no way back from
    /// inside the app. Cabinet now keeps MAME's own menu closed so
    /// nothing can set one (see the options in `activate`), but a
    /// device poisoned before that fix, or by anything similar in a
    /// future core, needs a door out.
    ///
    /// Deliberately does NOT touch nvram: that is high scores,
    /// bookkeeping and battery-backed progress, which is the player's
    /// and is not what breaks. Settings are recreated from defaults on
    /// the next launch.
    static func resetCoreSettings(romId: Int, core: NativeCore) {
        let cfg = coreSaveDirectory(romId: romId, core: core)
            .appendingPathComponent("cfg", isDirectory: true)
        try? FileManager.default.removeItem(at: cfg)
    }

    /// Whether there is anything for `resetCoreSettings` to remove, so
    /// a launch screen can offer the action only when it would do
    /// something.
    static func hasCoreSettings(romId: Int, core: NativeCore) -> Bool {
        let cfg = coreSaveDirectory(romId: romId, core: core)
            .appendingPathComponent("cfg", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: cfg.path)
        return !(contents ?? []).isEmpty
    }

    /// Sega CD, Neo Geo Pocket and 3DO: their cores read a save file by
    /// name from the save directory at load (bram_load, flash_read,
    /// opera_lr_nvram_load), so the restore is placing that file before
    /// boot, the same shape as the VMU path above and with the same
    /// own-rows-only rule: a web-player .srm for these platforms is not
    /// this file, so there is nothing foreign worth adopting.
    /// Where an arcade core keeps this game's NVRAM, relative to the
    /// save directory it was given. The two emulators disagree about
    /// both the folder and the extension, and their contents are not
    /// interchangeable, which is exactly why the sync keeps them apart
    /// rather than treating "the arcade save" as one thing.
    static func arcadeNVRAMFile(core: NativeCore, saveDir: URL, stem: String) -> URL? {
        switch core {
        case .mame2003Plus:
            return saveDir
                .appendingPathComponent("nvram", isDirectory: true)
                .appendingPathComponent("\(stem).nv")
        case .fbneo:
            return saveDir
                .appendingPathComponent("fbneo", isDirectory: true)
                .appendingPathComponent("\(stem).fs")
        default:
            return nil
        }
    }

    /// Arcade NVRAM in, before the core boots.
    ///
    /// Same decision rules the memory-card platforms use, keyed by core
    /// as well as by game: a copy this device still owes an upload wins
    /// outright, else a newer row from the server, else whatever is
    /// already on disk. What differs is only that a game legitimately
    /// has two of these, one per arcade emulator, and they are never
    /// candidates for each other.
    private static func restoreArcadeNVRAM(
        rom: Rom, session: Session, core: NativeCore, loadURL: URL, saveDir: URL
    ) async {
        let stem = loadURL.deletingPathExtension().lastPathComponent
        guard let target = arcadeNVRAMFile(core: core, saveDir: saveDir, stem: stem) else { return }
        let store = MemoryCardStore.shared

        func place(_ bytes: Data) {
            try? FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: target, options: .atomic)
        }

        let local = store.localCard(romId: rom.id, core: core)
        if store.pendingUpload(romId: rom.id, core: core), let local {
            place(local)
            return
        }
        if let own = (try? await session.saves(romId: rom.id))?
            .filter({ $0.emulator == core.emulatorTag })
            .sorted(by: { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") })
            .first,
           own.updatedAt != store.serverStamp(romId: rom.id, core: core) || local == nil,
           let bytes = try? await session.saveContent(own) {
            store.storeDownloaded(
                romId: rom.id, data: bytes, serverStamp: own.updatedAt, core: core)
            place(bytes)
            return
        }
        if let local {
            place(local)
        }
    }

    private static func restoreCoreFileSaveIfNeeded(
        rom: Rom, session: Session, platform: NativePlatform, core: NativeCore,
        loadURL: URL, saveDir: URL
    ) async {
        // nil suffix means the platform's file lives at a fixed nested
        // path instead of `<stem>.<suffix>`: Opera writes its NVRAM to
        // opera/shared/nvram.0.srm under the save directory (fixed
        // because forcedOptions pins nvram_storage and nvram_version),
        // so the restore target is that exact path.
        let suffix: String?
        switch platform {
        case .segaCD: suffix = "brm"
        case .ngpc: suffix = "flash"
        case .threeDO: suffix = nil
        case .arcade:
            await restoreArcadeNVRAM(
                rom: rom, session: session, core: core, loadURL: loadURL, saveDir: saveDir)
            return
        default: return
        }
        let store = MemoryCardStore.shared
        let stem = loadURL.deletingPathExtension().lastPathComponent
        // One server list for however many regions restore below; nil
        // means unreachable and only local copies play.
        let serverRows = try? await session.saves(romId: rom.id)

        // The same decision every region makes: a pending local copy wins
        // outright, else the newest own server row when its stamp moved
        // or nothing useful is local, else whatever is on this device.
        // Nothing anywhere leaves whatever file a previous session's
        // flush left in the save directory, which is already this game's
        // newest save; the core reads it exactly as it wrote it.
        func restore(region: MemoryCardStore.Region, to target: URL) async {
            let local = store.localCard(romId: rom.id, region: region)
            if store.pendingUpload(romId: rom.id, region: region), let local {
                try? local.write(to: target, options: .atomic)
                return
            }
            if let own = serverRows?
                .filter({ $0.emulator == platform.core.emulatorTag && MemoryCardStore.region(ofFileName: $0.fileName) == region })
                .sorted(by: { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") })
                .first,
               own.updatedAt != store.serverStamp(romId: rom.id, region: region) || local == nil,
               let bytes = try? await session.saveContent(own) {
                store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: own.updatedAt, region: region)
                try? bytes.write(to: target, options: .atomic)
                return
            }
            if let local {
                try? local.write(to: target, options: .atomic)
            }
        }

        if let suffix {
            await restore(region: .saveRAM, to: saveDir.appendingPathComponent("\(stem).\(suffix)"))
        } else {
            let operaDir = saveDir
                .appendingPathComponent("opera", isDirectory: true)
                .appendingPathComponent("shared", isDirectory: true)
            try? FileManager.default.createDirectory(at: operaDir, withIntermediateDirectories: true)
            await restore(region: .saveRAM, to: operaDir.appendingPathComponent("nvram.0.srm"))
        }

        // Sega CD's second save location, the external RAM cartridge,
        // which games prefer over the internal RAM when present (Lunar,
        // first device test). Its filename is fixed by the two core
        // options Cabinet forces: cart_bram stays on its "per cart"
        // default (per-game separation already comes from each game's
        // own save directory) and cart_size is "4meg", which makes the
        // core look for exactly this name.
        if platform == .segaCD {
            await restore(region: .cart, to: saveDir.appendingPathComponent("4Mbit_cart.brm"))
        }
    }

    /// Dreamcast only, and run before the core boots rather than after
    /// the way PS1's own `syncMemoryCardIn` in NativePlayerView does:
    /// Flycast reads whatever VMU file already exists on disk once,
    /// synchronously, while `retro_load_game` sets up its Maple bus
    /// devices, so anything placed after `loadGame` returns is already
    /// too late, there is no RETRO_MEMORY_SAVE_RAM injection point for
    /// this core the way there is for PS1's. The path itself is fixed
    /// and predictable, `<workDir>/dc/vmu_save_A1.bin`: confirmed
    /// 2026-08-11 by reading shell/libretro/oslib.cpp directly (a
    /// separate file from the core/oslib/oslib.cpp this investigation
    /// spent most of a session inside by mistake), where
    /// `per_content_vmus` defaults to 0 and the plain, gameId-free path
    /// is exactly what this core actually uses.
    ///
    /// Same own-card-wins-else-newest-server-card-wins logic as
    /// `syncMemoryCardIn`, just writing a file instead of handing bytes
    /// to the core directly, and applied uniformly to kept and
    /// temp-directory launches alike: a kept game's own directory
    /// already carries its last card forward for free, but a newer
    /// save from another device still deserves the same server check
    /// PS1 always runs regardless of Keep.
    private static func restoreVMUSaveIfNeeded(
        rom: Rom, session: Session, platform: NativePlatform, workDir: URL
    ) async {
        guard platform == .dreamcast else { return }
        let store = MemoryCardStore.shared
        let dcDir = workDir.appendingPathComponent("dc", isDirectory: true)
        let target = dcDir.appendingPathComponent("vmu_save_A1.bin")

        func place(_ data: Data) {
            try? FileManager.default.createDirectory(at: dcDir, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }

        let local = store.localCard(romId: rom.id)
        if store.pendingUpload(romId: rom.id), let local {
            place(local)
            return
        }

        if let saves = try? await session.saves(romId: rom.id) {
            let sorted = saves.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            let own = sorted.first { $0.emulator == NativeCore.flycast.emulatorTag }
            if let own, own.updatedAt != store.serverStamp(romId: rom.id) || local == nil,
               let bytes = try? await session.saveContent(own) {
                store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: own.updatedAt)
                place(bytes)
                return
            }
        }

        if let local {
            place(local)
        }
    }

    private static func activate(platform: NativePlatform, core: NativeCore, loadURL: URL, workDir: URL, saveDir: URL, gunCabinet: Bool = false) throws -> NativeCore {
        #if targetEnvironment(simulator)
        // A simulator build links no cores: they are built for real
        // hardware and rebuilding emulator cores for a simulator proves
        // nothing, since performance there is meaningless. The block sits
        // here, at the point of actually starting a core, rather than in
        // platform resolution, so the rest of the app still knows
        // perfectly well which platforms are supported and the library
        // does not label every one of them unplayable.
        throw LaunchError.unsupportedFormat("Games can't run in the Simulator. Use a real Apple TV.")
        #else
        LibretroFrontend.shared.activateCore(core.coreID)
        var coreOptions = NativeCoreOptionsStore.dictionary(for: platform)
        if core == .mame2003Plus {
            // Every option this core exposes, answered in one place.
            // An unanswered libretro variable does not leave the core
            // at its own default, it leaves a zeroed C global, which
            // is silence for a sample rate and off for every toggle
            // whose useful state is on. Eight bugs were found that way
            // one at a time before this table existed; see
            // MAME2003PlusOptions for the values and for the five
            // places Cabinet deliberately differs.
            coreOptions.merge(MAME2003PlusOptions.all(gunCabinet: gunCabinet)) { _, mine in mine }
        }
        LibretroFrontend.shared.setCoreOptions(coreOptions)
        let padDevice = NativeCoreOptionsStore.padDevice(for: platform)
        LibretroFrontend.shared.setControllerPortDevice(padDevice, port: 0)
        // Player 2 gets the same device type as player 1: nothing here
        // offers picking a different pad type per player, and every
        // platform that supports a second port treats both ports
        // identically (e.g. PSX's two standard controller ports).
        if platform.supportsSecondPlayer {
            LibretroFrontend.shared.setControllerPortDevice(padDevice, port: 1)
        }
        if let failure = LibretroFrontend.shared.loadGame(
            loadURL.path, systemDirectory: workDir.path, saveDirectory: saveDir.path
        ) {
            // Deliberately does NOT claim the core is wrong, because
            // nothing here knows that: a refusal is equally what a missing
            // BIOS, an incomplete romset, or a set built for a different
            // version of the same emulator looks like. It says only what
            // is known, which core refused, and offers the other as a
            // possibility rather than a diagnosis.
            //
            // Says the new thing and nothing else. It does not repeat
            // that the game failed to start, since the iOS alert is
            // already titled that and the tvOS text sits under a game
            // that plainly did not launch. It does not explain where the
            // picker is either: anyone running this app has a self-hosted
            // server and arcade romsets sorted into folders, and does not
            // need a tour of a screen they are looking at.
            var message = failure
            if platform.cores.count > 1 {
                let others = platform.cores
                    .filter { $0 != core }
                    .map(\.displayName)
                    .joined(separator: " or ")
                message = "\(core.displayName) refused it. Try \(others)."
            }
            throw NSError(domain: "NativeLauncher", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return core
        #endif
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
        // The two arcade cores load the archive itself: a romset zip IS
        // the rom, and extracting its first file would hand the core one
        // loose chip dump from a set of dozens.
        guard core != .fbneo, core != .mame2003Plus, ext == "zip" || ext == "7z" else { return romURL }
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
        // 3DO: every retail BIOS Opera knows is exactly 1MB. One name is
        // enough here because Opera does not scan by region the way the
        // CD cores above do: it loads exactly the file the opera_bios
        // option names, and forcedOptions always answers panafz10.bin,
        // so whatever 1MB firmware RomM has gets staged under the one
        // name the core will be told to load.
        .threeDO: (1_048_576, ["panafz10.bin"]),
    ]

    /// Copies whichever downloaded firmware file matches a platform's BIOS
    /// size into place under every name that platform's core will look for.
    /// A platform with no entry needs no BIOS and does nothing here.
    ///
    /// Shared with `KeptGameStore`, which runs it once at keep time so a
    /// kept game's directory is boot-ready with no work at launch.
    static func stageFirmware(from firmwareURLs: [URL], in dir: URL, platform: NativePlatform) {
        // Flycast's Apple build looks for its boot ROM under a "dc/"
        // subdirectory of the system directory, not the system directory
        // itself: documented in libretro-super's flycast_libretro.info,
        // confirmed the hard way 2026-08-10 with device console logging
        // after the flat placement every other platform here uses
        // produced a silent fallback to reios with no error. RomM's own
        // filename ("dc_boot.bin") already matches what Flycast looks
        // for, so this only needs a copy into the right subdirectory,
        // not the name-guessing the platforms below need.
        if platform == .dreamcast {
            let dcDir = dir.appendingPathComponent("dc", isDirectory: true)
            for url in firmwareURLs where url.lastPathComponent == "dc_boot.bin" {
                try? FileManager.default.createDirectory(at: dcDir, withIntermediateDirectories: true)
                let target = dcDir.appendingPathComponent("dc_boot.bin")
                guard !FileManager.default.fileExists(atPath: target.path) else { continue }
                try? FileManager.default.copyItem(at: url, to: target)
            }
        }

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
    ///
    /// Delegate-based rather than the plain async `download(for:)` this
    /// used before, purely to get `didWriteData`'s byte counts for
    /// `onProgress`: the launch button used to just spin with no signal
    /// on a large title, indistinguishable from a stall.
    private static func download(
        _ request: URLRequest, to url: URL, onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws {
        let delegate = ProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { continuation.resume(with: $0) }
            session.downloadTask(with: request).resume()
        }
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

    /// `didWriteData` fires on a background queue and the completion
    /// handler must move the temp file before returning, since iOS
    /// deletes it the instant that callback returns: the same constraint
    /// `RomExporter` documents for its own copy of this pattern.
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: @MainActor (Double) -> Void
        var completion: ((Result<(URL, URLResponse), Error>) -> Void)?

        init(onProgress: @escaping @MainActor (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let onProgress = onProgress
            Task { @MainActor in onProgress(fraction) }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            // Copied to a stable temp path synchronously, since `location`
            // is only guaranteed to exist for the duration of this call
            // and the checked continuation resumes asynchronously.
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("native-download-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: staged)
                completion?(.success((staged, downloadTask.response ?? URLResponse())))
            } catch {
                completion?(.failure(error))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error else { return }
            completion?(.failure(error))
        }
    }
}
