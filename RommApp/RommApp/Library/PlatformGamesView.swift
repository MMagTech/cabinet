import SwiftUI

/// The games of one platform, as a cover grid or a compact text list.
///
/// The mode preference persists per platform slug, because arcade sets often
/// have no cover art and a grid of gray tiles is worse than a text list, while
/// console libraries look far better as covers. One preference for both would
/// force a bad default on one of them.
struct PlatformGamesView: View {
    let platform: Platform

    @EnvironmentObject private var session: Session
    @ObservedObject private var compatibility = Compatibility.shared
    @State private var roms: [Rom] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var viewMode: ViewMode
    @State private var playing: Rom?

    enum ViewMode: String {
        case grid, list
    }

    init(platform: Platform) {
        self.platform = platform
        let stored = UserDefaults.standard.string(forKey: Self.modeKey(for: platform.slug))
        _viewMode = State(initialValue: stored.flatMap(ViewMode.init) ?? .grid)
    }

    private static func modeKey(for slug: String) -> String {
        "com.mmagtech.RommApp.viewMode.\(slug)"
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView {
                    Label("Could not load games", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
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
        .navigationTitle(platform.name ?? platform.slug)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Picker("View", selection: $viewMode) {
                    Image(systemName: "square.grid.3x3").tag(ViewMode.grid)
                    Image(systemName: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
            }
        }
        .onChange(of: viewMode) { _, mode in
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey(for: platform.slug))
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

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 12)],
                spacing: 12
            ) {
                ForEach(roms) { rom in
                    Button {
                        playing = rom
                    } label: {
                        VStack(spacing: 6) {
                            CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 10))
                                .compatibilityBadge(romId: rom.id)

                            Text(rom.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(
                                    compatibility.isMarked(rom.id) ? .secondary : .primary
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .compatibilityMenu(romId: rom.id)
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
                    .compatibilityMenu(romId: rom.id)
                    .onAppear { Task { await loadMoreIfNeeded(current: rom) } }
                }

                footer
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            // Room for the rail, or the longest titles run underneath it.
            .contentMargins(.trailing, letterIndex.count > 4 ? 18 : 0, for: .scrollContent)
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
            let page = try await session.roms(platformId: platform.id, offset: roms.count)
            roms.append(contentsOf: page.items)
            total = page.total
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// The letter rail on the trailing edge of a long list, the Contacts
/// pattern: touch anywhere on it and drag, and the list jumps to the first
/// title under each letter passed. Jumping is instant rather than animated,
/// because animating through a thousand rows reads as scrolling, and the
/// point of a scrubber is not scrolling.
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
