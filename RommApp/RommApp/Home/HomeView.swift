import SwiftUI

/// The launch screen. Resume first, not a library grid: the last game you
/// played, large, one tap back in. The library is a room you walk into from
/// here, not the front door.
struct HomeView: View {
    @EnvironmentObject private var session: Session

    @State private var recent: [Rom] = []
    @State private var loaded = false
    @State private var resuming: Rom?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let hero = recent.first {
                        heroCard(for: hero)

                        if recent.count > 1 {
                            rotationRow(Array(recent.dropFirst()))
                        }
                    } else if loaded {
                        emptyState
                    }

                    NavigationLink {
                        LibraryScreen()
                    } label: {
                        HStack {
                            Label("Browse the library", systemImage: "square.grid.2x2")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .fullScreenCover(item: $resuming) { rom in
                PlayerView(rom: rom)
            }
            // Coming back from the player means the rotation changed.
            .onChange(of: resuming == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
        }
    }

    // MARK: Hero, the one-tap resume

    private func heroCard(for rom: Rom) -> some View {
        Button {
            resuming = rom
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                CoverImage(path: rom.pathCoverLarge ?? rom.pathCoverSmall, title: rom.displayName)
                    .aspectRatio(3.0 / 4.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.75)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rom.displayName)
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                                .lineLimit(2)
                            Text(rom.platformDisplayName ?? rom.platformSlug)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .padding(16)
                    }
                    .overlay(alignment: .topTrailing) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: .capsule)
                            .padding(12)
                    }
            }
            .clipShape(.rect(cornerRadius: 18))
            .shadow(radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }

    // MARK: The current rotation

    private func rotationRow(_ roms: [Rom]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep playing")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(roms) { rom in
                        NavigationLink {
                            RomDetailView(rom: rom)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                    .frame(width: 100, height: 133)
                                    .clipShape(.rect(cornerRadius: 10))
                                Text(rom.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing on the go yet")
                .font(.title3.bold())
            Text("Pick a game from the library. Whatever you play last shows up here for one tap resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
    }

    private func load() async {
        if let roms = try? await session.recentlyPlayed() {
            recent = roms
        }
        loaded = true
    }
}
