import Foundation

/// Local persistence for battery saves, PS1 memory cards being the first
/// and so far only kind: the card image a native core exposes as
/// RETRO_MEMORY_SAVE_RAM, kept on disk between sessions and mirrored to
/// RomM's /api/saves.
///
/// The disk copy is written first on every snapshot, before any upload is
/// attempted, the same guarantee the state queue makes: losing signal must
/// never mean losing an in-game save. A card whose upload has not yet
/// succeeded carries a pending flag and is retried at the next launch.
final class MemoryCardStore {
    static let shared = MemoryCardStore()

    private struct Meta: Codable {
        /// The server save's updated_at from the last successful sync, so
        /// launch can tell a genuinely newer server card from the one this
        /// device already has.
        var serverStamp: String?
        var pendingUpload: Bool
    }

    private let directory: URL
    private let metaURL: URL
    private var meta: [String: Meta]

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("MemoryCards", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaURL = directory.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let decoded = try? JSONDecoder().decode([String: Meta].self, from: data) {
            meta = decoded
        } else {
            meta = [:]
        }
    }

    private func cardURL(romId: Int) -> URL {
        directory.appendingPathComponent("rom_\(romId).srm")
    }

    private func persistMeta() {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    func localCard(romId: Int) -> Data? {
        try? Data(contentsOf: cardURL(romId: romId))
    }

    func pendingUpload(romId: Int) -> Bool {
        meta[String(romId)]?.pendingUpload ?? false
    }

    func serverStamp(romId: Int) -> String? {
        meta[String(romId)]?.serverStamp
    }

    /// A fresh snapshot from the core: written to disk immediately and
    /// flagged pending until an upload confirms.
    func storeSnapshot(romId: Int, data: Data) {
        try? data.write(to: cardURL(romId: romId), options: .atomic)
        meta[String(romId), default: Meta(serverStamp: nil, pendingUpload: false)].pendingUpload = true
        persistMeta()
    }

    /// A card downloaded from the server: the local copy now matches the
    /// server's, nothing pending.
    func storeDownloaded(romId: Int, data: Data, serverStamp: String?) {
        try? data.write(to: cardURL(romId: romId), options: .atomic)
        meta[String(romId)] = Meta(serverStamp: serverStamp, pendingUpload: false)
        persistMeta()
    }

    func markUploaded(romId: Int, serverStamp: String?) {
        meta[String(romId)] = Meta(serverStamp: serverStamp, pendingUpload: false)
        persistMeta()
    }
}
