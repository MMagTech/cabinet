#if os(iOS)
import SwiftUI

/// A guest's whole app: one screen with one job, find a television in
/// the room and become its controls.
///
/// There is no library here, no shelves and no settings anyone without
/// a server could use, because a guest has none of those things. The
/// panel itself is `ControllerPadView`, exactly the one a phone with a
/// server gets from Home's offer card; only the way in differs.
///
/// The pairing this rests on never used a RomM account as identity
/// (see ControllerPairing), which is what makes a guest possible at
/// all: a phone proves itself to a television with its own keys and a
/// code read off the screen in the room.
struct ControllerOnlyView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        NavigationStack {
            ControllerPadView(isRoot: true)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Connect to a RomM server") {
                                session.leaveControllerOnly()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
        }
    }
}
#endif
