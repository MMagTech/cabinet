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
            MainTabView()
        }
    }
}
