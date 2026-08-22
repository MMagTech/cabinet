import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        #if DEBUG
        // The headless benchmark path, taken only when this launch was
        // given -cabinetBench. See NativeBenchHarness. Never compiled into
        // a release build, and with no such argument this is a single
        // UserDefaults read before the ordinary root. Shared by both
        // platforms: tvOS is the one that most needs measuring, being
        // slower and fanless.
        if NativeBenchHarness.requestedRomId != nil {
            return AnyView(NativeBenchRunnerView())
        }
        return AnyView(normalBody)
        #else
        return normalBody
        #endif
    }

    @ViewBuilder
    private var normalBody: some View {
        switch session.stage {
        case .needsServer:
            ServerSetupView()
        case .needsPairing:
            PairingView()
        case .ready:
            MainTabView()
        }
    }
}
