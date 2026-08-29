import Foundation

/// Reads a Dreamcast VMU card image's file table, the 128KB flash format
/// every DC save this app captures already is. One question matters to
/// the app: does this card carry a GAME-type file, a minigame the game
/// downloaded onto the card, which is what the launch screen's VMU row
/// exists for. The listing is generic because answering it means walking
/// the directory anyway.
///
/// Layout, per the format itself and verified against ten real cards
/// (spikes/vmu): 256 blocks of 512 bytes. The root block is 255 and
/// starts with sixteen 0x55 format markers; it names where the FAT and
/// directory actually live rather than promising the usual places
/// (FAT at block 254, directory at 253 growing downward for 13 blocks),
/// so this follows the root's own pointers instead of assuming them.
/// Directory entries are 32 bytes: type at 0x00 (0x33 data, 0xCC game,
/// anything else unused), first block at 0x02, a 12-byte name at 0x04,
/// size in blocks at 0x18.
///
/// A card can be genuinely formatted and empty: three of the ten real
/// cards parse to zero files because those games never wrote a save
/// (their FATs allocate zero user blocks, checked 2026-08-29, the
/// "3 of 10" oddity the spike flagged, resolved not a parser gap).
enum VMUCard {
    struct File {
        let isGame: Bool
        let name: String
        let sizeBlocks: Int
    }

    static let cardSize = 128 * 1024

    /// The card's directory listing, empty for a formatted card with no
    /// saves, nil for bytes that are not a VMU card image at all.
    static func files(in card: Data) -> [File]? {
        guard card.count == cardSize else { return nil }
        let bytes = [UInt8](card)
        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        let root = 255 * 512
        guard bytes[root..<root + 16].allSatisfy({ $0 == 0x55 }) else { return nil }
        let dirLocation = u16(root + 0x4A)
        let dirSize = u16(root + 0x4C)
        guard dirLocation <= 255, dirSize > 0, dirSize <= 24 else { return nil }

        var files: [File] = []
        for i in 0..<dirSize {
            let block = dirLocation - i
            guard block >= 0 else { break }
            let base = block * 512
            for entry in 0..<16 {
                let e = base + entry * 32
                let type = bytes[e]
                guard type == 0x33 || type == 0xCC else { continue }
                let nameBytes = bytes[(e + 4)..<(e + 16)].prefix { $0 != 0 }
                let name = String(decoding: nameBytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                files.append(File(
                    isGame: type == 0xCC,
                    name: name,
                    sizeBlocks: u16(e + 0x18)
                ))
            }
        }
        return files
    }

    /// Whether a minigame is aboard: the one-line question the launch
    /// screen asks.
    static func hasMinigame(_ card: Data) -> Bool {
        files(in: card)?.contains { $0.isGame } ?? false
    }

    /// The first GAME file's name, for the row's caption. VMU games boot
    /// from block 0 and a card holds at most one, so "first" is "the".
    static func minigameName(_ card: Data) -> String? {
        files(in: card)?.first { $0.isGame }?.name
    }
}
