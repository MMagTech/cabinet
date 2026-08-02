import SwiftUI

/// The library: platforms to browse into, and search across everything.
///
/// Pushed from Home, which owns the navigation stack and the destinations.
/// Search is server side and debounced, so typing does not fire a request per
/// keystroke and results match what the RomM web UI would find.
struct LibraryScreen: View {
    @EnvironmentObject private var session: Session

    @State private var platforms: [Platform] = []
    @State private var loading = true
    @State private var error: String?

    @State private var searchText = ""
    @State private var searchResults: [Rom] = []
    @State private var searching = false
    @State private var playing: Rom?

    var body: some View {
        Group {
            if !searchText.isEmpty {
                searchList
            } else {
                platformList
            }
        }
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search all games")
        .task(id: searchText) { await runSearch() }
        .task { await loadPlatforms() }
        .fullScreenCover(item: $playing) { rom in
            PlayerView(rom: rom)
        }
    }

    // MARK: Platforms

    private var platformList: some View {
        List {
            if loading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your library")
                        .foregroundStyle(.secondary)
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
                Button("Try again") { Task { await loadPlatforms() } }
            } else {
                ForEach(platforms) { platform in
                    NavigationLink {
                        PlatformGamesView(platform: platform)
                    } label: {
                        HStack {
                            Text(platform.name ?? platform.slug)
                            Spacer()
                            Text("\(platform.romCount)")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
        .readableWidth()
        .refreshable { await loadPlatforms() }
    }

    private func loadPlatforms() async {
        loading = true
        error = nil
        do {
            platforms = try await session.platforms()
                .sorted { ($0.name ?? $0.slug) < ($1.name ?? $1.slug) }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    // MARK: Search

    private var searchList: some View {
        List {
            if searching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching")
                        .foregroundStyle(.secondary)
                }
            } else if searchResults.isEmpty {
                Text("Nothing matched.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchResults) { rom in
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
                                Text(rom.platformSlug)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .readableWidth()
    }

    private func runSearch() async {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }

        // The debounce. Typing again cancels this task and restarts the clock.
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }

        searching = true
        if let page = try? await session.roms(searchTerm: searchText) {
            searchResults = page.items
        }
        searching = false
    }
}
