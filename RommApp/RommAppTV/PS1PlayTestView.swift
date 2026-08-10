#if os(tvOS)
import SwiftUI

/// The playable half of the PS1 go/no-go: same hardcoded rom as
/// PS1PerfTestView (no picker, no library), but actually drawn to the
/// screen and driven by a real controller instead of just timed. Still a
/// throwaway test screen, not the real player: no pause menu, no save
/// states, no way back out except the Menu button on the controller
/// (mapped to RetroPad.overlay's default binding) exiting this view.
///
/// Currently wired to PS1ThreadedRenderer, the tvOS-only experimental
/// threaded-core prototype (see that file), not the shared
/// NativePlayerRenderer iOS also uses: chasing a real report of choppy
/// audio and laggy video together during Crash Bandicoot 2 gameplay,
/// deliberately kept out of the shared file until proven, per Marcus
/// 2026-08-10 (never touch iOS code, or code iOS depends on, without
/// asking first and defending why).
struct PS1PlayTestView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    // Crash Bandicoot 2 (id 322): the title that surfaced real choppiness
    // with the shared (untreaded) renderer, the one worth re-testing here.
    private static let testRomID = 322

    @State private var status = "Idle"
    @State private var renderer: PS1ThreadedRenderer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer {
                ThreadedMetalGameView(renderer: renderer)
                    .ignoresSafeArea()
                VStack {
                    HStack {
                        Spacer()
                        ThreadedFPSReadout(renderer: renderer)
                            .padding()
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .task { await start() }
    }

    private func start() async {
        do {
            status = "Fetching rom \(Self.testRomID)…"
            let rom = try await session.rom(id: Self.testRomID)

            status = "Downloading \(rom.name)…"
            _ = try await NativeLauncher.prepare(rom: rom, session: session)

            let renderer = PS1ThreadedRenderer()
            GameControllerManager.shared.send = { id, pressed in
                renderer.setButton(id, down: pressed)
            }
            GameControllerManager.shared.onMenu = { dismiss() }
            GameControllerManager.shared.start()
            self.renderer = renderer
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }
}

/// Diagnostic overlay for the threaded prototype: shows the render side's
/// own fps/worst-frame (same meaning as before) plus the core thread's own
/// tick rate, which can now legitimately differ from the render rate,
/// that's the entire point of decoupling them. If the fix works, both
/// should read close to 60/16.7ms even during Crash Bandicoot 2's busiest
/// scenes.
private struct ThreadedFPSReadout: View {
    @ObservedObject var renderer: PS1ThreadedRenderer

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.0f fps render", renderer.measuredFPS))
                .foregroundStyle(renderer.measuredFPS < 55 ? .red : .green)
            Text(String(format: "%.0f ms worst", renderer.worstFrameMS))
                .foregroundStyle(renderer.worstFrameMS > 20 ? .red : .green)
            Text(String(format: "%.0f hz core", renderer.coreHz))
                .foregroundStyle(renderer.coreHz < 55 ? .red : .green)
        }
        .font(.callout.monospaced())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
