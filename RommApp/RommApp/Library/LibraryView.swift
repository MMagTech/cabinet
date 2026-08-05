import SwiftUI

/// The library: platforms and collections to browse into.
///
/// A tab of its own, reached from the bar rather than pushed from Home.
/// Searching every game lives in `SearchScreen`, its own tab, so this
/// screen is purely about browsing structure.
struct LibraryScreen: View {
    @EnvironmentObject private var session: Session
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var platforms: [Platform] = []
    @State private var loadingPlatforms = true
    @State private var platformsError: LoadFailure?

    @State private var collections: [Collection] = []
    @State private var loadingCollections = true
    @State private var collectionsError: String?

    @State private var browsing: Browsing = .platforms

    @State private var playing: Rom?

    enum Browsing: String, CaseIterable {
        case platforms = "Platforms", collections = "Collections"
    }

    var body: some View {
        Group {
            switch browsing {
            case .platforms: platformList
            case .collections: collectionList
            }
        }
        // The switcher belongs to the bar, not the page. Sitting in the
        // content it was a chrome shaped control marooned in a content
        // shaped place, which read as leftover layout once there were real
        // floating bars above and below it. In the bar it picks up the
        // system's own material and the list scrolls cleanly underneath.
        //
        // The title goes inline and gives its slot to the switcher rather
        // than stacking both: the tab bar already says Library, so a large
        // title would only repeat it while pushing the list further down.
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Browse by", selection: $browsing) {
                    ForEach(Browsing.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
        }
        // No search field here any more: searching every game is its own
        // tab, so a second entry point would be two ways to do one thing,
        // each with its own state.
        .task { await loadPlatforms() }
        .task { await loadCollections() }
        .fullScreenCover(item: $playing) { rom in
            NavigationStack { GameLaunchView(rom: rom) }
        }
    }

    // MARK: Platforms

    private var platformList: some View {
        List {
            if loadingPlatforms {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your library")
                        .foregroundStyle(.secondary)
                }
            } else if platformsError == .offline {
                OfflineNotice { await loadPlatforms() }
                    .listRowBackground(Color.clear)
            } else if let platformsError {
                Text(platformsError.message).foregroundStyle(.red)
                Button("Try again") { Task { await loadPlatforms() } }
            } else {
                if !supportedPlatforms.isEmpty {
                    Section("Supported") {
                        ForEach(supportedPlatforms) { platform in
                            platformRow(platform)
                        }
                    }
                }
                if !unsupportedPlatforms.isEmpty {
                    Section("Unsupported") {
                        ForEach(unsupportedPlatforms) { platform in
                            platformRow(platform)
                        }
                    }
                }
            }
        }
        // Inset rows read as cards floating under the bars, where the full
        // width plain style ran straight into them.
        .listStyle(.insetGrouped)
        .refreshable { await loadPlatforms() }
    }

    private func platformRow(_ platform: Platform) -> some View {
        NavigationLink {
            RomListView(source: .platform(platform))
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

    /// A platform this app can actually put a Play button in front of:
    /// not a keyboard machine, per `ComputerPlatforms`, and RomM's own core
    /// map, `Resources/cores.json`, actually lists a core for it. Dreamcast
    /// and Flash fail this the same way a keyboard machine does, just for a
    /// different reason, no core exists at all rather than no touch input.
    private func isSupported(_ platform: Platform) -> Bool {
        let canonicalSlug = (session.platformsVersions[platform.fsSlug] ?? platform.fsSlug).lowercased()
        return PlatformSupport.isSupported(canonicalSlug: canonicalSlug)
    }

    private var supportedPlatforms: [Platform] { platforms.filter(isSupported) }
    private var unsupportedPlatforms: [Platform] { platforms.filter { !isSupported($0) } }

    private func loadPlatforms() async {
        loadingPlatforms = true
        platformsError = nil
        do {
            platforms = try await session.platforms()
                .sorted { platformLabel(for: $0) < platformLabel(for: $1) }
        } catch {
            platformsError = LoadFailure(error)
            DiagnosticsLog.record(
                context: "Library load", message: error.localizedDescription, romVersion: session.serverVersion
            )
        }
        loadingPlatforms = false
    }

    // MARK: Collections

    private var collectionList: some View {
        List {
            if loadingCollections {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading your collections")
                        .foregroundStyle(.secondary)
                }
            } else if let collectionsError {
                Text(collectionsError).foregroundStyle(.red)
                Button("Try again") { Task { await loadCollections() } }
            } else if collections.isEmpty {
                Text("No collections yet. Make one in RomM to see it here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(collections) { collection in
                    NavigationLink {
                        RomListView(source: .collection(collection))
                    } label: {
                        HStack {
                            Text(collection.name)
                            Spacer()
                            Text("\(collection.romCount)")
                                .foregroundStyle(.secondary)
                                .font(.callout.monospacedDigit())
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await loadCollections() }
    }

    private func loadCollections() async {
        loadingCollections = true
        collectionsError = nil
        do {
            collections = try await session.collections()
                .sorted { $0.name < $1.name }
        } catch {
            collectionsError = error.localizedDescription
        }
        loadingCollections = false
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
}
