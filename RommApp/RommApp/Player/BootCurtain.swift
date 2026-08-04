import SwiftUI

/// EmulatorJS's own boot status, mirrored out of `.ejs_loading_text` verbatim
/// and split here into a phase and a percentage, never the other way around:
/// the phase text is localized and not safe to pattern match, but a trailing
/// "NN%" is a stable, language independent shape worth pulling out so the
/// bulb row below can show real progress instead of guessing at it.
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
/// technique the crash recovery screen already uses. A cabinet marquee
/// warming up, not RomM's own loading bars: a row of bulbs stands in for a
/// progress bar, chasing when no real percentage has arrived yet and lit to
/// the real count once one has, and the status line underneath is
/// EmulatorJS's own phase text, not decoration, with the percentage cut off
/// since the bulbs already say that part.
struct BootCurtain: View {
    let title: String
    let status: LoadingStatus?

    private let bulbCount = 10
    @State private var glowPulse = false
    @State private var chaseIndex = 0

    private let chaseTimer = Timer.publish(every: 0.18, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(red: 0.13, green: 0.07, blue: 0.10), Color(red: 0.04, green: 0.03, blue: 0.035), .black],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 10,
                endRadius: 340
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 1, green: 0.42, blue: 0.24).opacity(0.5), .clear],
                            center: .center, startRadius: 0, endRadius: 110
                        )
                    )
                    .frame(width: 220, height: 220)
                    .opacity(glowPulse ? 1 : 0.55)
                    .scaleEffect(glowPulse ? 1.04 : 0.94)
                    .blur(radius: 2)
                    .overlay {
                        Text(title.uppercased())
                            .font(.system(size: 19, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .shadow(color: .init(red: 1, green: 0.42, blue: 0.24).opacity(0.85), radius: 14)
                            .shadow(color: .white.opacity(0.5), radius: 2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .padding(.horizontal, 32)
                    }

                bulbRow

                if let status {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(red: 1, green: 0.42, blue: 0.24))
                            .frame(width: 5, height: 5)
                            .opacity(glowPulse ? 1 : 0.35)
                        Text(status.phase.trimmingCharacters(in: .whitespaces))
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.24))
                            .lineLimit(1)
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
        .onReceive(chaseTimer) { _ in
            guard status?.percent == nil else { return }
            chaseIndex = (chaseIndex + 1) % bulbCount
        }
    }

    private var bulbRow: some View {
        let litCount = status?.percent.map { Int(($0 * Double(bulbCount)).rounded()) }
        return HStack(spacing: 7) {
            ForEach(0..<bulbCount, id: \.self) { index in
                Circle()
                    .fill(bulbColor(index: index, litCount: litCount))
                    .frame(width: 7, height: 7)
                    .shadow(
                        color: isBright(index: index, litCount: litCount)
                            ? Color(red: 1, green: 0.42, blue: 0.24).opacity(0.85) : .clear,
                        radius: 5
                    )
            }
        }
    }

    private func isBright(index: Int, litCount: Int?) -> Bool {
        if let litCount { return index < litCount }
        return index == chaseIndex
    }

    private func bulbColor(index: Int, litCount: Int?) -> Color {
        if let litCount {
            return index < litCount ? Color(red: 1, green: 0.42, blue: 0.24) : .white.opacity(0.14)
        }
        return index == chaseIndex ? .white : .white.opacity(0.14)
    }
}
