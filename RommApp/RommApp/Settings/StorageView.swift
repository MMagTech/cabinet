import SwiftUI

/// Everything this app has on disk, in one place: kept games (permanent,
/// deliberate, the offline promise) and the web player's own cache
/// (automatic, evictable, rebuildable). Formerly CacheView, renamed when
/// kept games arrived: "Cache" stopped being an honest title the moment
/// the screen held things that are explicitly not a cache, and Storage
/// is what iOS itself calls this job.
struct StorageView: View {
    enum Category: String, CaseIterable {
        case kept = "Kept"
        case cached = "Cached"
    }

    @EnvironmentObject private var session: Session
    @ObservedObject private var keptStore = KeptGameStore.shared
    @StateObject private var bridge = EmulatorCacheBridge()
    @State private var cacheLimitBytes: Int64?
    @State private var confirmingClearAll = false
    @State private var deletingKeys: Set<String> = []
    @State private var searchText = ""
    @State private var category: Category = .kept

    private var totalBytes: Int {
        bridge.files.reduce(0) { $0 + $1.fileSize }
    }

    /// A kept library can run long enough that scrolling to find one game
    /// stops being reasonable, even though the list itself renders fine at
    /// any size, `List` is already lazy. Filters both sections rather than
    /// just kept games, since the cache list can grow long too.
    private var filteredKeptGames: [KeptGame] {
        guard !searchText.isEmpty else { return keptStore.games }
        return keptStore.games.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredCacheFiles: [CachedFile] {
        guard !searchText.isEmpty else { return bridge.files }
        return bridge.files.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    /// EmulatorJS 4.2.3's own default (`cacheLimit ?? 1073741824`), used
    /// whenever RomM's server hasn't set `emulatorjs.cache_limit` at all.
    private static let defaultLimitBytes: Int64 = 1024 * 1024 * 1024

    private var limitBytes: Int64 {
        cacheLimitBytes ?? Self.defaultLimitBytes
    }

    var body: some View {
        List {
            // The at-a-glance picture, first, before either itemized list:
            // matches iOS's own iPhone Storage screen, total first, detail
            // after. Kept games gets a plain number, never a bar, there is
            // no ceiling to show progress against, that is the design.
            // Cache gets a bar because it is the one category with a real
            // limit. Each number appears exactly once on screen; the
            // sections below explain behaviour, not repeat the total.
            Section {
                if keptStore.totalBytes > 0 {
                    HStack {
                        Text("Kept")
                        Spacer()
                        Text(byteCount(keptStore.totalBytes)).foregroundStyle(.secondary)
                    }
                }
                if bridge.isReady, bridge.loadError == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Cached")
                            Spacer()
                            Text("\(byteCount(Int64(totalBytes))) of \(byteCount(limitBytes))")
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: min(Double(totalBytes) / Double(limitBytes), 1))
                    }
                    .padding(.vertical, keptStore.totalBytes > 0 ? 4 : 0)
                }
            }

            // The picker decides which single category is on screen below,
            // so search only ever touches whichever one you're looking at,
            // and the other one isn't just filtered out, it isn't rendered
            // at all. Two options, not three: no combined view, matching
            // how Library's Platforms/Collections picker works, one or the
            // other, never both at once.
            Section {
                Picker("Category", selection: $category) {
                    ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if category == .kept {
                // A platform coming down, with its cancel, above the
                // games it has landed so far.
                if keptStore.bulk != nil {
                    Section { DownloadAllStatusContent() }
                }
                // Kept games live in this app's own storage, not the
                // webview cache below, so this renders regardless of
                // whether the bridge ever comes up. Storage lives in one
                // place, but the semantics differ, caches serve speed,
                // kept games serve a promise, hence no shared total and no
                // shared clear-all.
                if keptStore.games.isEmpty {
                    Section {
                        Text("Nothing kept yet. Turn on Download on a game's page to copy it in and play it without a download next time.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if !filteredKeptGames.isEmpty {
                    Section {
                        ForEach(filteredKeptGames) { game in
                            HStack(spacing: 12) {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(game.displayName)
                                        .lineLimit(1)
                                    Text(byteCount(game.totalBytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    let pending = keptStore.pendingStateCount(for: game.romId)
                                    if pending > 0 {
                                        Text("\(pending) save\(pending == 1 ? "" : "s") waiting to upload")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if MemoryCardStore.shared.anyPendingUpload(romId: game.romId) {
                                        Text("In-game save waiting to upload")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    keptStore.remove(romId: game.romId)
                                }
                            }
                        }
                    } header: {
                        Text("Kept games")
                    } footer: {
                        Text("These files also appear in the Files app, laid out like your RomM library; copy them to other apps from there. Deleting one there removes it here too. Nothing clears on its own.")
                    }
                }
            } else {
                if let error = bridge.loadError {
                    Section {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                } else if !bridge.isReady {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking the cache").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    if bridge.files.isEmpty {
                        Section {
                            Text("Nothing is cached yet. The web player adds games automatically when you play them, and keeping a game copies it in so playing skips the download.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // The clear-all action always covers everything
                        // cached, search or no search, so its section stays
                        // outside the filtered check below rather than
                        // disappearing along with the rows a search
                        // happens to hide.
                        if !filteredCacheFiles.isEmpty {
                            Section {
                                ForEach(filteredCacheFiles) { file in
                                    row(for: file)
                                }
                            } header: {
                                Text("Web player cache")
                            } footer: {
                                Text("Games larger than the limit play fine but aren't cached for next time. Cached files stay until you remove them here, and removing one never touches a kept game.")
                            }
                        }

                        Section {
                            Button("Clear all cached files", role: .destructive) {
                                confirmingClearAll = true
                            }
                            // Attached here, not at the screen root: a
                            // confirmationDialog anchors its arrow to
                            // whatever view carries this modifier, so it
                            // has to sit on the actual button, or the arrow
                            // points at the wrong place. Same fix as the
                            // download icon in GameLaunchView.
                            .confirmationDialog(
                                "Clear all cached files?", isPresented: $confirmingClearAll, titleVisibility: .visible
                            ) {
                                Button("Clear all", role: .destructive) {
                                    Task { await bridge.deleteAll() }
                                }
                            } message: {
                                Text("Web player games will re-download their ROM the next time you play. Kept games are not touched.")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: category == .kept ? "Find a kept game" : "Find a cached file")
        .background {
            if let serverURL = session.serverURL {
                EmulatorCacheWebView(url: serverURL, bridge: bridge)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .task {
            keptStore.reconcileFilesFolder()
            if let bytes = try? await session.cacheLimitBytes() {
                cacheLimitBytes = bytes
            }
        }
        .onChange(of: bridge.isReady) { _, ready in
            if ready { Task { await bridge.refresh() } }
        }
        .onChange(of: bridge.loadError) { _, error in
            if let error {
                DiagnosticsLog.record(context: "Cache", message: error, romVersion: session.serverVersion)
            }
        }
    }

    private func row(for file: CachedFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(for: file.type))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .lineLimit(1)
                Text("\(file.type.uppercased()) · \(byteCount(Int64(file.fileSize)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                Task {
                    deletingKeys.insert(file.key)
                    await bridge.delete(file)
                    deletingKeys.remove(file.key)
                }
            }
        }
        .opacity(deletingKeys.contains(file.key) ? 0.4 : 1)
    }

    private func iconName(for type: String) -> String {
        switch type.lowercased() {
        case "rom": return "square.and.arrow.down"
        case "bios": return "memorychip"
        case "core": return "cpu"
        default: return "doc"
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
