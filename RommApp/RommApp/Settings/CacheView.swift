import SwiftUI

/// What EmulatorJS itself has stored on this device, independent of RomM:
/// every ROM and BIOS file the player has ever cached into
/// `EmulatorJS-roms`, with a way to see how much room it's using and clear
/// individual entries or all of them.
struct CacheView: View {
    @EnvironmentObject private var session: Session
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
                        "Games larger than the limit play fine but aren't kept for next time. Cached files stay until you remove them here."
                    )
                }

                if bridge.files.isEmpty {
                    Section {
                        Text("Nothing is cached yet. Games are added automatically when you play them, or with Data Saver in a game's download menu.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(bridge.files) { file in
                            row(for: file)
                        }
                    } header: {
                        Text("Cached files")
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
                            Text("Games will need to re-download their ROM the next time you play, even on a good connection.")
                        }
                    }
                }
            }
        }
        .navigationTitle("Cache")
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
