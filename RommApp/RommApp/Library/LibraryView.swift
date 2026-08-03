import SwiftUI

/// The library: platforms to browse into, and search across everything.
///
/// Pushed from Home, which owns the navigation stack and the destinations.
/// Search is server side and debounced, so typing does not fire a request per
/// keystroke and results match what the RomM web UI would find.
struct LibraryScreen: View {
    @EnvironmentObject private var session: Session
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

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
            NavigationStack { GameLaunchView(rom: rom) }
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
                            Text(platformLabel(for: platform))
                            Spacer()
                            Text("\(platform.romCount)")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
        .refreshable { await loadPlatforms() }
    }

    private func loadPlatforms() async {
        loading = true
        error = nil
        do {
            platforms = try await session.platforms()
                .sorted { platformLabel(for: $0) < platformLabel(for: $1) }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    /// Same choice as `Rom.platformLabel`, for a `Platform` itself rather
    /// than a rom: no per-rom display name to fall through, only the
    /// metadata name and the folder it was scanned from.
    private func platformLabel(for platform: Platform) -> String {
        let metadataName = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let folderName = platform.fsSlug.isEmpty ? nil : platform.fsSlug
        switch labelSource {
        case .platformName: return metadataName ?? folderName ?? platform.slug
        case .folderName: return folderName ?? metadataName ?? platform.slug
        }
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
                                Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
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
