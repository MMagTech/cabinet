#if targetEnvironment(macCatalyst)
import SwiftUI
import os

/// The Mac shell's share of the family identity. tvOS owns the
/// always-ambient version of Cabinet, art-derived atmosphere behind the
/// whole screen, and the Mac reads as that app on a desk, not as the
/// phone stretched into a window. iOS deliberately keeps its ambient
/// contained to the game launch screen; that rule is about iOS's own
/// app-shell idiom and is unchanged by this file existing.
///
/// One backdrop for the whole window, derived from the most recently
/// played game, the same art Home's hero leads with, so the window and
/// the hero agree about what game this household is in the middle of.
/// The treatment is the family recipe from GameLaunchView's backdrop:
/// oversampled so the blur has pixels past every edge, blurred well past
/// recognition, slightly desaturated, darkened enough that glass and
/// text always have a floor.
struct MacAmbientBackground: View {
    @EnvironmentObject private var session: Session
    @Environment(\.scenePhase) private var scenePhase
    @State private var coverPath: String?

    var body: some View {
        ZStack {
            Color.black
            if let coverPath {
                CoverImage(path: coverPath, title: "", showsPlaceholder: false)
                    .scaleEffect(1.4)
                    .blur(radius: 60)
                    .saturation(0.8)
                    .overlay(Color.black.opacity(0.55))
            }
        }
        .clipped()
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: coverPath)
        .task { await refresh() }
        // Coming back to the window after playing somewhere else is
        // exactly when the last-played game, and so the backdrop,
        // changes.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func refresh() async {
        guard let page = try? await session.recentlyPlayed() else {
            Logger(subsystem: "com.mmagtech.Cabinet", category: "mac-ambient")
                .info("backdrop fetch failed, keeping previous art")
            return
        }
        let path = page.items.first.flatMap { $0.pathCoverLarge ?? $0.pathCoverSmall }
        Logger(subsystem: "com.mmagtech.Cabinet", category: "mac-ambient")
            .info("backdrop source: \(path ?? "none", privacy: .public)")
        if let path { coverPath = path }
    }
}
#endif
