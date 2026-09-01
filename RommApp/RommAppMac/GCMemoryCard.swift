//  One memory card per GameCube game, synced to RomM.
//
//  Dolphin ships the hardware's own arrangement: a single card in slot
//  A that every game writes into. That is authentic and it is wrong for
//  Cabinet, because RomM stores saves against a rom and a shared card
//  belongs to no rom in particular. It would also mean every machine
//  had to agree on one ever-growing file. So each game gets its own,
//  which is what Cabinet already does for PS1 and PS2.
//
//  Deliberately a sibling of PS2MemoryCard rather than a generalisation
//  of it. The two share a shape, not behaviour: the formats differ, the
//  emulator tags differ, and PS2's carries a one-off migration off
//  PCSX2's shared Mcd001 that has no GameCube equivalent. Merging them
//  would mean a file with two of everything and a flag to pick.
//
//  The rule that matters, from the arcade NVRAM work: the emulator tag
//  goes in the RomM row, or two emulators' uploads overwrite each other.
//
//  Dolphin's default card is 16 MB, twice PS2's 8 MB, so this hashes on
//  a stride the way PS2 does rather than reading every byte. Measured
//  against a real card rather than assumed: the 512 KB figure a
//  GameCube card is usually quoted at is the smallest one the hardware
//  shipped, not what an emulator creates.

import Foundation

enum GCMemoryCard {
    /// The tag RomM files these under. Dolphin rather than Cabinet,
    /// because the format is Dolphin's and another Dolphin could read
    /// it.
    static let emulatorTag = "dolphin"

    static var folder: URL {
        GCPlayer.dataRoot.appending(path: "memcards")
    }

    /// The path handed to Dolphin. A full path, unlike PCSX2, which
    /// wants a bare filename it resolves inside its own folder.
    ///
    /// NOTE that this is NOT the file that ends up on disk. Dolphin
    /// inserts the game's region before the extension, so asking for
    /// `cabinet-930.raw` produces `cabinet-930.USA.raw`. Nothing says
    /// so; it was found by looking at the folder after a run, and a
    /// sync built on the requested name would have uploaded nothing,
    /// silently, forever. Use `resolvedURL` for anything that reads the
    /// card.
    static func url(romId: Int) -> URL {
        folder.appending(path: fileName(romId: romId))
    }

    /// .raw is Dolphin's own extension for a whole-card image, as
    /// opposed to the .gci files that hold one save each.
    static func fileName(romId: Int) -> String {
        "cabinet-\(romId).raw"
    }

    /// The card that actually exists on disk for this game, whatever
    /// region Dolphin decided to stamp into its name. Newest wins if a
    /// game has somehow been run under two regions.
    static func resolvedURL(romId: Int) -> URL? {
        let prefix = "cabinet-\(romId)."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let mine = names.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".raw") }
        guard !mine.isEmpty else { return nil }
        let urls = mine.map { folder.appending(path: $0) }
        return urls.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
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

        // Written back under the name RomM has, not the name Cabinet
        // would have asked Dolphin for, because the name RomM has is the
        // region-stamped one this game actually uses. That keeps the
        // round trip consistent on a machine that has never run the game
        // and so has no way to know its region yet.
        let name = newest.fileName.hasPrefix("cabinet-\(rom.id).") && newest.fileName.hasSuffix(".raw")
            ? newest.fileName
            : fileName(romId: rom.id)
        let local = folder.appending(path: name)

        guard newest.updatedAt != stamp(romId: rom.id)
                || !FileManager.default.fileExists(atPath: local.path)
        else { return }
        guard let bytes = try? await session.saveContent(newest), !bytes.isEmpty else { return }

        try? bytes.write(to: local)
        setStamp(newest.updatedAt, romId: rom.id)
    }

    /// Uploads the card if it changed while the game ran. Compared by
    /// content rather than by modification date, because an emulator
    /// rewrites the file on shutdown whether a game saved or not.
    static func store(rom: Rom, session: Session, since digestBefore: Data?) async {
        guard let local = resolvedURL(romId: rom.id),
              let bytes = try? Data(contentsOf: local), !bytes.isEmpty
        else { return }

        // Unchanged is only a reason to skip if the server already has
        // this card. A card that has never been uploaded looks exactly
        // like one that is safely stored, and staying quiet about it
        // means a save can sit on one machine forever believing it
        // synced. PS2 documents the same trap for the same reason.
        let neverUploaded = stamp(romId: rom.id) == nil
        guard neverUploaded || digest(bytes) != digestBefore else { return }

        do {
            try await session.uploadSave(
                romId: rom.id,
                emulator: emulatorTag,
                // The RESOLVED name, so a restore on another machine
                // writes back the file Dolphin will actually open.
                fileName: local.lastPathComponent,
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

    /// A content fingerprint, taken before a game runs so the upload
    /// afterwards can tell whether anything actually changed.
    ///
    /// Strided rather than a full hash, like PS2's, because the card is
    /// 16 MB and this runs twice per launch. The stride is far tighter
    /// than PS2's (32 bytes against 8191) and mixes the index in, so a
    /// single changed block cannot cancel itself out: a card is mostly
    /// empty space, and a digest that only samples widely would miss a
    /// save landing in one block.
    static func digest(_ data: Data) -> Data {
        var hash = Data(count: 32)
        data.withUnsafeBytes { raw in
            hash.withUnsafeMutableBytes { out in
                let source = raw.bindMemory(to: UInt8.self)
                let target = out.bindMemory(to: UInt8.self)
                for i in 0..<32 {
                    var acc: UInt8 = 0
                    var index = i
                    while index < source.count {
                        acc = acc &+ source[index] &+ UInt8(truncatingIfNeeded: index)
                        index += 32
                    }
                    target[i] = acc
                }
            }
        }
        return hash
    }

    static func currentDigest(romId: Int) -> Data? {
        guard let local = resolvedURL(romId: romId),
              let bytes = try? Data(contentsOf: local)
        else { return nil }
        return digest(bytes)
    }

    // MARK: - The stamp of the server row this card came from

    private static func stampKey(_ romId: Int) -> String { "gc-card-stamp-\(romId)" }

    private static func stamp(romId: Int) -> String? {
        UserDefaults.standard.string(forKey: stampKey(romId))
    }

    private static func setStamp(_ value: String?, romId: Int) {
        UserDefaults.standard.set(value, forKey: stampKey(romId))
    }
}
