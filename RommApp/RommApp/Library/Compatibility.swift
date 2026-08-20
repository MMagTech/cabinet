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
/// A badge and a light opacity drop is how this reads as set aside, and it
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
            // Receding, not disabled. Draining the colour out of cover art
            // says the game is dead, which contradicts the only thing this
            // mark actually means: it still plays, someone just decided it
            // plays badly here. iOS dims controls that cannot be used; it
            // does not desaturate content that works. The badge carries the
            // meaning, and a light touch of opacity is enough to let a
            // marked tile fall behind its neighbours at a glance.
            .opacity(marked ? 0.72 : 1)
            .overlay(alignment: .topTrailing) {
                if marked {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(compact ? .caption2 : .footnote)
                        // Muted rather than full orange. This sits on top
                        // of cover art, where a fully saturated warning
                        // colour competes with the artwork instead of
                        // annotating it, and the badge only has to be
                        // noticed, not obeyed.
                        .foregroundStyle(.orange.opacity(0.7))
                        // Sit the triangle so its three corners are the
                        // same distance from the ring, which is what the
                        // eye is actually measuring here.
                        //
                        // A glyph is centred by its bounding box, but an
                        // equilateral triangle's circumcentre, the point
                        // its corners are equidistant from, is a sixth of
                        // the triangle's height BELOW that box's centre.
                        // So box centring parks the corners off by exactly
                        // that much, and the correction is up by h/6.
                        .offset(y: compact ? -1.5 : -2)
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
                    // Same idea as the warning triangle next door, much
                    // smaller correction. A five pointed star's box is
                    // bounded above by one point and below by two, so its
                    // centre sits just under the box's, and box centring
                    // leaves the points unevenly spaced from the ring by
                    // about a twentieth of the glyph rather than a sixth.
                    .offset(y: compact ? -0.5 : -0.75)
                    .padding(compact ? 4 : 6)
                    .background(.regularMaterial, in: .circle)
                    .padding(compact ? 4 : 6)
            }
        }
    }
}

/// A small ring wherever a badge or an inline icon already lives,
/// visible only while `KeptGameStore` actually has this game
/// downloading, gone the instant it finishes or fails. Bound to the
/// real byte progress, not a spinner, the same determinate-ring idiom
/// the App Store uses on its own icons; this app already speaks that
/// idiom for loading state everywhere else (a dimmed area with a
/// centered `ProgressView`), so a real percentage here is a natural
/// extension of it, not a new pattern. Deliberately not a permanent
/// "kept" badge once the download finishes: that state already lives
/// in Storage, and restating it on every cover forever would be one
/// more thing this app was trying all day to stop doing.
private struct DownloadProgressRing: View {
    @ObservedObject private var keptStore = KeptGameStore.shared
    let romId: Int

    var body: some View {
        if let progress = keptStore.downloading[romId] {
            ProgressView(value: min(progress.fraction, 1))
                .progressViewStyle(.circular)
                .controlSize(.mini)
        }
    }
}

/// The long press menu, used everywhere a game can be tapped. A press
/// rather than a swipe because a cover grid has no swipe to give, and one
/// gesture across both views is worth more than the better gesture in one
/// of them. Favoriting lives in the same menu rather than its own: two
/// long-press menus on one view do not merge, the second silently wins, so
/// every question a list can't otherwise answer without opening the game
/// belongs in this one place. Download joined it the same way: deciding to
/// keep a game used to mean opening its full launch screen for one toggle.
private struct GameContextMenu: ViewModifier {
    @ObservedObject private var compatibility = Compatibility.shared
    @ObservedObject private var keptStore = KeptGameStore.shared
    @EnvironmentObject private var session: Session
    let rom: Rom

    func body(content: Content) -> some View {
        let romId = rom.id
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
            // Same eligibility as the launch screen's Storage card, same
            // underlying calls: this is a second door, not a second
            // mechanism. Three labels, not two, since this menu has no
            // companion caption line the way the launch screen's toggle
            // does to explain an in-progress download on its own.
            if KeptGameStore.isKeepable(
                rom, canonicalSlug: rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
            ) {
                if keptStore.downloading[romId] != nil {
                    Button {
                        keptStore.remove(romId: romId)
                    } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                } else if keptStore.kept(romId: romId) != nil {
                    Button {
                        keptStore.remove(romId: romId)
                    } label: {
                        Label("Remove Download", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        keptStore.keep(rom: rom, session: session)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
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

    /// A small ring badge, matching `compatibilityBadge`/`favoriteBadge`'s
    /// own corner-circle styling, visible only while this game is
    /// actively downloading. The bottom-trailing corner is free:
    /// favorite already owns top-leading and compatibility top-trailing,
    /// and a game can genuinely be both marked incompatible and worth
    /// keeping for another emulator at once, so this needs its own
    /// corner rather than risking a collision with either.
    func downloadBadge(romId: Int, compact: Bool = false) -> some View {
        overlay(alignment: .bottomTrailing) {
            if KeptGameStore.shared.downloading[romId] != nil {
                DownloadProgressRing(romId: romId)
                    .padding(compact ? 4 : 6)
                    .background(.regularMaterial, in: .circle)
                    .padding(compact ? 4 : 6)
            }
        }
    }

    func gameContextMenu(rom: Rom) -> some View {
        modifier(GameContextMenu(rom: rom))
    }
}
