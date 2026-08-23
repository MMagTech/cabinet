#if os(iOS)
import SwiftUI

/// The first screen on a fresh install, and the only one that asks a
/// question before anything is typed.
///
/// iOS only, deliberately. A television cannot be its own controller,
/// so tvOS goes straight to `ServerSetupView` the way it always has and
/// never sees this choice.
///
/// Why a choice screen rather than a link under the address field:
/// `ServerSetupView` focuses its field on appear, so the keyboard is
/// already up when that screen arrives and covers the bottom of the
/// display, which is exactly where a secondary action would sit. The
/// one person who needs the controller door, a guest with no server of
/// their own, is the one least able to see it there. Nothing is typed
/// here, so nothing is covered.
///
/// The cost is honest and known: everyone who does have a server pays
/// one extra tap, once, on first launch.
struct WelcomeView: View {
    @EnvironmentObject private var session: Session
    @State private var showingServerSetup = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                Spacer()

                Text("Cabinet")
                    .font(.largeTitle.bold())

                // Two rows, no explaining sentence above them: the rows
                // say what they do, and a paragraph restating that is
                // the habit this app's copy pass exists to remove.
                VStack(spacing: 0) {
                    door(
                        icon: "server.rack",
                        title: "Connect to a RomM server",
                        detail: "Your library, your saves, offline"
                    ) {
                        showingServerSetup = true
                    }

                    Divider().padding(.leading, 54)

                    door(
                        icon: "iphone.gen3",
                        title: "Use this phone as a controller",
                        detail: "No server needed"
                    ) {
                        session.useAsControllerOnly()
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))

                Text("You can switch later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            // The grouped pairing, not a lone card colour: in light
            // mode secondarySystemGroupedBackground IS white, so on a
            // plain systemBackground page the rows had no card at all,
            // just a hairline. Caught in the simulator; invisible in
            // dark mode, where the two differ anyway.
            .background(Color(.systemGroupedBackground))
            .navigationDestination(isPresented: $showingServerSetup) {
                ServerSetupView()
            }
        }
    }

    private func door(
        icon: String, title: String, detail: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
