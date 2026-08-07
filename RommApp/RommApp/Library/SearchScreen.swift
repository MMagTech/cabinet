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
                        description: Text("Every game on your server, by name.")
                    )
                } else if searching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    resultList
                }
            }
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: "Search all games")
            .searchFocused($fieldFocused)
            .onAppear { fieldFocused = true }
            .task(id: searchText) { await runSearch() }
            .fullScreenCover(item: $playing) { rom in
                NavigationStack { GameLaunchView(rom: rom) }
            }
        }
    }

    private var resultList: some View {
        List {
            ForEach(results) { rom in
                Button {
                    playing = rom
                } label: {
                    HStack(spacing: 12) {
                        CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                            .frame(width: 40, height: 53)
                            .clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rom.displayName)
                                .lineLimit(1)
                            Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .gameContextMenu(rom: rom)
            }
        }
        .listStyle(.plain)
    }

    private func runSearch() async {
        guard !searchText.isEmpty else {
            results = []
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
