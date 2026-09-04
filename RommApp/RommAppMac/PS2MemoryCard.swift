//  One memory card per PS2 game, synced to RomM.
//
//  PCSX2 ships the hardware's own arrangement: a single Mcd001.ps2 that
//  every game writes into. That is authentic and it is wrong for
//  Cabinet, because RomM stores saves against a rom and a shared card
//  belongs to no rom in particular. It would also mean every machine
//  had to agree on one ever-growing file. So each game gets its own
//  card, which is what Cabinet already does for PS1 through
//  MemoryCardStore.
//
//  Not built on MemoryCardStore itself: that store is keyed on
//  NativePlatform and NativeCore for its region and emulator-tag
//  handling, and PS2 has neither. What it shares is the convention,
//  and the one rule that matters, from the arcade NVRAM work: the
//  emulator tag goes in the RomM row or two emulators' uploads
//  overwrite each other.

import Foundation

enum PS2MemoryCard {
    /// The tag RomM files these under. PCSX2 rather than Cabinet,
    /// because the format is PCSX2's and another PCSX2 could read it.
    static let emulatorTag = "pcsx2"

    static var folder: URL {
        PS2Player.dataRoot.appending(path: "memcards")
    }

    /// PCSX2 wants a bare filename here, not a path: it resolves it
    /// against its own memcards folder.
    static func fileName(romId: Int) -> String {
        "cabinet-\(romId).ps2"
    }

    static func url(romId: Int) -> URL {
        folder.appending(path: fileName(romId: romId))
    }

    /// Pulls this game's card down if the server has a newer one than
    /// the copy on disk. Silent on any failure: a card that cannot be
    /// fetched must not stop a game from starting, it just starts with
    /// whatever is local.
    static func restore(rom: Rom, session: Session) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard let saves = try? await session.saves(romId: rom.id) else { return }
        let mine = saves
            .filter { $0.emulator == emulatorTag }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        guard let newest = mine.first else { return }

        let local = url(romId: rom.id)
        let localStamp = stamp(romId: rom.id)
        guard newest.updatedAt != localStamp || !FileManager.default.fileExists(atPath: local.path) else {
            return
        }
        guard let bytes = try? await session.saveContent(newest), !bytes.isEmpty else { return }

        try? bytes.write(to: local)
        setStamp(newest.updatedAt, romId: rom.id)
    }

    /// Uploads the card if it changed while the game ran. Compared by
    /// content rather than by modification date, because PCSX2 rewrites
    /// the file on every shutdown whether a game saved or not, and
    /// uploading an unchanged 8MB card after every session would be
    /// pure noise on the server and the network.
    static func store(rom: Rom, session: Session, since digestBefore: Data?) async {
        let local = url(romId: rom.id)
        guard let bytes = try? Data(contentsOf: local), !bytes.isEmpty else { return }

        // Unchanged is only a reason to skip if the server already has
        // this card. A card that has never been uploaded looks exactly
        // like one that is safely stored, and staying quiet about it
        // means a save can sit on one machine forever believing it
        // synced. That is not hypothetical: the card adopted from
        // PCSX2's shared Mcd001 arrives already containing a save, so
        // it never "changes" and never travelled.
        let neverUploaded = stamp(romId: rom.id) == nil
        guard neverUploaded || digest(bytes) != digestBefore else { return }

        do {
            try await session.uploadSave(
                romId: rom.id,
                emulator: emulatorTag,
                fileName: fileName(romId: rom.id),
                saveData: bytes
            )
            // Re-read the row to learn the server's own timestamp,
            // rather than inventing one that will not match next time.
            if let saves = try? await session.saves(romId: rom.id) {
                let mine = saves
                    .filter { $0.emulator == emulatorTag }
                    .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
                setStamp(mine.first?.updatedAt, romId: rom.id)
            }
        } catch {
            // Left on disk with no stamp, so the next launch sees a
            // local card the server does not know about and keeps it.
        }
    }

    /// A cheap content fingerprint, taken before a game runs so the
    /// upload afterwards can tell whether anything actually changed.
    static func digest(_ data: Data) -> Data {
        var hash = Data(count: 32)
        data.withUnsafeBytes { raw in
            hash.withUnsafeMutableBytes { out in
                let source = raw.bindMemory(to: UInt8.self)
                let target = out.bindMemory(to: UInt8.self)
                // Sampled rather than hashed in full: an 8MB card read
                // twice per launch is real time, and a save changes far
                // more than a handful of scattered bytes.
                for i in 0..<32 {
                    var acc: UInt8 = 0
                    var index = i
                    while index < source.count {
                        acc = acc &+ source[index]
                        index += 8191
                    }
                    target[i] = acc
                }
            }
        }
        return hash
    }

    static func currentDigest(romId: Int) -> Data? {
        guard let bytes = try? Data(contentsOf: url(romId: romId)) else { return nil }
        return digest(bytes)
    }

    // MARK: - The stamp of the server row this card came from

    private static func stampKey(_ romId: Int) -> String { "ps2-card-stamp-\(romId)" }

    private static func stamp(romId: Int) -> String? {
        UserDefaults.standard.string(forKey: stampKey(romId))
    }

    private static func setStamp(_ value: String?, romId: Int) {
        UserDefaults.standard.set(value, forKey: stampKey(romId))
    }

    /// Copies the shared Mcd001.ps2 onto one game's card.
    ///
    /// Deliberately NOT automatic. Per-game cards arrived after PS2 was
    /// already playable, so the first saves went into the shared card
    /// PCSX2 defaults to, and stranding them would be data loss. But
    /// nothing in that file says which game a save belongs to without
    /// reading its directory, so adopting it on whichever game happens
    /// to launch first would hand Burnout 3's save to Gradius V.
    ///
    /// So it is a named, one-off migration instead: copy, never move,
    /// and only onto a game with no card of its own. Run it again for
    /// another game if a save turns out to be missing; the extra
    /// folders on a card cost nothing.
    static func adoptSharedCard(romId: Int) {
        let destination = url(romId: romId)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }

        let shared = folder.appending(path: "Mcd001.ps2")
        guard FileManager.default.fileExists(atPath: shared.path) else { return }

        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: shared, to: destination)
    }
}
