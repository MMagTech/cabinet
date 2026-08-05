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
                ScrollView {
                    // Nothing cached means nothing to show behind a banner,
                    // so offline replaces the content rather than sitting
                    // above it. Kept inside the ScrollView so pull to
                    // refresh still works as a second way to retry.
                    if offline, recent.isEmpty, favorites.isEmpty {
                        OfflineNotice { await load() }
                            .frame(minHeight: geometry.size.height * 0.8)
                    } else if landscape {
                        wideLayout(height: geometry.size.height)
                    } else {
                        tallLayout
                    }
                }
            }
            .navigationTitle("Home")
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

    private var tallLayout: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let hero = recent.first {
                heroCard(for: hero, height: 360, wide: false)
                if recent.count > 1 {
                    rotationRow("Recent", Array(recent.dropFirst()), seeAll: .recentlyPlayed)
                }
            } else if loaded {
                emptyState
            }
            if !favorites.isEmpty {
                rotationRow("Favorites", favorites, seeAll: session.favoriteCollection.map { .collection($0) })
            }
        }
        .padding(20)
    }

    /// Landscape: the hero takes the left, everything else stacks to its
    /// right, so nothing is pushed off a screen that is short but wide.
    private func wideLayout(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let hero = recent.first {
                heroCard(for: hero, height: max(200, height - 40), wide: true)
                    .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 20) {
                if recent.count > 1 {
                    rotationRow("Recent", Array(recent.dropFirst()), seeAll: .recentlyPlayed)
                } else if loaded, recent.isEmpty {
                    emptyState
                }
                if !favorites.isEmpty {
                    rotationRow("Favorites", favorites, seeAll: session.favoriteCollection.map { .collection($0) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    // MARK: Pieces

    private func heroCard(for rom: Rom, height: CGFloat, wide: Bool) -> some View {
        Button {
            resuming = rom
        } label: {
            // The frame you left on, when the player has recorded one, per
            // the scope doc's Home. Box art is the fallback, not the point:
            // the hero is your game mid-moment, inviting you back into it.
            Group {
                if let frame = LastFrame.image(romId: rom.id) {
                    Image(uiImage: frame)
                        .resizable()
                } else {
                    CoverImage(
                        path: rom.pathCoverLarge ?? rom.pathCoverSmall,
                        title: rom.displayName
                    )
                }
            }
                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(rom.displayName)
                            .font(wide ? .headline : .title2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                            .font(wide ? .caption : .subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(wide ? 12 : 16)
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
            } else {
                Text(title)
                    .font(.headline)
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
