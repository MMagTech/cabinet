import CoreGraphics
import Foundation
import ImageIO

/// The Vectrex screen overlays: every retail cartridge shipped with a
/// translucent colored sheet that slotted in front of the console's
/// monochrome vector CRT, tinting regions of the picture, carrying the
/// printed art and control legend the game itself never drew, and
/// softening the beam's flicker. This resolves which sheet belongs to a
/// game and hands its image to the renderer, which composites it over
/// the picture the way the real plastic sat over the real tube.
///
/// Matching is by content, not filename: RomM's own md5 for the rom is
/// the primary key, so a weirdly named file still gets its sheet, with a
/// normalized name-token fallback for dumps the table has never seen.
/// Resolution picks the row whose matched token is longest, and a
/// winning row marked non-historical renders nothing: that is both how
/// the invented sheets (prototypes, the 3D Imager games) stay off by
/// default and how "3D Mine Storm" is stopped from borrowing plain
/// Mine Storm's sheet by name. The table lives in
/// Resources/VectrexOverlays/vectrex-overlays.json, data not code, the
/// same philosophy as the control layouts.
enum VectrexOverlays {
    /// The Settings toggle, stored and exposed through the same
    /// per-platform option plumbing as everything else on the Vectrex
    /// settings page. The "cabinet_" prefix marks it as this app's own:
    /// it rides along in the core options dictionary, where vecx simply
    /// never asks for it, because GET_VARIABLE only answers questions
    /// the core poses.
    static let optionKey = "cabinet_vectrex_overlay"

    static var isEnabled: Bool {
        guard let option = NativeCoreOptions.options(for: .vectrex)
            .first(where: { $0.key == optionKey })
        else { return true }
        return NativeCoreOptionsStore.value(option, for: .vectrex) == "enabled"
    }

    private struct Table: Decodable {
        let overlays: [Row]
    }

    private struct Row: Decodable {
        let file: String
        let historical: Bool
        let md5: [String]
        let match: [String]
    }

    private static let rows: [Row] = {
        guard let url = Bundle.main.url(forResource: "vectrex-overlays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode(Table.self, from: data)
        else { return [] }
        return table.overlays
    }()

    /// Lowercased, punctuation collapsed to single spaces, so "Armor..
    /// Attack (World)" and "armor attack world" agree.
    private static func normalized(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// The sheet for a game, nil when none should draw: the toggle is
    /// off, nothing matches, or the best match is a sheet that never
    /// historically existed.
    static func image(md5: String?, name: String) -> CGImage? {
        guard isEnabled else { return nil }
        var winner: Row?
        if let md5 = md5?.lowercased(), !md5.isEmpty,
           let hit = rows.first(where: { $0.md5.contains(md5) }) {
            winner = hit
        } else {
            let haystack = normalized(name)
            var bestLength = 0
            for row in rows {
                for token in row.match where haystack.contains(token) && token.count > bestLength {
                    winner = row
                    bestLength = token.count
                }
            }
        }
        guard let winner, winner.historical else { return nil }
        return loadImage(named: winner.file)
    }

    private static func loadImage(named file: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: file, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
