#if os(tvOS)
import SwiftUI

/// A grid of games for one platform, collection, or Home rail, written for
/// a TV rather than adapted from iOS's `RomListView`.
///
/// The adapted version had three problems that all trace to reusing iOS
/// chrome: `.navigationTitle` rendered the title *over* the artwork rather
/// than above it (Favorites appeared as a watermark across the covers),
/// the grid ran under the tab bar with no top inset, and 3:4 covers with a
/// single-line caption truncated almost every title to "Alien Homi…". Here
/// the title is a plain view at the top of the scroll content, the grid
/// gets real insets, and captions get two lines to work with.
struct TVRomGridView: View {
    let source: RomListView.Source

    @EnvironmentObject private var session: Session
    @ObservedObject private var compatibility = Compatibility.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    @State private var roms: [Rom] = []
    @State private var total = 0
    @State private var loading = false
    @State private var failed = false
    @State private var playing: Rom?

    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    private var title: String {
        switch source {
        case .platform(let platform), .keptPlatform(let platform, _):
            let metadata = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
            return metadata ?? (platform.fsSlug.isEmpty ? platform.slug : platform.fsSlug)
        case .collection(let collection): return collection.name
        case .recentlyPlayed: return "Recent"
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 48)]
    /// Which card holds focus, for the caption slide.
    @FocusState private var focusedRom: Int?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 44) {
                Section {
                    ForEach(roms) { rom in
                        card(for: rom)
                            .task { await loadMoreIfNeeded(current: rom) }
                    }
                } header: {
                    // In the grid's own header rather than
                    // .navigationTitle, which on tvOS draws over the
                    // content instead of reserving space above it.
                    //
                    // The title sits in a static glass chip, not a plain
                    // label: this screen is reached from Home's "Recent"
                    // and "Favorites" links, which are not a toggle the
                    // way Library's Platforms/Collections switcher is,
                    // but landing here on a bare Text right after Library
                    // trained the eye to expect a glass pill for "which
                    // mode am I in" read as an inconsistency, not a
                    // simplification. Same material, no button behind it.
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        HStack(spacing: 10) {
                            Text(title)
                                .font(.system(size: 40, weight: .bold))
                            if total > 0 {
                                Text("\(total) games")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background {
                            if #available(tvOS 26.0, *) {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(.regular, in: Capsule())
                            } else {
                                Capsule().fill(.white.opacity(0.12))
                            }
                        }
                        Spacer()
                    }
                    .padding(.bottom, 24)
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 40)
            .padding(.bottom, 60)

            if loading {
                ProgressView().padding(.vertical, 40)
            }
            if failed, roms.isEmpty {
                VStack(spacing: 20) {
                    Text("Couldn't load games")
                        .font(.title2)
                    Button("Try again") { Task { await reload() } }
                }
                .padding(.vertical, 60)
            }
        }
        .task { await reload() }
        .fullScreenCover(item: $playing) { rom in
            TVGameLaunchView(rom: rom)
        }
    }

    private func card(for rom: Rom) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                playing = rom
            } label: {
                CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 12))
                    .compatibilityBadge(romId: rom.id)
                    .favoriteBadge(romId: rom.id)
            }
            .buttonStyle(CoverFocusStyle())
            .focused($focusedRom, equals: rom.id)
            // The same menu the Home shelves already carry: hold Select
            // on a cover to favourite it or mark it not working. The grid
            // has always DRAWN the incompatible badge and dimmed a marked
            // title without ever offering a way to set one.
            .gameContextMenu(rom: rom)

            // Two lines, not one: at this width a single line truncated
            // almost every real title. Fixed height so the grid rows stay
            // aligned whether a title wraps or not.
            Text(rom.displayName)
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(compatibility.isMarked(rom.id) ? .secondary : .primary)
                // Rides down with the focused card's lift; see
                // coverCaptionSlide in TVCoverFocus.swift. Nominal shelf
                // cover height is close enough across this grid's
                // adaptive column range.
                .coverCaptionSlide(
                    active: focusedRom == rom.id,
                    coverHeight: TenFoot.shelfCoverHeight
                )
        }
    }

    private func reload() async {
        roms = []
        total = 0
        failed = false
        await loadNextPage()
    }

    private func loadMoreIfNeeded(current rom: Rom) async {
        guard let last = roms.last, last.id == rom.id else { return }
        guard total == 0 || roms.count < total else { return }
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            switch source {
            case .platform(let platform):
                let page = try await session.roms(platformId: platform.id, offset: roms.count)
                roms += page.items
                total = page.total
            case .collection(let collection):
                let page = try await session.roms(collectionId: collection.id, offset: roms.count)
                roms += page.items
                total = page.total
            case .recentlyPlayed:
                let page = try await session.recentlyPlayed(limit: 60, offset: roms.count)
                roms += page.items
                total = page.total
            case .keptPlatform(_, let kept):
                roms = kept
                total = kept.count
            }
        } catch {
            failed = true
        }
    }
}
#endif
