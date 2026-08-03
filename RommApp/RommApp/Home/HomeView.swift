import SwiftUI

/// The launch screen. Resume first, not a library grid: the last game you
/// played, large, one tap back in. The library is a room you walk into from
/// here, not the front door.
///
/// The layout adapts to orientation rather than assuming portrait. A hero
/// sized for a tall screen fills a short one completely, hiding the rotation
/// shelf and the library entirely, so in landscape the hero becomes a wide
/// card and the rest sits beside it.
struct HomeView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var compatibility = Compatibility.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var recent: [Rom] = []
    @State private var loaded = false
    @State private var resuming: Rom?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                ScrollView {
                    if landscape {
                        wideLayout(height: geometry.size.height)
                    } else {
                        tallLayout
                    }
                }
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
                NavigationStack { GameLaunchView(rom: rom) }
            }
            .onChange(of: resuming == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
        }
    }

    // MARK: Layouts

    private var tallLayout: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let hero = recent.first {
                heroCard(for: hero, height: 360, wide: false)
                if recent.count > 1 {
                    rotationRow(Array(recent.dropFirst()))
                }
            } else if loaded {
                emptyState
            }
            libraryLink
        }
        .padding(20)
    }

    /// Landscape: the hero takes the left, everything else stacks to its
    /// right, so nothing is pushed off a screen that is short but wide.
    private func wideLayout(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let hero = recent.first {
                heroCard(for: hero, height: max(200, height - 40), wide: true)
                    .frame(maxWidth: 320)
            }

            VStack(alignment: .leading, spacing: 20) {
                if recent.count > 1 {
                    rotationRow(Array(recent.dropFirst()))
                } else if loaded, recent.isEmpty {
                    emptyState
                }
                libraryLink
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    // MARK: Pieces

    private func heroCard(for rom: Rom, height: CGFloat, wide: Bool) -> some View {
        Button {
            resuming = rom
        } label: {
            // The frame you left on, when the player has recorded one, per
            // the scope doc's Home. Box art is the fallback, not the point:
            // the hero is your game mid-moment, inviting you back into it.
            Group {
                if let frame = LastFrame.image(romId: rom.id) {
                    Image(uiImage: frame)
                        .resizable()
                } else {
                    CoverImage(
                        path: rom.pathCoverLarge ?? rom.pathCoverSmall,
                        title: rom.displayName
                    )
                }
            }
                .aspectRatio(3.0 / 4.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: height)
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
                            .font(wide ? .headline : .title2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                            .font(wide ? .caption : .subheadline)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(wide ? 12 : 16)
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
                .clipShape(.rect(cornerRadius: 18))
                .shadow(radius: 10, y: 5)
        }
        .buttonStyle(.plain)
    }

    private func rotationRow(_ roms: [Rom]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep playing")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(roms) { rom in
                        Button {
                            resuming = rom
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                    .frame(width: 100, height: 133)
                                    .clipShape(.rect(cornerRadius: 10))
                                    .compatibilityBadge(romId: rom.id, compact: true)
                                Text(rom.displayName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 100, alignment: .leading)
                                    .foregroundStyle(
                                        compatibility.isMarked(rom.id) ? .secondary : .primary
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .compatibilityMenu(romId: rom.id)
                    }
                }
            }
        }
    }

    private var libraryLink: some View {
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing on the go yet")
                .font(.title3.bold())
            Text("Pick a game from the library. Whatever you play last shows up here for one tap resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        if let roms = try? await session.recentlyPlayed() {
            recent = roms
        }
        loaded = true
    }
}
