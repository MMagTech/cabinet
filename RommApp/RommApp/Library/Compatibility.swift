import SwiftUI

/// Which games do not work on this phone, and what the app has noticed.
///
/// Some games simply do not survive here. CV1000 boards run at a fraction
/// of speed because iOS forbids the core's dynarec, and a game can be
/// perfectly emulated and still no fun to play. None of that is knowable
/// from RomM, which models a library rather than a device, and none of it
/// is true of the library generally: the same ROM may be fine on a
/// desktop. So the mark is local, per device, and per ROM.
///
/// Two things feed it. Someone can say so directly, which covers judgement
/// the app cannot make, like a game being technically fine and too slow to
/// enjoy. And the player counts how often each game's web process died,
/// because after the third or fourth time that is evidence worth offering
/// rather than a thing to keep quiet about.
///
/// An object rather than a namespace of statics so that marking a game
/// redraws every shelf and list showing it. Defaults are not observable,
/// and a view reading them has no way to know they changed.
@MainActor
final class Compatibility: ObservableObject {
    static let shared = Compatibility()

    private let markedKey = "com.mmagtech.RommApp.markedUnplayable"

    @Published private(set) var marked: Set<Int>

    private init() {
        marked = Set(UserDefaults.standard.array(forKey: markedKey) as? [Int] ?? [])
    }

    func isMarked(_ romId: Int) -> Bool { marked.contains(romId) }

    func setMarked(_ isMarked: Bool, romId: Int) {
        if isMarked { marked.insert(romId) } else { marked.remove(romId) }
        UserDefaults.standard.set(Array(marked), forKey: markedKey)
    }

    // MARK: What the app noticed

    private func crashKey(_ romId: Int) -> String {
        "com.mmagtech.RommApp.crashes.\(romId)"
    }

    func recordCrash(romId: Int) {
        UserDefaults.standard.set(crashes(romId: romId) + 1, forKey: crashKey(romId))
    }

    func crashes(romId: Int) -> Int {
        UserDefaults.standard.integer(forKey: crashKey(romId))
    }

    /// Enough deaths to be worth mentioning, and not already marked. Three
    /// is the threshold because one is bad luck and two is a coincidence.
    func shouldSuggestMark(romId: Int) -> Bool {
        !isMarked(romId) && crashes(romId: romId) >= 3
    }

    // MARK: Native player crashes

    /// Counted separately from webview crashes on purpose: webview counts
    /// push a game's default toward the native player, so a native core
    /// that also dies on that game must be able to push back, or a bad
    /// game gets locked into whichever player failed second.
    private func nativeCrashKey(_ romId: Int) -> String {
        "com.mmagtech.RommApp.nativeCrashes.\(romId)"
    }

    func recordNativeCrash(romId: Int) {
        UserDefaults.standard.set(nativeCrashes(romId: romId) + 1, forKey: nativeCrashKey(romId))
    }

    func nativeCrashes(romId: Int) -> Int {
        UserDefaults.standard.integer(forKey: nativeCrashKey(romId))
    }
}

/// Dims a cover and badges it when the game is marked.
///
/// Grayscale plus a lowered opacity is how iOS says unavailable, and it
/// survives any cover art; a badge alone would vanish into a busy one. The
/// badge sits on a material circle for the same reason.
private struct CompatibilityBadge: ViewModifier {
    @ObservedObject private var compatibility = Compatibility.shared
    let romId: Int
    /// Badges scale with their tile: a 100 point shelf cover and a full
    /// width grid cell should not carry the same size glyph.
    var compact = false

    func body(content: Content) -> some View {
        let marked = compatibility.isMarked(romId)
        return content
            .grayscale(marked ? 0.85 : 0)
            .opacity(marked ? 0.55 : 1)
            .overlay(alignment: .topTrailing) {
                if marked {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(compact ? .caption2 : .footnote)
                        .foregroundStyle(.orange)
                        .padding(compact ? 4 : 6)
                        .background(.regularMaterial, in: .circle)
                        .padding(compact ? 4 : 6)
                }
            }
    }
}

/// A star in the corner opposite the compatibility badge, shown only when
/// the game is favorited. Reads at a glance in a grid without opening
/// anything, the same job the compatibility triangle does for the other
/// question a cover alone cannot answer.
private struct FavoriteBadge: ViewModifier {
    @EnvironmentObject private var session: Session
    let romId: Int
    var compact = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if session.isFavorite(romId: romId) {
                Image(systemName: "star.fill")
                    .font(compact ? .caption2 : .footnote)
                    .foregroundStyle(.yellow)
                    .padding(compact ? 4 : 6)
                    .background(.regularMaterial, in: .circle)
                    .padding(compact ? 4 : 6)
            }
        }
    }
}

/// The long press menu, used everywhere a game can be tapped. A press
/// rather than a swipe because a cover grid has no swipe to give, and one
/// gesture across both views is worth more than the better gesture in one
/// of them. Favoriting lives in the same menu rather than its own: two
/// long-press menus on one view do not merge, the second silently wins, so
/// every question a list can't otherwise answer without opening the game
/// belongs in this one place.
private struct GameContextMenu: ViewModifier {
    @ObservedObject private var compatibility = Compatibility.shared
    @EnvironmentObject private var session: Session
    let romId: Int

    func body(content: Content) -> some View {
        let marked = compatibility.isMarked(romId)
        let favorited = session.isFavorite(romId: romId)
        return content.contextMenu {
            Button {
                Task { try? await session.toggleFavorite(romId: romId) }
            } label: {
                Label(
                    favorited ? "Unfavorite" : "Favorite",
                    systemImage: favorited ? "star.slash" : "star"
                )
            }
            Button {
                compatibility.setMarked(!marked, romId: romId)
            } label: {
                Label(
                    marked ? "Compatible" : "Incompatible",
                    systemImage: marked ? "checkmark.circle" : "exclamationmark.triangle"
                )
            }
        }
    }
}

extension View {
    func compatibilityBadge(romId: Int, compact: Bool = false) -> some View {
        modifier(CompatibilityBadge(romId: romId, compact: compact))
    }

    func favoriteBadge(romId: Int, compact: Bool = false) -> some View {
        modifier(FavoriteBadge(romId: romId, compact: compact))
    }

    func gameContextMenu(romId: Int) -> some View {
        modifier(GameContextMenu(romId: romId))
    }
}
