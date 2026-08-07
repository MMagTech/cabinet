import SwiftUI

/// Everything this app has on disk, in one place: kept games (permanent,
/// deliberate, the offline promise) and the web player's own cache
/// (automatic, evictable, rebuildable). Formerly CacheView, renamed when
/// kept games arrived: "Cache" stopped being an honest title the moment
/// the screen held things that are explicitly not a cache, and Storage
/// is what iOS itself calls this job.
struct StorageView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var keptStore = KeptGameStore.shared
    @StateObject private var bridge = EmulatorCacheBridge()
    @State private var cacheLimitBytes: Int64?
    @State private var confirmingClearAll = false
    @State private var deletingKeys: Set<String> = []

    private var totalBytes: Int {
        bridge.files.reduce(0) { $0 + $1.fileSize }
    }

    /// EmulatorJS 4.2.3's own default (`cacheLimit ?? 1073741824`), used
    /// whenever RomM's server hasn't set `emulatorjs.cache_limit` at all.
    private static let defaultLimitBytes: Int64 = 1024 * 1024 * 1024

    private var limitBytes: Int64 {
        cacheLimitBytes ?? Self.defaultLimitBytes
    }

    var body: some View {
        List {
            // Kept games live in this app's own storage, not the webview
            // cache below, so the section renders regardless of whether
            // the bridge ever comes up. Same screen on purpose: storage
            // lives in one place, but the semantics differ, caches serve
            // speed, kept games serve a promise, hence no shared total
            // and no shared clear-all.
            if !keptStore.games.isEmpty {
                Section {
                    ForEach(keptStore.games) { game in
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
                    Text("\(byteCount(keptStore.totalBytes)) kept. These files also appear in the Files app, under Cabinet, Kept Games, where you can copy them to other apps; deleting one there removes it here too. Nothing clears on its own.")
                }
            }

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
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(byteCount(Int64(totalBytes))).fontWeight(.semibold)
                            Spacer()
                            Text("of \(byteCount(limitBytes))").foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        ProgressView(value: min(Double(totalBytes) / Double(limitBytes), 1))
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text(
                        "The web player's own cache. Games larger than the limit play fine but aren't cached for next time. Cached files stay until you remove them here, and removing one never touches a kept game."
                    )
                }

                if bridge.files.isEmpty {
                    Section {
                        Text("Nothing is cached yet. The web player adds games automatically when you play them, and keeping a game copies it in so playing skips the download.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(bridge.files) { file in
                            row(for: file)
                        }
                    } header: {
                        Text("Web player cache")
                    }

                    Section {
                        Button("Clear all cached files", role: .destructive) {
                            confirmingClearAll = true
                        }
                        // Attached here, not at the screen root: a
                        // confirmationDialog anchors its arrow to whatever
                        // view carries this modifier, so it has to sit on
                        // the actual button, or the arrow points at the
                        // wrong place. Same fix as the download icon in
                        // GameLaunchView.
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
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
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
