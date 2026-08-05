import SwiftUI

/// The launch screen. Resume first, not a library grid: the last game you
/// played, large, one tap back in. The library is a room you walk into from
/// here, not the front door.
///
/// The layout adapts to orientation rather than assuming portrait. A hero
/// sized for a tall screen fills a short one completely, hiding the rotation
/// shelf and the library entirely, so in landscape the hero becomes a wide
/// card and the rest sits beside it.
struct HomeView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var compatibility = Compatibility.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var recent: [Rom] = []
    @State private var favorites: [Rom] = []
    @State private var loaded = false
    @State private var offline = false
    @State private var resuming: Rom?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                // Nothing cached means nothing to show behind a banner, so
                // offline replaces the content rather than sitting above
                // it. Kept in a ScrollView so pull to refresh still works
                // as a second way to retry.
                if offline, recent.isEmpty, favorites.isEmpty {
                    ScrollView {
                        OfflineNotice { await load() }
                            .frame(minHeight: geometry.size.height * 0.8)
                    }
                } else if landscape {
                    // Landscape does not scroll as a page. The hero and its
                    // Resume button hold the left side still while only the
                    // rails beside them move, which is the whole point of
                    // the split: scrolling the page moved the one thing you
                    // came here to tap.
                    wideLayout(height: geometry.size.height)
                } else {
                    ScrollView { tallLayout(height: geometry.size.height) }
                }
            }
            // No large title. The tab bar already names this screen, and
            // in landscape the large title overlapped the first rail's
            // header outright. Inline keeps the bar itself, which the
            // settings button needs.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings only. The library and search moved to the tab
                // bar, where a thumb actually rests: on a large phone the
                // top trailing corner is the worst place for the two
                // things reached every session. Settings earns its place
                // here precisely because it is reached rarely.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .refreshable { await load() }
            // A game reached through Library, not Home's own resume flow,
            // has its own fullScreenCover and never touches `resuming`, so
            // the reload below never sees it close. Reappearing covers both:
            // it fires on first appearance same as `.task` would, and again
            // every time navigation brings Home back into view, favoriting
            // included.
            .onAppear { Task { await load() } }
            .fullScreenCover(item: $resuming) { rom in
                NavigationStack { GameLaunchView(rom: rom) }
            }
            .onChange(of: resuming == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
        }
    }

    // MARK: Layouts

    private func tallLayout(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if let hero = recent.first {
                heroCard(for: hero, height: portraitHeroHeight(for: height), wide: false)
                    .padding(.horizontal, 20)
                if recent.count > 1 {
                    rotationRow("Recent", Array(recent.dropFirst()), seeAll: .recentlyPlayed)
                }
            } else if loaded {
                emptyState.padding(.horizontal, 20)
            }
            if !favorites.isEmpty {
                rotationRow("Favorites", favorites, seeAll: session.favoriteCollection.map { .collection($0) })
            }
        }
        .padding(.vertical, 20)
    }

    /// Landscape: the hero takes the left, everything else stacks to its
    /// right, so nothing is pushed off a screen that is short but wide.
    private func wideLayout(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let hero = recent.first {
                heroCard(for: hero, height: max(200, height - 40), wide: true)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 20)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if recent.count > 1 {
                        rotationRow("Recent", Array(recent.dropFirst()), seeAll: .recentlyPlayed)
                    } else if loaded, recent.isEmpty {
                        emptyState.padding(.horizontal, 20)
                    }
                    if !favorites.isEmpty {
                        rotationRow(
                            "Favorites", favorites, seeAll: session.favoriteCollection.map { .collection($0) }
                        )
                    }
                }
            }
            // Bottom margin so the last row can still be scrolled fully
            // clear of the tab bar when you want to see it, even though it
            // rests underneath it.
            .contentMargins(.bottom, 80, for: .scrollContent)
            // The system's scroll edge effect tints this column's whole
            // area, not just the strip near a bar, which drew a hard
            // vertical seam down the middle of the screen where the column
            // met the hero beside it. The bars here float over content that
            // is already high contrast box art, so the effect buys nothing
            // and cost a visible join.
            .withoutScrollEdgeEffect()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.leading, 20)
        // The scrolling column runs the whole height of the screen and
        // carries on under the tab bar. Previously it was only as tall as
        // the hero beside it, so rows were sliced against the column's own
        // invisible bottom edge with dead white space below, which looked
        // broken rather than layered. Reaching the bottom also gives the
        // bar something to sit over, which is the only way its material
        // ever shows: glass over nothing just renders as a white pill.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Pieces

    @ViewBuilder
    private func heroArtwork(for rom: Rom, contentMode: ContentMode) -> some View {
        if let frame = LastFrame.image(romId: rom.id) {
            Image(uiImage: frame)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            CoverImage(
                path: rom.pathCoverLarge ?? rom.pathCoverSmall,
                title: rom.displayName,
                contentMode: contentMode
            )
        }
    }

    /// Portrait's hero takes a share of the screen rather than a fixed 360
    /// points, which dominated a small phone and looked timid on a large
    /// one. Bounded at both ends, and deliberately short of half the
    /// screen so the first rail still shows: Home is meant to say "resume
    /// this, and here is what else is around", and a hero filling the
    /// whole screen only says the first half.
    private func portraitHeroHeight(for available: CGFloat) -> CGFloat {
        min(max(available * 0.45, 280), 460)
    }

    private func heroCard(for rom: Rom, height: CGFloat, wide: Bool) -> some View {
        Button {
            resuming = rom
        } label: {
            // The frame you left on, when the player has recorded one, per
            // the scope doc's Home. Box art is the fallback, not the point:
            // the hero is your game mid-moment, inviting you back into it.
            //
            // Fitted over a blurred copy of itself rather than cropped to
            // fill. A captured frame is wide and box art is tall, so any
            // single card shape has to butcher one of them: filling this
            // one sliced a 4:3 game frame down to a narrow vertical strip
            // of its middle, which is the opposite of showing someone the
            // moment they left. Fitting shows all of it, and the blurred
            // backdrop fills the leftovers with the game's own colours
            // instead of letterbox bars.
            heroArtwork(for: rom, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                // A background rather than a ZStack layer. Stacked, the
                // filled copy is greedy about size and grew the whole card
                // past the edge of the screen; as a background it is sized
                // by the card instead of the other way round.
                .background {
                    heroArtwork(for: rom, contentMode: .fill)
                        .blur(radius: 20)
                        .overlay(Color.black.opacity(0.15))
                        .clipped()
                }
                .clipped()
                // A frosted band, not a black gradient. The gradient was
                // painting over the very backdrop that makes this card
                // worth looking at, leaving a slab of black under the
                // artwork. A material keeps the game's colours showing
                // through while still giving the text a surface it can be
                // read against, and it matches the Resume pill, which is
                // already the same material.
                .overlay(alignment: .bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rom.displayName)
                                .font(wide ? .headline : .title3.bold())
                                .lineLimit(1)
                            Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                                .font(wide ? .caption : .subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, wide ? 12 : 16)
                    .padding(.vertical, wide ? 10 : 12)
                    .frame(maxWidth: .infinity)
                    .background(.regularMaterial)
                }
                .overlay(alignment: .topTrailing) {
                    Label("Resume", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(12)
                }
                .clipShape(.rect(cornerRadius: 18))
                .shadow(radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }

    /// `seeAll` is the full list this rail is a preview of. Nil only
    /// transiently, before that destination has finished loading (the
    /// favorite collection isn't known until the first fetch lands), in
    /// which case the header is a plain label rather than a broken link.
    private func rotationRow(_ title: String, _ roms: [Rom], seeAll: RomListView.Source?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let seeAll {
                NavigationLink {
                    RomListView(source: seeAll)
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            } else {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 20)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(roms) { rom in
                        Button {
                            resuming = rom
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                    .frame(width: 100, height: 133)
                                    .clipShape(.rect(cornerRadius: 10))
                                    .compatibilityBadge(romId: rom.id, compact: true)
                                    .favoriteBadge(romId: rom.id, compact: true)
                                Text(rom.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                                    .foregroundStyle(
                                        compatibility.isMarked(rom.id) ? .secondary : .primary
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .gameContextMenu(romId: rom.id)
                    }
                }
            }
            // Covers dissolve at the rail's leading edge rather than being
            // sliced in half by it. A screen edge is a boundary the eye
            // accepts without help, which is why Apple's own rails clip
            // hard, but in landscape this edge sits in the middle of the
            // screen with the hero beside it, and a clean vertical cut
            // there reads as a rendering fault. The mask covers only the
            // scrolling covers: fading the headers too would look like the
            // text itself was broken.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing on the go yet")
                .font(.title3.bold())
            Text("Pick a game from the library. Whatever you play last shows up here for one tap resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Only the recents call decides whether this reads as offline: it is
    /// the one every account makes, where favorites is empty for plenty of
    /// people legitimately. A failure that is not a connection problem
    /// keeps the old quiet behaviour, since Home has no good place to put
    /// a server side error and the library screen will explain it properly
    /// the moment they go looking.
    private func load() async {
        do {
            recent = try await session.recentlyPlayed().items
            offline = false
        } catch RommError.offline {
            offline = true
        } catch {
            // Left as is on purpose, see above.
        }
        if let favs = try? await session.favoriteRoms() {
            favorites = favs
        }
        loaded = true
    }
}

private extension View {
    /// iOS 26 only, so it goes through here rather than putting an
    /// availability check in the middle of the layout.
    @ViewBuilder
    func withoutScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden()
        } else {
            self
        }
    }
}
