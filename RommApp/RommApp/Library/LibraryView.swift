import SwiftUI

/// The library root: platforms to browse into, and search across everything.
///
/// Search is server side and debounced, so typing does not fire a request per
/// keystroke and results match what the RomM web UI would find.
struct LibraryView: View {
    @EnvironmentObject private var session: Session

    @State private var platforms: [Platform] = []
    @State private var loading = true
    @State private var error: String?

    @State private var searchText = ""
    @State private var searchResults: [Rom] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
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
        }
    }

    // MARK: Platforms

    private var platformList: some View {
        List {
            Section {
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
                        NavigationLink(value: platform) {
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

        }
        .navigationDestination(for: Platform.self) { platform in
            PlatformGamesView(platform: platform)
        }
        .navigationDestination(for: Rom.self) { rom in
            RomDetailView(rom: rom)
        }
        .refreshable { await loadPlatforms() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
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
                    NavigationLink(value: rom) {
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
