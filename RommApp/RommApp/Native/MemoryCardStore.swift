import Foundation

/// Local persistence for battery saves: the save image a native core
/// exposes as RETRO_MEMORY_SAVE_RAM (a PS1 memory card, a cartridge
/// battery, Saturn's internal backup RAM), kept on disk between sessions
/// and mirrored to RomM's /api/saves. Dreamcast's VMU file rides the
/// same store even though the core hands it over as a file.
///
/// A game can carry a second, much smaller region alongside the save
/// RAM: the Game Boy real-time clock, stored as its own `.rtc` file next
/// to the `.srm` so each round-trips independently, the same file split
/// RetroArch uses.
///
/// The disk copy is written first on every snapshot, before any upload is
/// attempted, the same guarantee the state queue makes: losing signal must
/// never mean losing an in-game save. A card whose upload has not yet
/// succeeded carries a pending flag and is retried at the next launch.
final class MemoryCardStore {
    static let shared = MemoryCardStore()

    /// Which persisted region a call is about. `.saveRAM` is the default
    /// everywhere so every caller written when the card was the only
    /// region reads unchanged.
    enum Region: String {
        case saveRAM = "srm"
        case rtc
    }

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

    private func cardURL(romId: Int, region: Region) -> URL {
        directory.appendingPathComponent("rom_\(romId).\(region.rawValue)")
    }

    /// Save RAM keeps the bare rom id it always had, so every card
    /// already on a device stays recognized; other regions suffix it.
    private func metaKey(romId: Int, region: Region) -> String {
        region == .saveRAM ? String(romId) : "\(romId).\(region.rawValue)"
    }

    private func persistMeta() {
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    func localCard(romId: Int, region: Region = .saveRAM) -> Data? {
        try? Data(contentsOf: cardURL(romId: romId, region: region))
    }

    func pendingUpload(romId: Int, region: Region = .saveRAM) -> Bool {
        meta[metaKey(romId: romId, region: region)]?.pendingUpload ?? false
    }

    func serverStamp(romId: Int, region: Region = .saveRAM) -> String? {
        meta[metaKey(romId: romId, region: region)]?.serverStamp
    }

    /// A fresh snapshot from the core: written to disk immediately and
    /// flagged pending until an upload confirms.
    func storeSnapshot(romId: Int, data: Data, region: Region = .saveRAM) {
        try? data.write(to: cardURL(romId: romId, region: region), options: .atomic)
        meta[metaKey(romId: romId, region: region), default: Meta(serverStamp: nil, pendingUpload: false)].pendingUpload = true
        persistMeta()
    }

    /// A card downloaded from the server: the local copy now matches the
    /// server's, nothing pending.
    func storeDownloaded(romId: Int, data: Data, serverStamp: String?, region: Region = .saveRAM) {
        try? data.write(to: cardURL(romId: romId, region: region), options: .atomic)
        meta[metaKey(romId: romId, region: region)] = Meta(serverStamp: serverStamp, pendingUpload: false)
        persistMeta()
    }

    func markUploaded(romId: Int, serverStamp: String?, region: Region = .saveRAM) {
        meta[metaKey(romId: romId, region: region)] = Meta(serverStamp: serverStamp, pendingUpload: false)
        persistMeta()
    }

    /// Whether a card image holds any actual saves, as opposed to a
    /// freshly formatted or factory-erased region. Lives here, not in a
    /// player view, because keep-time prefetch and both players' launch
    /// syncs all need the same answer; the check drifting apart between
    /// them is how a junk card ends up outranking a real one.
    ///
    /// PS1's 128KB card has a real directory format worth checking:
    /// frames 1-15 carry 0x51/0x52/0x53 in their first byte for in-use
    /// blocks (the PS1 spec's block allocation states). Saturn's backup
    /// RAM starts with a repeating "BackUpRam Format" text header the
    /// core writes when formatting fresh memory, so real saves are
    /// judged past the 64-byte header. Everything else has no directory
    /// to check and varies in size by cartridge, so the only signal is
    /// whether the bytes look like an erase pattern: unused save memory
    /// is uniformly 0x00 or 0xFF, while any real save carries structure
    /// that is neither.
    static func cardHasSaves(_ card: Data, platform: NativePlatform) -> Bool {
        switch platform {
        case .psx:
            guard card.count == 128 * 1024 else { return false }
            return (1...15).contains { block in
                [0x51, 0x52, 0x53].contains(Int(card[128 * block]))
            }
        case .saturn:
            guard card.count > 64 else { return false }
            return card.dropFirst(64).contains { $0 != 0x00 && $0 != 0xFF }
        default:
            return card.contains { $0 != 0x00 && $0 != 0xFF }
        }
    }

}
