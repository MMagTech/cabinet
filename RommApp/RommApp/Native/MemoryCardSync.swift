import Foundation

/// The battery-save engine both players drive: which copy of an in-game
/// save wins at launch, when a snapshot travels, and how each region
/// (card, Game Boy clock, Sega CD cart, Dreamcast VMU, the file-writing
/// cores' flushes) is captured and uploaded. One shared type on purpose,
/// extracted 2026-08-16 from `NativePlayerView` when the tvOS pass would
/// otherwise have meant a second copy: the tvOS player carried exactly
/// such a copy once before and it silently went stale, which is how tvOS
/// spent a day syncing only PS1 and N64 while iOS had every platform.
/// The views own the *when* (pause, background, quit); this type owns
/// the *what*.
///
/// One instance per play session, created by the player view alongside
/// its renderer. Not a singleton: `lastCardData` and friends are session
/// state, and two sessions must never share them.
@MainActor
final class MemoryCardSync {
    private let rom: Rom
    private let core: NativeCore
    private let platform: NativePlatform
    private let session: Session
    private let renderer: NativePlayerRenderer

    /// The card bytes as of the last sync or upload, so snapshots only
    /// travel when an in-game save actually changed them.
    private var lastCardData: Data?
    /// Same idea for the Game Boy clock region. Tracked separately so a
    /// clock tick alone never counts as a card change.
    private var lastRTCData: Data?

    init(rom: Rom, core: NativeCore, platform: NativePlatform, session: Session, renderer: NativePlayerRenderer) {
        self.rom = rom
        self.core = core
        self.platform = platform
        self.session = session
        self.renderer = renderer
    }

    private func cardHasSaves(_ card: Data) -> Bool {
        MemoryCardStore.cardHasSaves(card, platform: platform)
    }

    // MARK: Launch

    /// The launch-time decision of which card goes into the slot: a local
    /// copy still waiting to upload always wins (it is strictly newer than
    /// anything the server has), otherwise the server's card wins whenever
    /// its stamp moved since the last sync, covering saves made on another
    /// device. Offline, or with nothing on the server, whatever is on disk
    /// plays. A game with no card anywhere just starts with the core's
    /// own freshly formatted one. Releases `renderer.awaitingSaveRAM`
    /// whichever way it resolves.
    func syncIn() async {
        guard platform.savesOverSaveRAM else {
            renderer.awaitingSaveRAM = false
            return
        }
        defer { renderer.awaitingSaveRAM = false }
        let store = MemoryCardStore.shared
        let local = store.localCard(romId: rom.id)
        let localUseful = local.map(cardHasSaves) ?? false

        if store.pendingUpload(romId: rom.id), let local, localUseful {
            renderer.pendingSaveRAM = local
            lastCardData = local
            DiagnosticsLog.record(
                context: "Memory card",
                message: "Using the local card; its upload is still pending.",
                romVersion: session.serverVersion
            )
            await uploadMemoryCard(local)
            await syncRTCIn(serverRows: nil)
            return
        }

        if let saves = try? await session.saves(romId: rom.id) {
            // The clock and cart regions travel as their own rows; they
            // are never cards and never adoption candidates, so they stay
            // out of every decision below.
            let sorted = saves
                .filter { MemoryCardStore.region(ofFileName: $0.fileName) == .saveRAM }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            let own = sorted.first { $0.emulator == core.emulatorTag }
            // A game with no Cabinet card worth keeping adopts the newest
            // card from anywhere else: a save uploaded through RomM's web
            // UI, a card brought over from another emulator. Only ever as
            // a seed when there is no local card holding real saves, and
            // only if the bytes verify as an actual card image with saves
            // on it. In-game saves after this fork into Cabinet's own row;
            // the original upload is never touched.
            let newest = own ?? (localUseful ? nil : sorted.first)
            if let newest, newest.updatedAt != store.serverStamp(romId: rom.id) || !localUseful {
                if let bytes = try? await session.saveContent(newest),
                   cardHasSaves(bytes) {
                    store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: newest.updatedAt)
                    renderer.pendingSaveRAM = bytes
                    lastCardData = bytes
                    DiagnosticsLog.record(
                        context: "Memory card",
                        message: "Loaded \(newest.fileName) from the server into the card slot.",
                        romVersion: session.serverVersion
                    )
                    await syncRTCIn(serverRows: saves)
                    return
                }
                DiagnosticsLog.record(
                    context: "Memory card",
                    message: "Found \(newest.fileName) on the server but its content did not verify as a card with saves.",
                    romVersion: session.serverVersion
                )
            }
            if let local {
                renderer.pendingSaveRAM = local
                lastCardData = local
                DiagnosticsLog.record(
                    context: "Memory card",
                    message: localUseful ? "Using the local card." : "Using the local card; it holds no saves yet.",
                    romVersion: session.serverVersion
                )
            }
            await syncRTCIn(serverRows: saves)
            return
        }

        DiagnosticsLog.record(
            context: "Memory card",
            message: "Could not list saves from the server; using what is on this device.",
            romVersion: session.serverVersion
        )

        if let local {
            renderer.pendingSaveRAM = local
            lastCardData = local
            DiagnosticsLog.record(
                context: "Memory card",
                message: localUseful ? "Using the local card." : "Using the local card; it holds no saves yet.",
                romVersion: session.serverVersion
            )
        }
        await syncRTCIn(serverRows: nil)
    }

    /// The Game Boy clock region's own, much simpler launch decision:
    /// only ever Cabinet's own row (a clock from another emulator's save
    /// means nothing to this core's format), local-pending wins, else a
    /// server copy newer than the last sync, else whatever is on disk.
    /// `serverRows` reuses the list the card sync already fetched; nil
    /// means the server was unreachable and only the local copy plays.
    private func syncRTCIn(serverRows: [GameSave]?) async {
        let store = MemoryCardStore.shared
        let local = store.localCard(romId: rom.id, region: .rtc)

        if store.pendingUpload(romId: rom.id, region: .rtc), let local {
            renderer.pendingRTC = local
            lastRTCData = local
            await uploadMemoryCard(local, region: .rtc)
            return
        }

        if let own = serverRows?
            .filter({ $0.emulator == core.emulatorTag && MemoryCardStore.region(ofFileName: $0.fileName) == .rtc })
            .sorted(by: { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") })
            .first,
           own.updatedAt != store.serverStamp(romId: rom.id, region: .rtc) || local == nil,
           let bytes = try? await session.saveContent(own), !bytes.isEmpty {
            store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: own.updatedAt, region: .rtc)
            renderer.pendingRTC = bytes
            lastRTCData = bytes
            return
        }

        if let local {
            renderer.pendingRTC = local
            lastRTCData = local
        }
    }

    // MARK: Pause-time capture

    /// Everything a paused core can hand over: the memory-API card (plus
    /// the clock when the region exists) and Dreamcast's VMU file. Call
    /// on every pause, quit and background: cards are small and in-game
    /// saves are the one thing a player never expects to lose. The
    /// file-writing cores (Sega CD, Neo Geo Pocket) cannot be captured
    /// here, their files only exist after the quit-time shutdown; see
    /// `captureAfterShutdown()`.
    func capturePauseSnapshot() {
        captureMemoryCard()
        captureVMUSave()
    }

    /// A card that never held a save does not travel: a session that
    /// started with nothing (no local card, no server card) and whose
    /// bytes still read as a factory erase pattern is just the core's own
    /// freshly initialized region, and uploading it would put a junk row
    /// on the server for every save-less game ever paused. The moment a
    /// card holds anything real, or a real card existed before this
    /// session, every change travels, erasing a save included.
    private func captureMemoryCard() {
        guard platform.savesOverSaveRAM, renderer.paused, let data = renderer.snapshotSaveRAM() else { return }
        guard data != lastCardData else { return }
        guard cardHasSaves(data) || lastCardData != nil else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        Task { await uploadMemoryCard(data) }
        captureRTC()
    }

    /// The clock region rides along only when the card itself just
    /// traveled: the region ticks on every real-world second, so change
    /// alone means nothing, but a clock captured next to a fresh save is
    /// exactly what keeps Pokemon Gold and Silver's day/night right when
    /// the save comes back on this or another device.
    private func captureRTC() {
        guard let rtc = renderer.snapshotRTC(), rtc != lastRTCData else { return }
        lastRTCData = rtc
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: rtc, region: .rtc)
        Task { await uploadMemoryCard(rtc, region: .rtc) }
    }

    /// Dreamcast only, and structurally different from the card capture:
    /// Flycast never exposes its VMU save through RETRO_MEMORY_SAVE_RAM
    /// at all (confirmed against its own retro_get_memory_data, which
    /// only ever answers RETRO_MEMORY_SYSTEM_RAM), it writes a real file
    /// straight into the system directory. This is the capture half; the
    /// restore half is `NativeLauncher.restoreVMUSaveIfNeeded`, which
    /// writes the card back as `dc/vmu_save_A1.bin` before the core
    /// boots. That is Flycast's fallback filename, so if the core ever
    /// resolves the disc's own game id and looks for the per-game name
    /// instead, the restore is silently ignored; not yet seen on
    /// hardware.
    private func captureVMUSave() {
        guard platform == .dreamcast, renderer.paused else { return }
        guard let systemDir = LibretroFrontend.shared.systemDirectory() else { return }
        // Same "dc/" subdirectory the BIOS needed: confirmed 2026-08-11
        // by pulling the app's real data container and finding the file
        // at workDir/dc/vmu_save_A1.bin after a real in-game save.
        let scanDir = URL(fileURLWithPath: systemDir).appendingPathComponent("dc", isDirectory: true).path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: scanDir) else { return }
        // No leading underscore: PerGameVmu names the file
        // "<gameId>_vmu_save_A1.bin", but Flycast falls back to the bare
        // "vmu_save_A1.bin" whenever the disc's own game id isn't
        // available yet at the moment it names the file.
        guard let vmuName = entries.first(where: { $0.hasSuffix("vmu_save_A1.bin") }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: scanDir).appendingPathComponent(vmuName))
        else { return }
        guard data != lastCardData else { return }
        lastCardData = data
        MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data)
        DiagnosticsLog.record(
            context: "VMU save", message: "Found \(vmuName), \(data.count) bytes, uploading.",
            romVersion: session.serverVersion
        )
        Task { await uploadMemoryCard(data) }
    }

    // MARK: Quit-time capture

    /// Sega CD and Neo Geo Pocket, after `LibretroFrontend.unloadGame()`
    /// has made the core flush: reads the save file the core just wrote
    /// into its persistent save directory and syncs it through the same
    /// store and upload as everything else. Quit is the only capture
    /// point these two have; a session ended by iOS killing the app
    /// loses its in-game saves since launch, the same accepted
    /// limitation FBNeo's NVRAM always had, and the same one RetroArch
    /// lives with for these cores. Compared against the store's own copy
    /// rather than `lastCardData`, which the launch sync never sets for
    /// these platforms; the same junk guard applies so a session that
    /// never saved uploads nothing.
    func captureAfterShutdown() {
        let suffix: String
        switch platform {
        case .segaCD: suffix = ".brm"
        case .ngpc: suffix = ".flash"
        default: return
        }
        let dir = NativeLauncher.coreSaveDirectory(romId: rom.id)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }

        func capture(_ file: URL, region: MemoryCardStore.Region) {
            guard let data = try? Data(contentsOf: file) else { return }
            let previous = MemoryCardStore.shared.localCard(romId: rom.id, region: region)
            guard data != previous else { return }
            guard cardHasSaves(data) || previous != nil else { return }
            MemoryCardStore.shared.storeSnapshot(romId: rom.id, data: data, region: region)
            DiagnosticsLog.record(
                context: "In-game save",
                message: "Captured \(file.lastPathComponent), \(data.count) bytes, after core shutdown.",
                romVersion: session.serverVersion
            )
            Task { await self.uploadMemoryCard(data, region: region) }
        }

        // The internal backup RAM (or NGP's flash); the cart file is its
        // own region below, never this one.
        if let file = entries.first(where: {
            $0.lastPathComponent.hasSuffix(suffix) && !$0.lastPathComponent.hasSuffix("cart.brm")
        }) {
            capture(file, region: .saveRAM)
        }

        // Sega CD's external RAM cartridge, the location games prefer
        // when one is present (Lunar routed its save here on the first
        // real device test). Same store, same upload, its own row.
        if platform == .segaCD,
           let cart = entries.first(where: { $0.lastPathComponent.hasSuffix("cart.brm") }) {
            capture(cart, region: .cart)
        }
    }

    // MARK: Upload

    private func uploadMemoryCard(_ data: Data, region: MemoryCardStore.Region = .saveRAM) async {
        do {
            // The Cabinet marker keeps this row's filename distinct from
            // anything the web player made: RomM's overwrite matches rows
            // by filename alone, emulator tag not included (confirmed in
            // its saves endpoint source), so a bare "<name>.srm" upload
            // would silently take over and rewrite an existing EmulatorJS
            // card of the same name.
            try await session.uploadSave(
                romId: rom.id, emulator: core.emulatorTag,
                fileName: "\(rom.fsNameNoExt) (Cabinet).\(region.rawValue)", saveData: data
            )
            // Re-list to learn the stamp the server just minted, so the
            // next launch recognises its own upload instead of pulling
            // it back down.
            let saves = (try? await session.saves(romId: rom.id)) ?? []
            let stamp = saves
                .filter { $0.emulator == core.emulatorTag && MemoryCardStore.region(ofFileName: $0.fileName) == region }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                .first?.updatedAt
            MemoryCardStore.shared.markUploaded(romId: rom.id, serverStamp: stamp, region: region)
        } catch {
            // The disk copy and its pending flag survive; the next launch
            // retries. Same soft failure as the state queue.
        }
    }
}
