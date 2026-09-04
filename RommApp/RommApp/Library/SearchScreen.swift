import SwiftUI

/// Search across every game on the server, its own tab rather than a field
/// buried inside the library.
///
/// Looking for one specific game is a different intent from browsing
/// platforms, and it was previously two taps and a reach to the far top
/// corner away. As a tab it is one thumb tap from anywhere in the app.
///
/// The field takes focus on appear, so the keyboard is already up: there is
/// nothing else on this screen to look at, so holding the keyboard back
/// would only cost a second tap to reach the obvious next step. Apps whose
/// search screen doubles as a browse surface (suggestions, recent searches,
/// categories) are right not to do this; this one has no such surface.
struct SearchScreen: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var keptStore = KeptGameStore.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var searchText = ""
    @State private var results: [Rom] = []
    @State private var searching = false
    @State private var offline = false
    @State private var playing: Rom?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if offline {
                    OfflineNotice { await runSearch() }
                } else if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search your library",
                        systemImage: "magnifyingglass",
                        description: Text(
                            networkMonitor.isOffline
                                ? "Every kept game, by name."
                                : "Every game on your server, by name."
                        )
                    )
                } else if searching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    #if targetEnvironment(macCatalyst)
                    resultGrid
                    #else
                    resultList
                    #endif
                }
            }
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: networkMonitor.isOffline ? "Search kept games" : "Search all games")
            #if os(iOS)
            .searchFocused($fieldFocused)
            .onAppear { fieldFocused = true }
            #endif
            .task(id: searchText) { await runSearch() }
            // Live, matching everywhere else Offline Mode touches
            // tonight: stale online results should not sit on screen
            // once the toggle flips, and typed text should not need to
            // be re-entered to see it re-scoped to what is kept.
            .onChange(of: networkMonitor.isOffline) { _, _ in Task { await runSearch() } }
            #if targetEnvironment(macCatalyst)
            .navigationDestination(item: $playing) { rom in
                GameLaunchView(rom: rom)
            }
            #else
            .fullScreenCover(item: $playing) { rom in
                #if os(iOS)
                NavigationStack { GameLaunchView(rom: rom) }
                #else
                TVGameLaunchView(rom: rom)
                #endif
            }
            #endif
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Search results as cover art, the way the library and Home show
    /// games on this platform.
    ///
    /// The shared list is a phone result list: a 40pt thumbnail and two
    /// lines of text per row, which on a desk-sized window left a
    /// handful of tiny rows in one corner of an empty screen. The
    /// covers are the thing you actually recognise a game by, and this
    /// screen is the one place in the app that was still showing them
    /// at postage-stamp size.
    ///
    /// Same grid metrics, same badges, same hover lift and context menu
    /// as `RomListView`, so a game found by searching looks and behaves
    /// exactly like the same game found by browsing.
    private var resultGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: TenFoot.gridCoverMinimum), spacing: TenFoot.gridSpacing)],
                spacing: TenFoot.gridSpacing
            ) {
                ForEach(results) { rom in
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
                            VStack(spacing: 1) {
                                Text(rom.displayName)
                                    .font(TenFoot.captionFont)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                // Searching crosses every platform at
                                // once, so unlike a platform's own grid
                                // this has to say which machine a result
                                // belongs to.
                                Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .macHoverLift()
                    .gameContextMenu(rom: rom)
                }
            }
            .padding(.horizontal, TenFoot.contentInset)
            .padding(.vertical, 16)
        }
    }
    #endif

    private var resultList: some View {
        List {
            ForEach(results) { rom in
                Button {
                    playing = rom
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                            .frame(
                                width: TenFoot.isTV ? 90 : 40,
                                height: TenFoot.isTV ? 120 : 53
                            )
                            .clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rom.displayName)
                                .font(TenFoot.isTV ? .title3 : .body)
                                .lineLimit(1)
                            Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                                .font(TenFoot.isTV ? .callout : .caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .gameContextMenu(rom: rom)
            }
        }
        .macTransparentList()
        .listStyle(.plain)
    }

    private func runSearch() async {
        guard !searchText.isEmpty else {
            results = []
            offline = false
            return
        }

        // Real suppression, not a cosmetic switch, matching everywhere
        // else Offline Mode touches tonight: this never reaches the
        // network at all while it's on, even though the connection
        // underneath might genuinely be fine. Instant, no debounce,
        // since filtering an array already on the phone has no server
        // to spare; a kept game either matches the text or it does not,
        // the same honest "no results" screen a real search with
        // nothing found already shows, not OfflineNotice, which implies
        // a retry would help when nothing here needs one. Only
        // native-capable kept games, the rule used everywhere else
        // tonight: a webview-only kept game's player still needs the
        // server, so surfacing it here would set up a tap that fails.
        guard !networkMonitor.isOffline else {
            results = keptStore.games
                .filter { NativeCore.core(bySlug: $0.resolvedCanonicalSlug, isArcade: $0.rom.isArcade) != nil }
                .map(\.rom)
                .filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            offline = false
            return
        }

        // The debounce. Typing again cancels this task and restarts the clock.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        searching = true
        do {
            results = try await session.roms(searchTerm: searchText).items
            offline = false
        } catch RommError.offline {
            offline = true
        } catch {
            results = []
        }
        searching = false
    }
}
