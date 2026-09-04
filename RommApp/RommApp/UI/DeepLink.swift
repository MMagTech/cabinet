#if os(iOS)
import CoreSpotlight
import SwiftUI

/// Opens Cabinet at a particular game, from anywhere outside the app.
///
/// The Apple TV has had this since the top shelf: a URL carrying a rom id
/// arrives and the launch screen opens on it. This is the iPhone's twin,
/// and it serves the widget and Spotlight rather than a shelf.
///
/// It differs from the television's version in one way that matters. The
/// television resolves a link by asking the server, and treats a failure as
/// the game having been deleted, which is fair on a mains-powered box
/// sitting next to its own server. A phone genuinely goes offline, and
/// keeping games on it so they play without a server is the whole point of
/// the native cores. So this looks in the kept games first and only asks
/// the server when it finds nothing. A game you have downloaded opens in
/// Airplane Mode, and "cannot reach your server" stays a different sentence
/// from "that game is gone".
struct DeepLinkHandler: ViewModifier {
    @ObservedObject var session: Session

    @State private var target: Target?
    @State private var problem: String?
    /// A link that arrived before the session had finished restoring.
    ///
    /// A cold launch is the normal case for this: the system hands the URL
    /// over immediately and the session is still coming back from disk, so
    /// checking readiness at that moment and giving up drops nearly every
    /// link that matters. The television's version has the same guard and
    /// gets away with it because a shelf press only happens on a machine
    /// that has been sitting there paired.
    ///
    /// Held rather than dropped, and only dropped by never becoming ready,
    /// which is the unpaired case the guard was actually written for.
    @State private var pending: Int?

    private struct Target: Identifiable {
        let id = UUID()
        let rom: Rom
    }

    func body(content: Content) -> some View {
        content
            .onOpenURL { open($0) }
            // A Spotlight result arrives as a continued activity rather
            // than a URL, carrying the identifier the indexer wrote.
            // From here it is the same road as a widget press: hold it
            // if the session is still restoring, then open the launch
            // screen, never the game itself.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                      raw.hasPrefix("rom-"),
                      let romId = Int(raw.dropFirst("rom-".count))
                else { return }
                open(romId: romId)
            }
            .onChange(of: session.stage) { _, stage in
                if stage == .ready, let romId = pending {
                    pending = nil
                    resolve(romId: romId)
                }
            }
            .fullScreenCover(item: $target) { target in
                NavigationStack {
                    GameLaunchView(rom: target.rom)
                        .environmentObject(session)
                }
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

    /// Deliberately opens the launch screen rather than starting the game,
    /// even for a `play` link. A search result or a widget press that
    /// silently began a download would be a poor surprise, and the launch
    /// screen is one more press for somebody who did mean it.
    private func open(_ url: URL) {
        guard let link = CabinetLink.parse(url) else { return }
        open(romId: link.romId)
    }

    private func open(romId: Int) {
        guard session.stage == .ready else {
            pending = romId
            return
        }
        resolve(romId: romId)
    }

    private func resolve(romId: Int) {
        if let kept = KeptGameStore.shared.games.first(where: { $0.romId == romId }) {
            target = Target(rom: kept.rom)
            return
        }

        Task {
            do {
                target = Target(rom: try await session.rom(id: romId))
            } catch {
                // Two different sentences on purpose. Offline and
                // not downloaded is a state somebody can act on; being
                // told the game was deleted when it was not is alarming
                // and wrong, which is what the television currently does
                // whenever it cannot reach RomM.
                problem = NetworkMonitor.shared.isOffline
                    ? "Cabinet can't reach your server, and this game isn't downloaded to this phone."
                    : "It may have been removed from your library."
            }
        }
    }
}

extension View {
    func handlesGameDeepLinks(session: Session) -> some View {
        modifier(DeepLinkHandler(session: session))
    }
}
#endif
