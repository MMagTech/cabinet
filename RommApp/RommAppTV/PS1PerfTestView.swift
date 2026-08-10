#if os(tvOS)
import SwiftUI

/// The PS1 go/no-go's actual test: does PCSX ReARMed's pure-interpreter
/// build keep up with real time on this hardware. No render view, no
/// controller input, no library picker, deliberately: those are separate
/// questions with their own risk, and building them before this one is
/// answered would just be guessing at effort spent on a maybe.
///
/// Hardcodes one known PS1 title (Crash Bandicoot 2, real GTE-heavy 3D
/// throughout) rather than routing through Library, since picking a game
/// from a grid has nothing to do with whether the core can run one.
struct PS1PerfTestView: View {
    @EnvironmentObject private var session: Session

    private static let testRomID = 322
    private static let frameCount = 600

    @State private var status = "Idle"
    @State private var result: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("PS1 Performance Test")
                .font(.title.bold())
            Text(status)
                .foregroundStyle(.secondary)
            if let result {
                Text(result)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .padding(.top, 24)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await run() }
    }

    private func run() async {
        do {
            status = "Fetching rom \(Self.testRomID)…"
            let rom = try await session.rom(id: Self.testRomID)

            status = "Downloading \(rom.name)…"
            let core = try await NativeLauncher.prepare(rom: rom, session: session)
            precondition(core == .pcsxReARMed, "test rom did not route to PS1's core")

            status = "Running \(Self.frameCount) frames…"
            let start = Date()
            for _ in 0..<Self.frameCount {
                LibretroFrontend.shared.runFrame()
            }
            let elapsed = Date().timeIntervalSince(start)

            // PS1 titles run at 60fps NTSC almost universally; Crash 2 is
            // one of them. Real-time speed means frameCount / 60 emulated
            // seconds took frameCount / 60 real seconds or less.
            let emulatedSeconds = Double(Self.frameCount) / 60.0
            let speed = emulatedSeconds / elapsed
            status = "Done"
            result = String(format: "%.2fx real-time", speed)
        } catch {
            status = "Failed"
            result = error.localizedDescription
        }
    }
}
#endif
