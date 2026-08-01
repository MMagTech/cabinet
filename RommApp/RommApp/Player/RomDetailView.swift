import SwiftUI

/// Cover hero, one primary action, metadata. Per the scope doc, Play is the
/// only button that matters on this screen.
struct RomDetailView: View {
    let rom: Rom

    @State private var playing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                CoverImage(path: rom.pathCoverLarge ?? rom.pathCoverSmall, title: rom.displayName)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .frame(maxWidth: 260)
                    .clipShape(.rect(cornerRadius: 14))
                    .shadow(radius: 8, y: 4)
                    .padding(.top, 12)

                VStack(spacing: 4) {
                    Text(rom.displayName)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text(rom.platformDisplayName ?? rom.platformSlug)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    playing = true
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)

                if let summary = rom.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                }

                LabeledContent("Size") {
                    Text(ByteCountFormatter.string(
                        fromByteCount: rom.fsSizeBytes, countStyle: .file
                    ))
                }
                .font(.callout)
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 32)
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $playing) {
            PlayerView(rom: rom)
        }
    }
}
