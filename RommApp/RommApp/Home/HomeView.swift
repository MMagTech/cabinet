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
    @State private var directLaunch: DirectLaunch?
    @State private var preparingResume = false
    @ObservedObject private var quickActions = QuickActionRouter.shared
    @State private var quickPushRecents = false
    @State private var quickPushFavorites = false

    /// Everything the player needs to start without the launch screen in
    /// front of it. Identifiable so it can drive a `fullScreenCover` the
    /// same way `resuming` does.
    private struct DirectLaunch: Identifiable {
        let id = UUID()
        let rom: Rom
        let choices: LaunchChoices
        let resumeFromAutosave: Bool
        let stateToLoad: PlayerView.StateToLoad?
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                // Nothing cached means nothing to show behind a banner, so
                // offline replaces the content rather than sitting above
                // it. Kept in a ScrollView so pull to refresh still works
                // as a second way to retry.
                if offline, recent.isEmpty, favorites.isEmpty {
                    // Nothing cached to show above a banner, same as
                    // before, but there may be something better: any
                    // kept, native-capable game plays with zero
                    // connection, so resume-first still has an honest
                    // answer offline whenever one exists.
                    if !offlineKeptGames.isEmpty {
                        offlineKeptList
                    } else {
                        ScrollView {
                            OfflineNotice { await load() }
                                .frame(minHeight: geometry.size.height * 0.8)
                        }
                    }
                } else if !loaded, recent.isEmpty, favorites.isEmpty {
                    // Something, anything, while the first load runs. This
                    // screen used to render nothing at all until the answer
                    // arrived, so a slow or failing connection looked like a
                    // hung app rather than one waiting on a server.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .fullScreenCover(item: $directLaunch) { launch in
                PlayerView(
                    rom: launch.rom,
                    launch: launch.choices,
                    resumeFromAutosave: launch.resumeFromAutosave,
                    stateToLoad: launch.stateToLoad
                )
            }
            .onChange(of: resuming == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            .onChange(of: directLaunch == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            // Home's share of a quick action, taken when, and only when,
            // this screen can actually act on it: resume needs the recents
            // fetch to have landed, favorites needs the collection known.
            // Checked on every signal that could newly make one possible,
            // since a cold start sets the action before any of them.
            .onChange(of: quickActions.pending) { _, _ in consumeQuickAction() }
            .onChange(of: loaded) { _, _ in consumeQuickAction() }
            .onChange(of: session.favoriteCollection) { _, _ in consumeQuickAction() }
            .onAppear { consumeQuickAction() }
            .navigationDestination(isPresented: $quickPushRecents) {
                RomListView(source: .recentlyPlayed)
            }
            .navigationDestination(isPresented: $quickPushFavorites) {
                if let favorites = session.favoriteCollection {
                    RomListView(source: .collection(favorites))
                }
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

    /// Every kept game that can actually play with no connection.
    /// Webview-only kept games are left out on purpose: their player is
    /// a page from the server, so listing them here would set up a tap
    /// that fails, the exact silent-spinner problem this pass exists to
    /// remove, just relocated to Home.
    private var offlineKeptGames: [Rom] {
        KeptGameStore.shared.games
            .filter { NativeCore.core(for: $0.rom) != nil }
            .map(\.rom)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Offline's version of resume-first: not one tile for whichever
    /// game happened to be recent the last time there was a signal, but
    /// every kept game, since any of them can genuinely play right now.
    /// A quiet label instead of the full `OfflineNotice`, which is built
    /// for the moment there is nothing else on screen; here there is,
    /// and the heavier treatment would only compete with it.
    private var offlineKeptList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Label("No connection", systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Kept games")
                    .font(.title2.bold())
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                ForEach(Array(offlineKeptGames.enumerated()), id: \.element.id) { index, rom in
                    Button {
                        resuming = rom
                    } label: {
                        HStack(spacing: 12) {
                            CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                                .frame(width: 46, height: 61)
                                .clipShape(.rect(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rom.displayName)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if index < offlineKeptGames.count - 1 {
                        Divider().padding(.leading, 78)
                    }
                }
            }
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    /// Box art, always, the same visual language as every other card in
    /// the app. The hero used to show a captured game frame when one
    /// existed, which meant Home mixed two art styles depending on how the
    /// last session ended, and keeping those frames honest required a
    /// periodic in-game screenshot, standing work inside a process with
    /// no headroom to spare. Save screenshots still exist where they
    /// belong: attached to the save states themselves.
    private func heroArtwork(for rom: Rom, contentMode: ContentMode) -> some View {
        CoverImage(
            path: rom.pathCoverLarge ?? rom.pathCoverSmall,
            title: rom.displayName,
            contentMode: contentMode
        )
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
            // Fitted over a blurred copy of itself rather than cropped to
            // fill: box art is tall and the hero card is wide, so filling
            // would slice the art to a strip of its middle. Fitting shows
            // all of it, and the blurred backdrop fills the leftovers with
            // the art's own colours instead of letterbox bars.
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
                .clipShape(.rect(cornerRadius: 18))
                .shadow(radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        // A second, real button rather than decoration inside the first.
        // Resume means resume: it goes straight back into the game with
        // the choices already remembered for it, since the scope doc's
        // Home promises one tap into the last game and stopping at a
        // screen with a Play button on it is two. Tapping the artwork
        // still opens that screen, which is where you go to pick a
        // different state, change the core, or export.
        .overlay(alignment: .topTrailing) {
            Button {
                Task { await beginResume(rom) }
            } label: {
                Group {
                    if preparingResume {
                        ProgressView().tint(.white)
                    } else {
                        Label("Resume", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(minWidth: 92)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(preparingResume)
            .padding(12)
        }
    }

    private func consumeQuickAction() {
        guard let action = quickActions.pending else { return }
        switch action {
        case .search:
            // The tab bar's job, never this screen's.
            return
        case .resume:
            // No recents once loaded means nothing to resume; the action
            // dissolves into just opening the app, which is the honest
            // reading of Resume with nothing to resume into.
            guard loaded else { return }
            quickActions.pending = nil
            if let first = recent.first {
                Task { await beginResume(first) }
            }
        case .recents:
            quickActions.pending = nil
            quickPushRecents = true
        case .favorites:
            guard session.favoriteCollection != nil else { return }
            quickActions.pending = nil
            quickPushFavorites = true
        }
    }

    /// Starts the last game without the launch screen in between.
    ///
    /// Falls back to that screen whenever there is a real question to
    /// answer: no core for the platform means nothing to launch, and any
    /// failure reaching the server is better spent on a screen that can
    /// explain itself than on a player that would just fail later.
    ///
    /// An interrupted session wins over a stored state, matching what the
    /// launch screen itself does: the local autosave is newer than
    /// anything uploaded, and it is the run that was actually cut short.
    ///
    /// Otherwise, this is what actually makes switching between desktop
    /// and mobile transparent: the newest state is loaded regardless of
    /// which device wrote it, by weight of its timestamp, not by trusting
    /// whichever copy happens to be closest. The one exception is the
    /// local pause menu slot outrunning the server, which happens when its
    /// own upload failed, already reported in the game at the time; the
    /// comparison catches it anyway rather than relying on remembering
    /// that warning.
    private func beginResume(_ rom: Rom) async {
        preparingResume = true
        defer { preparingResume = false }

        let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        let cores = CoreCatalog.cores(for: canonicalSlug)
        guard PlatformSupport.isSupported(canonicalSlug: canonicalSlug), !cores.isEmpty else {
            resuming = rom
            return
        }

        let core = LaunchChoices.defaultCore(rom: rom, canonicalSlug: canonicalSlug, from: cores)
        let firmware = (try? await session.firmware(platformId: rom.platformId)) ?? []
        let firmwareId = LaunchChoices.defaultFirmware(platformId: rom.platformId, from: firmware)?.id
        let choices = LaunchChoices(core: core, firmwareId: firmwareId, saveId: nil)

        if SessionMarker.offersResume(romId: rom.id) {
            directLaunch = DirectLaunch(
                rom: rom, choices: choices, resumeFromAutosave: true, stateToLoad: nil
            )
            return
        }

        guard let states = try? await session.states(romId: rom.id) else {
            resuming = rom
            return
        }
        guard !states.isEmpty else {
            // Genuinely no states: nothing to resume into, so the game
            // just starts. Not a fallback to the launch screen, there is
            // no real question left to ask.
            directLaunch = DirectLaunch(
                rom: rom, choices: choices, resumeFromAutosave: false, stateToLoad: nil
            )
            return
        }
        // Plain string comparison, matching the launch screen's own
        // newest-first sort: RomM's `updated_at` is not documented as a
        // specific format, only "string", in its own OpenAPI schema, and
        // this comparison is already relied on elsewhere, so it stays
        // format agnostic rather than risk a date parser silently
        // rejecting a shape that was never actually confirmed.
        let newest = states.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }!

        // The one place an actual Date is unavoidable: weighing that
        // newest server state against the local pause menu slot, which
        // only ever carries a native timestamp. If the server's string
        // cannot be parsed at all, that is not a "local wins" signal, it
        // is a genuine unknown, and guessing either way risks the exact
        // silent wrong load this whole change exists to fix. The launch
        // screen is where an unknown gets a human rather than a guess.
        guard let newestDate = RommDate.parse(newest.updatedAt) else {
            resuming = rom
            return
        }
        if let localDate = ManualSave.date(romId: rom.id), localDate > newestDate {
            directLaunch = DirectLaunch(
                rom: rom, choices: choices, resumeFromAutosave: false, stateToLoad: .local
            )
            return
        }

        guard let bytes = try? await session.stateContent(newest) else {
            // A state exists and should be loaded, but fetching it failed:
            // better to explain that on the launch screen than to guess and
            // either start over or load something stale.
            resuming = rom
            return
        }
        directLaunch = DirectLaunch(
            rom: rom, choices: choices, resumeFromAutosave: false, stateToLoad: .remote(bytes)
        )
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
                                    .downloadBadge(romId: rom.id, compact: true)
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
                        .gameContextMenu(rom: rom)
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
        // A session that just ended must reach the server before recents
        // are asked for, or the game played a moment ago sorts under the
        // one before it. No-op when nothing is pending.
        await session.waitForPendingPlayReport()
        // Concurrently, not one after the other. Sequentially, a slow or
        // dead connection paid the timeout twice before this screen could
        // say anything, which doubled the wait for the answer that matters
        // least.
        async let recentTask = session.recentlyPlayed()
        async let favoritesTask = session.favoriteRoms()

        do {
            recent = try await recentTask.items
            offline = false
        } catch RommError.offline {
            offline = true
        } catch {
            // Left as is on purpose, see above.
        }
        if let favs = try? await favoritesTask {
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
