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
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var recent: [Rom] = []
    @State private var favorites: [Rom] = []
    @State private var loaded = false
    @State private var offline = false
    @State private var resuming: Rom?
    #if os(iOS)
    @State private var directLaunch: DirectLaunch?
    #endif
    @State private var nativeDirectLaunch: NativeDirectLaunch?
    @State private var preparingResume = false
    @ObservedObject private var keptStore = KeptGameStore.shared
    @ObservedObject private var quickActions = QuickActionRouter.shared
    @State private var quickPushRecents = false
    @State private var quickPushFavorites = false

    /// Everything the player needs to start without the launch screen in
    /// front of it. Identifiable so it can drive a `fullScreenCover` the
    /// same way `resuming` does.
    ///
    /// iOS-only: it exists purely to feed `PlayerView`, itself iOS-only in
    /// this pass. See `beginResume` below for tvOS's fallback.
    #if os(iOS)
    private struct DirectLaunch: Identifiable {
        let id = UUID()
        let rom: Rom
        let choices: LaunchChoices
        let resumeFromAutosave: Bool
        let stateToLoad: PlayerView.StateToLoad?
    }
    #endif

    /// The native equivalent of `DirectLaunch`. Separate rather than one
    /// shared shape with optional fields either player never uses: native
    /// has no `resumeFromAutosave` concept (that is webview's injected
    /// autosave script, see `SessionMarker`) and takes state as raw bytes
    /// rather than `PlayerView.StateToLoad`'s local/remote distinction,
    /// `NativeLauncher.prepare` already handles the on-device-vs-download
    /// question before this is ever built.
    private struct NativeDirectLaunch: Identifiable {
        let id = UUID()
        let rom: Rom
        let core: NativeCore
        let initialState: Data?
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                // Nothing cached means nothing to show behind a banner, so
                // offline replaces the content rather than sitting above
                // it. Kept in a ScrollView so pull to refresh still works
                // as a second way to retry. The manual toggle bypasses
                // that emptiness check entirely: real signal loss with a
                // hero already on screen should not yank it away, but
                // choosing Offline Mode is a deliberate act, and it has
                // to visibly do something the instant it is flipped, not
                // wait for recent/favorites to happen to be empty
                // already or for a fresh launch to clear them (Marcus,
                // 2026-08-07: had to force-quit and reopen to see it
                // take effect).
                if networkMonitor.manualOfflineMode || (offline && recent.isEmpty && favorites.isEmpty) {
                    // Nothing cached to show above a banner, same as
                    // before, but there may be something better: any
                    // kept, native-capable game plays with zero
                    // connection, so resume-first still has an honest
                    // answer offline whenever one exists. The exact same
                    // view the library shows, not a second one built to
                    // look like it: one offline view, shown wherever the
                    // app needs one (Marcus, 2026-08-07, "why would the
                    // two need to exist").
                    OfflineLibraryView(onRetry: load)
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
            // Shown only when a background sync pass actually uploaded
            // something (a queued save, a queued play-session report),
            // never for a no-op check: same "invisible when it applies
            // to nothing" rule the Offline Mode toggle already follows.
            // safeAreaInset rather than an overlay so it never covers the
            // toolbar or the hero underneath it, in either orientation,
            // without needing to be threaded into both layouts
            // separately.
            .safeAreaInset(edge: .top) {
                if let summary = session.lastSyncSummary {
                    syncBanner(summary)
                }
            }
            .onChange(of: session.lastSyncSummary) { _, summary in
                guard summary != nil else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation { session.lastSyncSummary = nil }
                }
            }
            // No large title. The tab bar already names this screen, and
            // in landscape the large title overlapped the first rail's
            // header outright. Inline keeps the bar itself, which the
            // settings button needs.
            // Both the inline title mode and this toolbar (Settings link,
            // Offline Mode toggle) are iOS-only for now: navigationBarTitle
            // DisplayMode doesn't exist on tvOS, and SettingsView itself is
            // iOS-only in this pass. tvOS follow-up, not solved here.
            #if os(iOS)
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
                // A real Toggle, not a plain button: a toolbar icon that
                // just triggers something is the wrong shape for a mode
                // that stays on, nothing in iOS treats Low Power Mode or
                // Airplane Mode itself as a one-shot action button. The
                // button style keeps it toolbar-sized while still
                // reading as a switch, filled when on the same way
                // Control Center's own toggles are; the airplane glyph
                // is deliberately the one iOS already uses for exactly
                // this idea, acting as though there is no signal.
                // Invisible, not merely disabled, when there is nothing
                // it could switch to, matching every other control this
                // app has cut back to only where it applies.
                if !KeptGameStore.shared.offlinePlatforms().isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        // No explicit tint: the app has no custom accent
                        // color, so leaving this alone inherits the same
                        // system blue the Home tab icon already uses,
                        // guaranteed to match rather than a hardcoded
                        // guess at it.
                        Toggle(isOn: $networkMonitor.manualOfflineMode) {
                            Label("Offline Mode", systemImage: "airplane")
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            #endif
            .refreshable { await load() }
            // A game reached through Library, not Home's own resume flow,
            // has its own fullScreenCover and never touches `resuming`, so
            // the reload below never sees it close. Reappearing covers both:
            // it fires on first appearance same as `.task` would, and again
            // every time navigation brings Home back into view, favoriting
            // included.
            .onAppear { Task { await load() } }
            // Live, not just at the next natural reload: load() already
            // leaves recent/favorites untouched on a failed fetch (see
            // its own catch below), so re-running it the instant
            // connectivity changes can only correct the offline flag and
            // reveal the kept-games list sooner, never discard content
            // already on screen. Closes the gap where going offline
            // needed a manual re-navigation to notice (Marcus,
            // 2026-08-07).
            .onChange(of: networkMonitor.isConnected) { _, _ in Task { await load() } }
            .onChange(of: networkMonitor.manualOfflineMode) { _, _ in Task { await load() } }
            // Launch and playback both go through GameLaunchView/PlayerView,
            // which are iOS-only for now: tvOS has no native core wired up
            // yet (see NativeLauncher.swift) and no webview player. Follow-up
            // work, not stubbed further here.
            #if os(iOS)
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
            #endif
            .onChange(of: resuming == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            #if os(iOS)
            .onChange(of: directLaunch == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            #endif
            #if os(iOS)
            .fullScreenCover(item: $nativeDirectLaunch) { launch in
                NativePlayerView(rom: launch.rom, core: launch.core, initialState: launch.initialState)
            }
            .onChange(of: nativeDirectLaunch == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            #endif
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

        // The direct-launch fast path below skips the launch screen by
        // going straight to PlayerView, which is iOS-only for now (see
        // GameLaunchView.swift and the #if guards around it). tvOS always
        // falls back to the launch screen instead, same as the "need a
        // human" cases below already do.
        #if os(tvOS)
        resuming = rom
        return
        #else
        let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        let cores = CoreCatalog.cores(for: canonicalSlug)
        guard PlatformSupport.isSupported(canonicalSlug: canonicalSlug), !cores.isEmpty else {
            resuming = rom
            return
        }

        // Resume honors whichever backend this game actually last played
        // on, same as the full launch screen already does via
        // `LaunchChoices.defaultBackend`. Hardcoding webview here used to
        // silently replay a stale choice for any platform that graduated
        // to native since it was last played (Dreamcast and N64 both did,
        // 2026-08-10/11), and risked resuming a native save into the
        // webview's own player, or the reverse, since the two do not share
        // a save format.
        let backend = LaunchChoices.defaultBackend(rom: rom, canonicalSlug: canonicalSlug)
        if backend == .native, let nativeCore = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) {
            await beginNativeResume(rom, core: nativeCore)
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
        #endif
    }

    /// The native counterpart to the newest-state resolution above, minus
    /// the `SessionMarker`/`ManualSave` autosave branches: those exist for
    /// the webview's own injected autosave script, which native has no
    /// equivalent of, so native resume compares only server states against
    /// whatever is already on the device, same as `GameLaunchView`'s own
    /// native launch path does.
    private func beginNativeResume(_ rom: Rom, core: NativeCore) async {
        do {
            try await NativeLauncher.prepare(rom: rom, session: session)
        } catch {
            resuming = rom
            return
        }

        guard let states = try? await session.states(romId: rom.id) else {
            resuming = rom
            return
        }
        guard !states.isEmpty else {
            nativeDirectLaunch = NativeDirectLaunch(rom: rom, core: core, initialState: nil)
            return
        }
        let newest = states.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }!

        // The copy already on this phone first: reading it costs nothing,
        // and a network round trip only slows down a game already sitting
        // on the device, matching `GameLaunchView.beginNativePlay`'s own
        // reasoning.
        if let local = keptStore.localState(for: rom.id), local.stateId == newest.id {
            nativeDirectLaunch = NativeDirectLaunch(rom: rom, core: core, initialState: local.data)
            return
        }
        guard let bytes = try? await session.stateContent(newest) else {
            resuming = rom
            return
        }
        nativeDirectLaunch = NativeDirectLaunch(rom: rom, core: core, initialState: bytes)
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

    /// A background sync just uploaded something the app was holding
    /// offline. Self-dismissing (see the onChange above), terse, matching
    /// every other offline-sync caption in this app: the fact that
    /// something uploaded is the whole message.
    private func syncBanner(_ summary: String) -> some View {
        Label(summary, systemImage: "checkmark.icloud")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
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
        // Real suppression, not a cosmetic switch: manual offline mode
        // has to actually stop the app from spending a connection it was
        // told not to use, or the roaming/capped-data reason for having
        // it at all would not hold up. Genuine signal loss already
        // avoided this same round trip everywhere else tonight; this is
        // the same check, just also true when someone chose it.
        guard !networkMonitor.isOffline else {
            offline = true
            loaded = true
            return
        }

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
        if #available(iOS 26.0, tvOS 26.0, *) {
            self.scrollEdgeEffectHidden()
        } else {
            self
        }
    }
}
