#if os(tvOS)
import SwiftUI

/// Handles `cabinet://` links, which today means the top shelf and
/// nothing else. Attached once, to the tvOS scene in `RommAppTV.swift`.
///
/// The whole feature stays inside the tvOS target because of this: the
/// shelf hands back a URL, and everything from there is a rom id, an
/// existing client call, and an existing tvOS launch screen. No shared
/// file needs to change to make the Home screen able to start a game.
struct TVDeepLinkHandler: ViewModifier {
    /// Passed in rather than read from the environment. `RommAppTV`
    /// owns the session as a `@StateObject` and installs it with
    /// `.environmentObject` on the same expression this modifier is
    /// applied to, and a modifier's own body is evaluated outside that,
    /// so reading it from the environment here works or does not
    /// depending on the order of two lines. Handing it over is the
    /// version that cannot silently break.
    @ObservedObject var session: Session

    @State private var target: Target?
    @State private var problem: String?

    private struct Target: Identifiable {
        let id = UUID()
        let rom: Rom
        let startsPlaying: Bool
    }

    func body(content: Content) -> some View {
        content
            .onOpenURL { open($0) }
            .fullScreenCover(item: $target) { target in
                TVGameLaunchView(rom: target.rom, autoStart: target.startsPlaying)
                    .environmentObject(session)
            }
            .alert(
                "Couldn't open that game",
                isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
            ) {
                Button("OK", role: .cancel) { problem = nil }
            } message: {
                Text(problem ?? "")
            }
    }

    private func open(_ url: URL) {
        guard let link = CabinetLink.parse(url) else { return }

        // Not paired, or signed out since the shelf was written. The
        // link is dropped rather than queued for after setup: by the
        // time somebody has typed a server address and approved a
        // pairing, a game they pressed a minute ago on a different
        // account is not what they are still asking for. `RootView` is
        // already showing the setup flow, which is the right screen.
        guard session.stage == .ready else { return }

        Task {
            do {
                let rom = try await session.rom(id: link.romId)
                target = Target(rom: rom, startsPlaying: link.startsPlaying)
            } catch {
                // Usually a game deleted from RomM since the snapshot
                // was written, which is a real thing that happens on a
                // library somebody is still curating. Say so plainly on
                // Home rather than opening an empty player.
                problem = "It may have been removed from your library."
            }
        }
    }
}
#endif
