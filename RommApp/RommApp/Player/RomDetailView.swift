import SwiftUI

/// Cover hero, one primary action, metadata. Per the scope doc, Play is the
/// only button that matters on this screen.
///
/// Like Home, the layout adapts to orientation: a cover sized for a tall
/// screen fills a short one entirely and pushes Play below the fold, which
/// hides the one control this screen exists for.
struct RomDetailView: View {
    let rom: Rom

    @State private var playing = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ScrollView {
                if landscape {
                    HStack(alignment: .top, spacing: 24) {
                        cover(maxWidth: 200)
                        VStack(alignment: .leading, spacing: 16) {
                            titleBlock(centred: false)
                            playButton
                            details
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 20) {
                        cover(maxWidth: 260)
                            .padding(.top, 12)
                        titleBlock(centred: true)
                        playButton
                        details
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $playing) {
            PlayerView(rom: rom)
        }
    }

    private func cover(maxWidth: CGFloat) -> some View {
        CoverImage(path: rom.pathCoverLarge ?? rom.pathCoverSmall, title: rom.displayName)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: maxWidth)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(radius: 8, y: 4)
    }

    private func titleBlock(centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 4) {
            Text(rom.displayName)
                .font(.title2.bold())
                .multilineTextAlignment(centred ? .center : .leading)
            Text(rom.platformDisplayName ?? rom.platformSlug)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
    }

    private var playButton: some View {
        Button {
            playing = true
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
    }

    @ViewBuilder
    private var details: some View {
        if let summary = rom.summary, !summary.isEmpty {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        LabeledContent("Size") {
            Text(ByteCountFormatter.string(
                fromByteCount: rom.fsSizeBytes, countStyle: .file
            ))
        }
        .font(.callout)
    }
}
