import SwiftUI

/// The one offline view, shown wherever the app has reason to show one,
/// Home and the library both. Not two screens each drawing their own
/// version of the same idea: Home's own resume-first "Kept games" list
/// and the library's platform-grouped one used to be separately
/// maintained copies of the identical underlying data, and Marcus
/// caught it the moment he compared them side by side, 2026-08-07: "why
/// would the two need to exist... we just need a home."
///
/// Kept, native-capable games grouped by platform, each opening into the
/// exact grid or list screen live browsing already uses, badges and
/// context menu included. Webview-only kept games are excluded: their
/// player still needs the server to start, so listing them would set up
/// a tap that fails regardless of what is actually stored. Nothing kept
/// yet falls through to the same `OfflineNotice` every other empty state
/// in this app already uses, so a launch with nothing downloaded still
/// gets an honest, familiar answer rather than a browsing screen with
/// nothing in it.
struct OfflineLibraryView: View {
    /// What to retry when `OfflineNotice`'s button is tapped: each host
    /// screen's own load, so a real reconnect refreshes it correctly
    /// rather than this view guessing at one.
    let onRetry: () async -> Void

    @ObservedObject private var keptStore = KeptGameStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    /// `KeptGameStore`'s own grouping is slug-ordered, since it has no
    /// way to know which label source this particular view prefers;
    /// re-sorted here by whichever label is actually on screen, or rows
    /// would visibly appear out of order.
    private var platforms: [(platform: Platform, roms: [Rom])] {
        keptStore.offlinePlatforms()
            .sorted { platformLabel(for: $0.platform) < platformLabel(for: $1.platform) }
    }

    /// Same fallback order as `Rom.platformLabel`, one rung shorter: a
    /// platform has no per-rom display name to fall through, only its
    /// curated name, its folder name, and the slug last of all.
    private func platformLabel(for platform: Platform) -> String {
        let metadataName = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let folderName = platform.fsSlug.isEmpty ? nil : platform.fsSlug
        switch labelSource {
        case .platformName: return metadataName ?? folderName ?? platform.slug
        case .folderName: return folderName ?? metadataName ?? platform.slug
        }
    }

    var body: some View {
        if platforms.isEmpty {
            ScrollView {
                OfflineNotice(retry: onRetry)
                    .frame(maxWidth: .infinity, minHeight: 400)
            }
        } else {
            List {
                Section {
                    ForEach(platforms, id: \.platform.id) { entry in
                        NavigationLink {
                            RomListView(source: .keptPlatform(entry.platform, entry.roms))
                        } label: {
                            HStack {
                                Text(platformLabel(for: entry.platform))
                                Spacer()
                                Text("\(entry.roms.count)")
                                    .foregroundStyle(.secondary)
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                } header: {
                    Label(networkMonitor.offlineReason.label, systemImage: networkMonitor.offlineReason.systemImage)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
