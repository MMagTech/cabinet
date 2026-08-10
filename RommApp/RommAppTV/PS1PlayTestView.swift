#if os(tvOS)
import SwiftUI

/// The playable half of the PS1 go/no-go: same hardcoded rom as
/// PS1PerfTestView (no picker, no library), but actually drawn to the
/// screen and driven by a real controller instead of just timed. Still a
/// throwaway test screen, not the real player: no pause menu, no save
/// states, no way back out except the Menu button on the controller
/// (mapped to RetroPad.overlay's default binding) exiting this view.
///
/// Uses the same MetalGameView/NativePlayerRenderer pipeline the iOS
/// player uses, not a hand-rolled render path: it drives its own draw
/// loop off MTKView's display link and owns its own audio, so this view
/// only needs to load the game and forward controller input.
struct PS1PlayTestView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    private static let testRomID = 322

    @State private var status = "Idle"
    @State private var renderer: NativePlayerRenderer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer {
                MetalGameView(renderer: renderer)
                    .ignoresSafeArea()
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

            let renderer = NativePlayerRenderer()
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
#endif
