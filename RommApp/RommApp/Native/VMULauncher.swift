import Foundation

/// The VMU minigame player's launch and sync path. Deliberately not
/// NativeLauncher: nothing here downloads a ROM, because the "ROM" is
/// the DC game's own save card, already synced through MemoryCardStore.
/// This opens and writes THE SAME card file RomM stores as that game's
/// save, one row, one sync path, per the settled design; the minigame
/// is cargo inside the save, never a platform or a library entry.
///
/// The local layer's guarantee: the phone's card is always current. The
/// core commits every flash write into the play file in real time
/// (VeMUlator's enable_flash_write, spike-proven), so nothing is lost
/// locally even to an app kill, and `prepare` reconciles a play file a
/// kill orphaned back into the store's write-first queue before every
/// boot. The server layer uploads on quit and on backgrounding, both
/// through the same durable pending-flag queue every other card rides.
///
/// The two-writer rule lives at the door, not here: the launch screen's
/// VMU row declines while a television is running a DC session for the
/// same game (the pairing scout can tell), so the phone and the TV never
/// edit one card at once.
enum VMULauncher {
    /// The live play file. Its whole directory chain is deliberately
    /// dot-free: VeMUlator identifies the file type by the dot in the
    /// path (patched to the LAST dot in build-core.sh, still worth not
    /// tempting), and anything but ".bin" loads as nothing, no flash
    /// image, no write-through, no error.
    static func playCardURL(romId: Int) -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support
            .appendingPathComponent("VMUCards", isDirectory: true)
            .appendingPathComponent("rom_\(romId)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("card.bin")
    }

    /// The card that would boot if the VMU row were tapped right now:
    /// the store's copy, superseded by a play file only a crash could
    /// have left newer. This is what the launch screen parses for the
    /// minigame row, so detection and boot read the same bytes.
    static func currentCard(romId: Int) -> Data? {
        let stored = MemoryCardStore.shared.localCard(romId: romId)
        // A play file differing from the store holds writes the store
        // has not absorbed yet (a crash mid-play); prefer it. Otherwise
        // the store is the truth.
        if let play = try? Data(contentsOf: playCardURL(romId: romId)),
           play.count == VMUCard.cardSize, play != stored {
            return play
        }
        if let stored, stored.count == VMUCard.cardSize { return stored }
        return nil
    }

    /// Decides which card plays and places it as the live play file.
    /// Same launch decision every card platform makes, in order: a play
    /// file orphaned by a crash feeds the store's queue first (it is
    /// strictly newer than anything else local), then a still-pending
    /// local card wins outright, then the server's own Flycast row when
    /// its stamp moved, then whatever is on this device. On the go this
    /// is Cabinet's normal remote flow: fetch latest, play, upload back
    /// on exit; fully offline works exactly when the card was already
    /// here. Returns nil when no card exists anywhere, which the launch
    /// screen's detection has already ruled out on every real path.
    @MainActor
    static func prepare(rom: Rom, session: Session) async -> URL? {
        let store = MemoryCardStore.shared
        let target = playCardURL(romId: rom.id)
        let tag = NativeCore.flycast.emulatorTag

        // The crash reconcile: a play file the last session never
        // captured (no quit, no backgrounding, just a kill) carries the
        // newest writes in existence. Absorb it before deciding.
        if let orphan = try? Data(contentsOf: target),
           orphan.count == VMUCard.cardSize,
           orphan != store.localCard(romId: rom.id) {
            store.storeSnapshot(romId: rom.id, data: orphan)
            DiagnosticsLog.record(
                context: "VMU player",
                message: "Reconciled a play card the last session never uploaded.",
                romVersion: session.serverVersion
            )
        }

        func place(_ data: Data) -> URL? {
            do {
                try data.write(to: target, options: .atomic)
                return target
            } catch {
                return nil
            }
        }

        let local = store.localCard(romId: rom.id)
        if store.pendingUpload(romId: rom.id), let local {
            // Retry the owed upload while the game boots, the same
            // retry syncIn gives every other pending card; not awaited,
            // so a dead network cannot hold the boot.
            Task {
                await MemoryCardSync.uploadCard(
                    local, romId: rom.id, fileNameStem: rom.fsNameNoExt,
                    emulatorTag: tag, session: session
                )
            }
            return place(local)
        }

        if let saves = try? await session.saves(romId: rom.id) {
            let own = saves
                .filter { $0.emulator == tag && MemoryCardStore.region(ofFileName: $0.fileName) == .saveRAM }
                .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                .first
            if let own, own.updatedAt != store.serverStamp(romId: rom.id) || local == nil,
               let bytes = try? await session.saveContent(own), bytes.count == VMUCard.cardSize {
                store.storeDownloaded(romId: rom.id, data: bytes, serverStamp: own.updatedAt)
                return place(bytes)
            }
        }

        if let local { return place(local) }
        return nil
    }

    /// Reads the play file back into the store's write-first queue and
    /// uploads it, the server half of the sync policy. Called on quit
    /// and on backgrounding, with the core paused, so the file is
    /// quiescent when read. No mid-play uploads on purpose: churn
    /// without benefit, and the two-writer rule already guards the TV.
    @MainActor
    static func capture(rom: Rom, session: Session) async {
        let store = MemoryCardStore.shared
        guard let data = try? Data(contentsOf: playCardURL(romId: rom.id)),
              data.count == VMUCard.cardSize,
              data != store.localCard(romId: rom.id)
        else { return }
        store.storeSnapshot(romId: rom.id, data: data)
        DiagnosticsLog.record(
            context: "VMU player",
            message: "Captured the card after play, \(data.count) bytes, uploading.",
            romVersion: session.serverVersion
        )
        await MemoryCardSync.uploadCard(
            data, romId: rom.id, fileNameStem: rom.fsNameNoExt,
            emulatorTag: NativeCore.flycast.emulatorTag, session: session
        )
    }

    /// Boots the core on the placed card. The frontend side of what
    /// NativeLauncher.activate does, minus everything a card does not
    /// need: no firmware, no archive extraction, no controller port
    /// devices. enable_flash_write is the whole point, stated here
    /// rather than defaulted.
    @MainActor
    static func boot(cardURL: URL) -> String? {
        #if targetEnvironment(simulator)
        // Same reasoning as NativeLauncher.activate: no cores link in a
        // simulator build.
        return "Games can't run in the Simulator. Use a real iPhone."
        #else
        LibretroFrontend.shared.activateCore(.vemulator)
        LibretroFrontend.shared.setCoreOptions(["enable_flash_write": "enabled"])
        let dir = cardURL.deletingLastPathComponent().path
        return LibretroFrontend.shared.loadGame(cardURL.path, systemDirectory: dir, saveDirectory: dir)
        #endif
    }
}
