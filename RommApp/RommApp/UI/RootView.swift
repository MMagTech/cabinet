import SwiftUI

struct RootView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        switch session.stage {
        case .needsServer:
            ServerSetupView()
        case .needsPairing:
            PairingView()
        case .ready:
            #if os(tvOS)
            // Home/Library/Player haven't been ported yet, that's the next
            // milestone step (native cores rebuilt for tvOS, then
            // GameControllerManager wired up). This proves pairing and the
            // target boot for now.
            ReadyPlaceholderView()
            #else
            MainTabView()
            #endif
        }
    }
}
