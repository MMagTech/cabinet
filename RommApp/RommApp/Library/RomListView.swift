import SwiftUI

/// The games of one platform or one collection, as a cover grid or a compact
/// text list.
///
/// The mode preference persists per source, because arcade sets often have
/// no cover art and a grid of gray tiles is worse than a text list, while
/// console libraries look far better as covers. One preference for both
/// would force a bad default on one of them.
struct RomListView: View {
    enum Source {
        case platform(Platform)
        case collection(Collection)
        /// Home's "Recent" rail in full. Not a RomM concept the way a
        /// collection is, just the same last-played query Home already
        /// makes, unpaged there and paged here.
        case recentlyPlayed
        /// One platform's kept games, browsed with no network at all.
        /// Offline Mode's answer to the library: the same grid and list
        /// this screen already draws for a live platform, reused rather
        /// than a second version built just for this, fed a plain array
        /// instead of a paged fetch because every rom is already known,
        /// already on the phone, nothing to page or retry.
        case keptPlatform(Platform, [Rom])

        var title: String {
            switch self {
            case .platform(let platform), .keptPlatform(let platform, _): return platform.slug
            case .collection(let collection): return collection.name
            case .recentlyPlayed: return "Recent"
            }
        }

        /// Distinguishes a platform and a collection that happen to share an
        /// id, which their own ids alone cannot: they are different tables.
        var modeKey: String {
            switch self {
            case .platform(let platform): return "platform.\(platform.slug)"
            case .collection(let collection): return "collection.\(collection.id)"
            case .recentlyPlayed: return "recentlyPlayed"
            case .keptPlatform(let platform, _): return "keptPlatform.\(platform.slug)"
            }
        }
    }

    let source: Source

    @EnvironmentObject private var session: Session
    @ObservedObject private var compatibility = Compatibility.shared
    @ObservedObject private var keptStore = KeptGameStore.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }
    @State private var roms: [Rom] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: LoadFailure?
    @State private var viewMode: ViewMode
    @State private var playing: Rom?

    enum ViewMode: String {
        case grid, list
    }

    init(source: Source) {
        self.source = source
        let stored = UserDefaults.standard.string(forKey: Self.modeKey(for: source.modeKey))
        _viewMode = State(initialValue: stored.flatMap(ViewMode.init) ?? .grid)
    }

    private static func modeKey(for sourceKey: String) -> String {
        "com.mmagtech.RommApp.viewMode.\(sourceKey)"
    }

    /// Same fallback order as `Rom.platformLabel`, one rung shorter: a
    /// platform has no display name field of its own to fall back through,
    /// only its curated name, its folder name, and the slug last of all. A
    /// collection has no such ambiguity, its name is just its name.
    private var navigationLabel: String {
        switch source {
        case .platform(let platform), .keptPlatform(let platform, _):
            let metadataName = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
            let folderName = platform.fsSlug.isEmpty ? nil : platform.fsSlug
            switch labelSource {
            case .platformName: return metadataName ?? folderName ?? platform.slug
            case .folderName: return folderName ?? metadataName ?? platform.slug
            }
        case .collection(let collection):
            return collection.name
        case .recentlyPlayed:
            return "Recent"
        }
    }

    var body: some View {
        #if os(tvOS)
        // Every path that reaches a game list on tvOS lands on the grid
        // built for a TV, rather than this screen's iOS chrome (a toolbar
        // view-mode menu that renders as a floating pill over the artwork,
        // a navigationTitle that paints over it, a letter scrubber meant
        // for a thumb). Handing off here rather than at each call site
        // means Home's rails, the library, search and the offline list all
        // get it without any of them having to know.
        TVRomGridView(source: source)
        #else
        iosBody
        #endif
    }

    #if !os(tvOS)
    private var iosBody: some View {
        Group {
            if error == .offline {
                OfflineNotice { await reload() }
            } else if let error {
                ContentUnavailableView {
                    Label("Could not load games", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try again") { Task { await reload() } }
                }
            } else {
                switch viewMode {
                case .grid: grid
                case .list: list
                }
            }
        }
        .navigationTitle(navigationLabel)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // A menu, not a segmented picker. iOS 26 wraps every
                // toolbar item in its own glass container, and a segmented
                // control carries a background of its own, so the two
                // nested: a grey selection pill inside a white capsule,
                // with the selection spilling past the container's edge.
                // Pinning the width only squeezed it harder. A menu is one
                // button, so there is nothing to nest, and it has room for
                // sorting later if that ever earns its place.
                Menu {
                    Picker("View", selection: $viewMode) {
                        Label("Grid", systemImage: "square.grid.3x3").tag(ViewMode.grid)
                        Label("List", systemImage: "list.bullet").tag(ViewMode.list)
                    }
                } label: {
                    Image(systemName: viewMode == .grid ? "square.grid.3x3" : "list.bullet")
                }
            }
        }
        .onChange(of: viewMode) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey(for: source.modeKey))
        }
        .task { await reload() }
        // The scrubber can only jump to rows that exist, so list mode pulls
        // the whole set rather than paging on scroll. A list is just names;
        // even the 1,204 arcade titles are a few small requests, and a
        // scrubber that stops working past the first page is worse than
        // none. The loop waits out whichever page fetch is already in
        // flight rather than trusting `total`, which is zero until the
        // first page lands and made an earlier version give up instantly.
        .task(id: viewMode) {
            guard viewMode == .list else { return }
            var lastCount = -1
            while error == nil {
                if loading {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                if total > 0, roms.count >= total { break }
                if roms.count == lastCount { break }
                lastCount = roms.count
                await loadNextPage()
            }
        }
        .fullScreenCover(item: $playing) { rom in
            NavigationStack { GameLaunchView(rom: rom) }
        }
    }
    #endif

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: TenFoot.gridCoverMinimum), spacing: TenFoot.gridSpacing)],
                spacing: TenFoot.gridSpacing
            ) {
                ForEach(roms) { rom in
                    Button {
                        playing = rom
                    } label: {
                        VStack(spacing: 6) {
                            CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                .compatibilityBadge(romId: rom.id)
                                .favoriteBadge(romId: rom.id)
                                .downloadBadge(romId: rom.id)

                            Text(rom.displayName)
                                .font(TenFoot.captionFont)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(
                                    compatibility.isMarked(rom.id) ? .secondary : .primary
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .gameContextMenu(rom: rom)
                    .onAppear { Task { await loadMoreIfNeeded(current: rom) } }
                }
            }
            .padding(.horizontal, 16)

            footer
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(roms) { rom in
                    Button {
                        playing = rom
                    } label: {
                        HStack(spacing: 8) {
                            Text(rom.displayName)
                                .lineLimit(1)
                                .foregroundStyle(
                                    compatibility.isMarked(rom.id) ? .secondary : .primary
                                )
                            Spacer(minLength: 0)
                            // Leftmost of the three, and before the star
                            // rather than after it: transient status reads
                            // first, the two settled badges follow in
                            // their own established order.
                            if keptStore.downloading[rom.id] != nil {
                                ProgressView(value: min(keptStore.downloading[rom.id]?.fraction ?? 0, 1))
                                    .progressViewStyle(.circular)
                                    .controlSize(.mini)
                            }
                            if session.isFavorite(romId: rom.id) {
                                Image(systemName: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.yellow)
                            }
                            if compatibility.isMarked(rom.id) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .gameContextMenu(rom: rom)
                    .onAppear { Task { await loadMoreIfNeeded(current: rom) } }
                }

                footer
                    #if os(iOS)
                    .listRowSeparator(.hidden)
                    #endif
            }
            .listStyle(.plain)
            // Room for the rail, or the longest titles run underneath it.
            .contentMargins(.trailing, letterIndex.count > 4 ? 18 : 0, for: .scrollContent)
            // The letter scrubber is a touch drag gesture with a haptic tap,
            // both iOS-only; tvOS's focus-engine equivalent is real future
            // work, not attempted here.
            #if os(iOS)
            .overlay(alignment: .trailing) {
                // Only when there is enough alphabet to be worth jumping
                // around in; a six game list scrolls faster than it scrubs.
                if letterIndex.count > 4 {
                    LetterScrubber(letters: letterIndex.map(\.letter)) { letter in
                        if let id = letterIndex.first(where: { $0.letter == letter })?.romId {
                            proxy.scrollTo(id, anchor: .top)
                        }
                    }
                }
            }
            #endif
        }
    }

    /// The first game of each initial, in list order. Non letters group
    /// under "#" at whichever end the server sorts them to. A leading "The"
    /// is skipped because the server sorts ignoring it: lettering "The
    /// Battle of..." under T would plant a stray T in the middle of the B
    /// section and the rail would jump there.
    private var letterIndex: [(letter: String, romId: Int)] {
        var seen = Set<String>()
        var index: [(String, Int)] = []
        for rom in roms {
            var name = rom.displayName
            if name.lowercased().hasPrefix("the ") { name = String(name.dropFirst(4)) }
            let first = name.prefix(1).uppercased()
            let letter = first.rangeOfCharacter(from: .letters) != nil ? first : "#"
            if seen.insert(letter).inserted {
                index.append((letter, rom.id))
            }
        }
        return index
    }

    @ViewBuilder
    private var footer: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding()
        } else if !roms.isEmpty {
            Text("\(roms.count) of \(total)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding()
        }
    }

    private func reload() async {
        roms = []
        total = 0
        error = nil
        await loadNextPage()
    }

    private func loadMoreIfNeeded(current rom: Rom) async {
        guard rom.id == roms.last?.id, roms.count < total else { return }
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !loading else { return }
        loading = true
        do {
            switch source {
            case .keptPlatform(_, let kept):
                // No page to fetch: every kept rom for this platform is
                // already known, already on the phone. Assigned
                // directly rather than routed through RomPage, which
                // models a server's paged response, not a plain local
                // array.
                roms = kept
                total = kept.count
            case .platform(let platform):
                let page = try await session.roms(platformId: platform.id, offset: roms.count)
                roms.append(contentsOf: page.items)
                total = page.total
            case .collection(let collection):
                let page = try await session.roms(collectionId: collection.id, offset: roms.count)
                roms.append(contentsOf: page.items)
                total = page.total
            case .recentlyPlayed:
                let page = try await session.recentlyPlayed(limit: 60, offset: roms.count)
                roms.append(contentsOf: page.items)
                total = page.total
            }
        } catch {
            self.error = LoadFailure(error)
        }
        loading = false
    }
}

/// The letter rail on the trailing edge of a long list, the Contacts
/// pattern: touch anywhere on it and drag, and the list jumps to the first
/// title under each letter passed. Jumping is instant rather than animated,
/// because animating through a thousand rows reads as scrolling, and the
/// point of a scrubber is not scrolling.
#if os(iOS)
private struct LetterScrubber: View {
    let letters: [String]
    let onSelect: (String) -> Void

    @State private var height: CGFloat = 0
    @State private var current: String?
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
                    .frame(width: 16)
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard height > 0, !letters.isEmpty else { return }
                    let fraction = min(max(value.location.y / height, 0), 0.999)
                    let letter = letters[Int(fraction * CGFloat(letters.count))]
                    if letter != current {
                        current = letter
                        haptic.selectionChanged()
                        onSelect(letter)
                    }
                }
                .onEnded { _ in current = nil }
        )
        .padding(.trailing, 2)
    }
}
#endif
