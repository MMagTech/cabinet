//  Downloaded, the Mac's view of what is kept on this machine.
//
//  The phone reaches its kept games through an airplane in the bar,
//  because on a phone "no signal" is the situation that makes them
//  matter. A Mac has no such moment. What it has is a source list, and
//  Downloaded is a source: the games whose files are on this disk,
//  shown as the platforms that have some, each opening the same grid
//  live browsing uses, so a downloaded game is played exactly the way
//  any other is.
//
//  The platforms are Library's own tiles, four across, art from the
//  kept games themselves. Tried first as plain rows, which read as an
//  iOS list dropped into a Mac window with no heading; and as one grid
//  of games with a section per platform, which Marcus found unlike the
//  platform screens. Library's shape, then the platform's grid, is what
//  the sidebar's own platform rows already do.
//
//  Reads KeptGameStore's own grouping, the one OfflineLibraryView on
//  the phone reads, so the two can never disagree about what is kept.

import SwiftUI

struct MacDownloadedView: View {
    @ObservedObject private var keptStore = KeptGameStore.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue

    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    private var platforms: [(platform: Platform, roms: [Rom])] {
        keptStore.offlinePlatforms()
            .sorted { label(for: $0.platform) < label(for: $1.platform) }
    }

    private func label(for platform: Platform) -> String {
        let metadataName = platform.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let folderName = platform.fsSlug.isEmpty ? nil : platform.fsSlug
        switch labelSource {
        case .platformName: return metadataName ?? folderName ?? platform.slug
        case .folderName: return folderName ?? metadataName ?? platform.slug
        }
    }

    var body: some View {
        ScrollView {
            // Drawn here, as RomListView draws its own on the Mac: the
            // window's title bar is hidden, so navigationTitle shows
            // nowhere.
            HStack {
                Text("Downloaded")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(.horizontal, TenFoot.contentInset)
            .padding(.top, 16)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 10) {
                ForEach(platforms, id: \.platform.id) { entry in
                    NavigationLink {
                        RomListView(source: .keptPlatform(entry.platform, entry.roms))
                    } label: {
                        PlatformTile(
                            title: label(for: entry.platform),
                            count: entry.roms.count,
                            covers: entry.roms.compactMap(\.pathCoverSmall).filter { !$0.isEmpty }
                        )
                    }
                    .buttonStyle(.plain)
                    // The platform's own menu, minus Download All: what
                    // is here is already downloaded.
                    .contextMenu {
                        MacPlatformMenu(platform: entry.platform, label: label(for: entry.platform), offersDownloadAll: false)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}
