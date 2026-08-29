#if os(tvOS)
import SwiftUI

/// tvOS's library: a grid of platform tiles, not a list of rows.
///
/// Deliberately not a copy of iOS's `LibraryScreen`. That one is a `List`
/// because a phone is a tall narrow window where a full-width row is the
/// natural unit. A TV is a wide one, and the same row stretched to 1920pt
/// leaves a platform name at the far left and its count at the far right
/// with a third of the screen empty between them. A tile grid uses the
/// width, gives the focus engine a real 2D field to move around, and fits
/// several times as many platforms on screen.
///
/// No screen title either: the tab bar already says Library, and repeating
/// it directly underneath is a habit from iOS, where the tab bar's own
/// label is small and a large title earns its place. Here it is neither.
struct TVLibraryView: View {
    @EnvironmentObject private var session: Session
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    @State private var platforms: [Platform] = []
    @State private var collections: [Collection] = []
    @State private var loading = true
    @State private var browsing: Browsing = .platforms
    @State private var destination: Destination?
    /// A few cover paths per tile, keyed by the tile's own source id, for
    /// the mosaic behind each tile's label. Filled in the background after
    /// the platform and collection lists land, so the grid appears
    /// immediately and the art fills in rather than the whole screen
    /// waiting on N extra requests.
    @State private var mosaics: [String: [String]] = [:]
    /// Moving the switcher to a plain sibling view (out of the grid's own
    /// section header) was not, on its own, enough to make tvOS land focus
    /// there on arrival; `.prefersDefaultFocus` is a hint evaluated against
    /// a heuristic, not a guarantee, and it was still losing to the grid.
    /// Driving it explicitly with `@FocusState` instead, on `onAppear`.
    @FocusState private var focusedSwitch: Browsing?
    /// Forcing focus onto the switcher is only needed the first time this
    /// screen appears: `NavigationStack` re-runs a popped root view's
    /// `onAppear`, and without this guard every reappearance re-grabbed
    /// focus, including leaving Library for Search or Home via the tab bar
    /// and coming back, which yanked focus back down to the switcher
    /// instead of wherever the system's own back-navigation would have put
    /// it. Reappearing from a pushed platform's rom list still lands focus
    /// correctly without help, the same way any other screen's back
    /// navigation does; this flag only covers the one case that genuinely
    /// needed the override, the very first landing from a fresh app launch.
    @State private var hasForcedInitialFocus = false

    /// `RomListView.Source` carries whole `Platform`/`Collection` values
    /// and is not Hashable, so it cannot drive navigationDestination(item:)
    /// directly. Boxing it keeps that a tvOS navigation detail rather than
    /// a conformance forced onto a type iOS shares.
    private struct Destination: Identifiable, Hashable {
        let id = UUID()
        let source: RomListView.Source

        static func == (lhs: Destination, rhs: Destination) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    enum Browsing: String, CaseIterable, Identifiable {
        case platforms = "Platforms", collections = "Collections"
        var id: String { rawValue }
    }

    private let columns = [GridItem(.adaptive(minimum: 380), spacing: 36)]

    var body: some View {
        NavigationStack {
            // Ordinary scrollable content, not pinned chrome: the system
            // top bar (Home, Library, Search, Settings) is real, pinned
            // Liquid Glass, but it is system-owned, and Apple keeps that
            // bar's space deliberately separate from app content rather
            // than letting apps annex or extend it. Two rounds of trying
            // to make this switcher its own permanently-pinned glass bar
            // (floating pills, then a shared full-width bar) each broke
            // something new: nothing behind isolated pills to blur, then
            // a fixed bar slicing through whatever row was scrolling past
            // underneath it. This app already treats scrolling as normal
            // for reaching secondary content (Home's own Favorites row
            // requires it), so the switcher scrolls away with the grid
            // exactly the same way, rather than fighting to stay glued to
            // the screen like it was trying to become system chrome.
            ScrollView {
                LazyVGrid(columns: columns, spacing: 36) {
                    Section {
                        switch browsing {
                        case .platforms:
                            // Identified by a namespaced key, not by the
                            // model's own id. Platform and Collection are
                            // both Identifiable by a plain Int, and both
                            // ForEaches live in this one grid, swapped
                            // by `browsing`. With raw ids SwiftUI saw
                            // "still items 1 and 2" across the switch and
                            // reused the tiles it already had, so
                            // Collections rendered Game Boy and Game Boy
                            // Advance (platforms 1 and 2) instead of
                            // Favorites and SHMUP (collections 1 and 2).
                            ForEach(supported, id: \.libraryTileID) { platform in
                                tile(
                                    title: label(for: platform),
                                    count: platform.romCount,
                                    source: .platform(platform)
                                )
                            }
                        case .collections:
                            ForEach(collections, id: \.libraryTileID) { collection in
                                tile(
                                    title: collection.name,
                                    count: collection.romCount,
                                    source: .collection(collection)
                                )
                            }
                        }
                    } header: {
                        switcher
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 20)
                .padding(.bottom, 60)

                if loading, platforms.isEmpty, collections.isEmpty {
                    ProgressView().padding(.top, 80)
                }
            }
            .navigationDestination(item: $destination) { destination in
                TVRomGridView(source: destination.source)
            }
        }
        .onAppear {
            guard !hasForcedInitialFocus else { return }
            hasForcedInitialFocus = true
            focusedSwitch = browsing
        }
        .task {
            restoreStoredArt()
            async let p = try? await session.platforms()
            async let c = try? await session.collections()
            platforms = await p ?? []
            collections = await c ?? []
            loading = false
            await loadArt()
        }
    }

    /// Real Liquid Glass on each pill, not a flat white-opacity capsule
    /// standing in for it. tvOS 18 falls back to the flat fill, since
    /// `glassEffect` only exists on tvOS 26 and this app's support window
    /// is this major and the previous one.
    private var switcher: some View {
        HStack(spacing: 16) {
            ForEach(Browsing.allCases) { mode in
                Button {
                    browsing = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 30)
                        .padding(.vertical, 14)
                        .background {
                            if #available(tvOS 26.0, *) {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(
                                        browsing == mode ? .regular.tint(.white.opacity(0.35)) : .regular,
                                        in: Capsule()
                                    )
                            } else {
                                Capsule().fill(
                                    browsing == mode
                                        ? AnyShapeStyle(.white.opacity(0.18))
                                        : AnyShapeStyle(.clear)
                                )
                            }
                        }
                }
                .buttonStyle(TextFocusStyle())
                .focused($focusedSwitch, equals: mode)
            }
            Spacer()
        }
        .padding(.bottom, 20)
    }

    private func sectionHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 36)
        .padding(.bottom, 12)
    }

    private func tile(
        title: String, count: Int, source: RomListView.Source, dimmed: Bool = false
    ) -> some View {
        let covers = mosaics[artKey(for: source)] ?? []
        return Button {
            destination = Destination(source: source)
        } label: {
            // A row: label on the left, cover on the right, both centred by
            // the stack itself. Earlier versions positioned each piece with
            // computed widths and overlay alignments, which is why the
            // label kept drifting low and its count clipped off the bottom.
            // There is nothing special about this layout and it should
            // never have needed arithmetic.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.8), radius: 8, y: 1)
                    Text("\(count) games")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .shadow(color: .black.opacity(0.8), radius: 6, y: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let first = covers.first {
                    // 3:4, sized off the row's own height, so box art is
                    // never squeezed into a slot the wrong shape and
                    // cropped to a sliver.
                    CoverImage(path: first, title: "", showsPlaceholder: false)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.55), radius: 12, y: 5)
                }
            }
            .padding(20)
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geo in
                    // The opaque zone has to reach exactly to where the
                    // cover art starts, not some fixed fraction of the
                    // tile's width. A fixed fraction (0.34, tried earlier)
                    // covers a short label fine but a longer title or the
                    // "N games" line runs past it into the gradient's
                    // interpolated region, which is only partially opaque
                    // by design (that's what lets the atmosphere layer
                    // read as color at all near the cover). The result was
                    // a brightness leak that scaled with cover paleness
                    // and looked like it came from focus state, because
                    // the one persistently-focused tile in every screenshot
                    // happened to also be one with a leaking label. It
                    // wasn't focus: three separate unfocused tiles leaked
                    // in the same screenshot once anyone looked closely.
                    let coverZoneWidth = Self.coverWidth + 20
                    let opaqueWidth = max(0, geo.size.width - coverZoneWidth)
                    ZStack(alignment: .leading) {
                        Self.panel
                        if !covers.isEmpty {
                            // Atmosphere: the same art, blurred past
                            // recognition, so the tile carries the platform's
                            // colour with no edge anywhere to blend.
                            HStack(spacing: 0) {
                                ForEach(Array(covers.prefix(2).enumerated()), id: \.offset) { _, path in
                                    CoverImage(path: path, title: "", showsPlaceholder: false)
                                        .frame(maxWidth: .infinity)
                                        .clipped()
                                }
                            }
                            // Scaled, not negatively padded. Negative padding
                            // makes this layer genuinely larger than the tile,
                            // so the ZStack sizes to it and the panel and
                            // scrim above end up centred inside a bigger box,
                            // leaving a bare strip of unscrimmed artwork down
                            // each edge. scaleEffect gives blur the extra
                            // pixels it needs to sample without touching
                            // layout at all.
                            .scaleEffect(1.3)
                            .blur(radius: 26)
                            .saturation(0.7)
                            .brightness(-0.22)

                            // A real photo of the device (not a simulator
                            // screenshot, which compressed this away) showed
                            // a hairline of the atmosphere layer's own
                            // colour surviving right at the tile's leading
                            // edge, tinted per platform, focus state
                            // irrelevant. A LinearGradient's opaque stop is
                            // opaque in value but still an interpolated
                            // shader; whatever composited it left a
                            // subpixel gap for that hairline to show
                            // through. A plain solid Rectangle has no
                            // interpolation to get subtly wrong, so the
                            // label zone is a flat fill and only the
                            // strip actually behind the cover fades.
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Self.panel)
                                    .frame(width: opaqueWidth)
                                LinearGradient(
                                    colors: [Self.panel, Self.panel.opacity(0.3)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: coverZoneWidth)
                            }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                }
                .clipped()
            }
            .animation(.easeOut(duration: 0.35), value: covers)
        }
        .buttonStyle(CoverFocusStyle(cornerRadius: 18, showsRing: false))
        .opacity(dimmed ? 0.5 : 1)
    }

    /// Deliberately darker and less saturated than it looks in a browser
    /// mockup: the same sRGB values render far more vividly on a
    /// wide-gamut TV, and the first build of this tile came out a loud
    /// electric purple on real hardware.
    private static let panel = Color(red: 0.14, green: 0.10, blue: 0.24)

    /// The cover's rendered width in the tile: 3:4 box art, fit to the
    /// row's inner height (200 tile height minus 20+20 padding). Kept in
    /// sync with the `.aspectRatio(3.0 / 4.0, contentMode: .fit)` cover in
    /// the tile body so the label scrim's opaque zone can end exactly
    /// where the cover begins instead of guessing.
    private static let coverWidth: CGFloat = (200 - 40) * 3.0 / 4.0

    private func artKey(for source: RomListView.Source) -> String {
        switch source {
        case .platform(let platform): return "p\(platform.id)"
        case .collection(let collection): return "c\(collection.id)"
        case .recentlyPlayed: return "recent"
        case .keptPlatform(let platform, _): return "k\(platform.id)"
        }
    }

    /// The whole picking and caching mechanism lives in `LibraryTileArt`,
    /// shared with iOS since its library adopted the same artwork tiles.
    /// The "tv" namespace keeps this screen on the exact storage keys it
    /// has always used, so nothing about a stored pick changes.
    private func restoreStoredArt() {
        mosaics = LibraryTileArt.restore(namespace: "tv")
    }

    private func loadArt() async {
        let fresh = await LibraryTileArt.load(
            platforms: platforms, collections: collections,
            existing: mosaics, session: session
        )
        guard !fresh.isEmpty else { return }
        mosaics.merge(fresh) { _, new in new }
        LibraryTileArt.persist(mosaics, namespace: "tv")
    }

    /// Only platforms this device can actually play, and only ones with
    /// games in them.
    ///
    /// iOS deliberately lists unsupported platforms in their own section,
    /// and is right to: there "unsupported" means no *native* core, and
    /// those games still play through the webview player. tvOS has no
    /// webview player at all (see CLAUDE.md's JIT boundary), so the same
    /// section here is a dead end, browse in and launch nothing, across a
    /// large part of the library (Jaguar, Switch, PS2, DS, PS3 and more).
    /// A game reached some other way, such as search, still explains
    /// itself properly on the launch screen.
    private var supported: [Platform] { platforms.filter { isSupported($0) && $0.romCount > 0 } }

    /// The same choice LibraryView makes on iOS, honoring the same
    /// Settings row: this predated the setting and hardcoded the
    /// metadata-first order, which is why flipping the new tvOS row
    /// visibly did nothing here.
    private func label(for platform: Platform) -> String {
        let metadata = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let folder = platform.fsSlug.isEmpty ? nil : platform.fsSlug
        switch PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName {
        case .platformName: return metadata ?? folder ?? platform.slug
        case .folderName: return folder ?? metadata ?? platform.slug
        }
    }

    private func isSupported(_ platform: Platform) -> Bool {
        let canonicalSlug = (session.platformsVersions[platform.fsSlug] ?? platform.fsSlug).lowercased()
        let isArcade = PlatformSupport.arcadeSlugs.contains(platform.slug)
        guard PlatformSupport.isSupported(canonicalSlug: canonicalSlug, isArcade: isArcade),
              let native = NativePlatform.platform(bySlug: canonicalSlug, isArcade: isArcade)
        else { return false }
        // The experimental gate: with the switch off, a gated platform's
        // shelf disappears rather than offering games whose launch
        // screen would refuse them.
        return !native.isExperimental || ExperimentalCores.enabled
    }
}

private extension Platform {
    /// Namespaced so a platform can never collide with a collection that
    /// happens to share its integer id. See the ForEach above.
    var libraryTileID: String { "platform-\(id)" }
}

private extension Collection {
    var libraryTileID: String { "collection-\(id)" }
}
#endif
