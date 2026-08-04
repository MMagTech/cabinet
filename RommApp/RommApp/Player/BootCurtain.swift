import SwiftUI

/// EmulatorJS's own boot status, mirrored out of `.ejs_loading_text` verbatim
/// and split here into a phase and a percentage, never the other way around:
/// the phase text is localized and not safe to pattern match, but a trailing
/// "NN%" is a stable, language independent shape worth pulling out so the
/// progress track below can show real motion instead of guessing at it.
struct LoadingStatus: Equatable {
    let phase: String
    let percent: Double?

    private static let percentPattern = try? NSRegularExpression(pattern: #"\s*(\d{1,3})%\s*$"#)

    init(raw: String) {
        guard let match = Self.percentPattern?.firstMatch(
            in: raw, range: NSRange(raw.startIndex..., in: raw)
        ), let range = Range(match.range(at: 1), in: raw), let value = Double(raw[range]) else {
            phase = raw
            percent = nil
            return
        }
        phase = String(raw[..<Range(match.range, in: raw)!.lowerBound])
        percent = min(1, max(0, value / 100))
    }
}

/// Covers the webview from the moment it starts loading until the game
/// reports started, the same "native curtain over an in-progress webview"
/// technique the crash recovery screen already uses, so RomM's own loading
/// bars never show through. The game's own cover art fills the screen,
/// dimmed under a bottom sheet, the same shape Music and Podcasts use for a
/// now playing sheet: real art, not a synthesized color standing in for it,
/// so there is nothing to get wrong matching a game's actual palette.
struct BootCurtain: View {
    let title: String
    let status: LoadingStatus?
    let platformLabel: String
    /// `pathCoverLarge` falling back to `pathCoverSmall`, the same choice
    /// the launch screen makes.
    let coverPath: String?

    @EnvironmentObject private var session: Session
    @State private var cover: UIImage?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let cover {
                GeometryReader { geometry in
                    Image(uiImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 26)
                        .overlay(Color.black.opacity(0.35))
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.55), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack {
                Spacer()
                sheet
            }
        }
        .task(id: coverPath) { await loadCover() }
    }

    private var sheet: some View {
        HStack(spacing: 14) {
            CoverThumb(image: cover, title: title)
                .frame(width: 46, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let status {
                    Text(status.phase.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                } else {
                    Text(platformLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }

                ProgressTrack(percent: status?.percent)
                    .frame(height: 3)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [.clear, Color(white: 0.07).opacity(0.94), Color(white: 0.05)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func loadCover() async {
        guard cover == nil, let coverPath else { return }
        if let cached = CoverCache.shared.image(forKey: coverPath) {
            cover = cached
            return
        }
        guard let data = try? await session.coverData(path: coverPath), let image = UIImage(data: data) else { return }
        CoverCache.shared.set(image, forKey: coverPath)
        withAnimation(.easeInOut(duration: 0.3)) {
            cover = image
        }
    }
}

/// The sheet's small cover thumbnail. A plain fallback tile rather than
/// nothing while the real art is still in flight or missing entirely, the
/// same reasoning `CoverImage` uses everywhere else in the app.
private struct CoverThumb: View {
    let image: UIImage?
    let title: String

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.12))
                Image(systemName: "gamecontroller")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// An indeterminate sweep, not a hard percentage bar drawn to scale: the
/// mirrored EmulatorJS text does not always carry a reliable percent of
/// total (a decompress phase may report megabytes moved instead), so this
/// only promises "still moving," and switches to a real fill precisely
/// when a percentage has actually arrived.
private struct ProgressTrack: View {
    let percent: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))

                if let percent {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * percent)
                } else {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.8), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * 0.4)
                        .offset(x: sweep ? geometry.size.width * 1.2 : -geometry.size.width * 0.4)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) {
                                sweep = true
                            }
                        }
                }
            }
        }
        .clipShape(Capsule())
    }
}
