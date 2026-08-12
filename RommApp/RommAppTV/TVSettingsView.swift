#if os(tvOS)
import SwiftUI

/// tvOS's settings screen, the scoped-down sibling of iOS's
/// `SettingsView`. That one is a long `Form` because it also owns Storage
/// (kept games), the EmulatorJS cache bridge, native core options and the
/// debug screen. Most of it is either iOS-only by design (kept games do
/// not exist here, tvOS's storage is a transient same-network cache) or
/// not yet ported.
///
/// Laid out as real cards rather than a `List`: a plain List on tvOS gives
/// every row the full width of a 1920pt canvas with a focus plate to
/// match, so four short rows read as four enormous grey bands. Cards in a
/// bounded column look like the rest of this app and leave the focus
/// effect something sensibly sized to land on.
struct TVSettingsView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // No "Settings" heading: the tab bar already says it, and
                // repeating it directly underneath is an iOS habit that
                // buys nothing on a TV. Same reasoning as TVLibraryView.
                VStack(alignment: .leading, spacing: 40) {
                    section("Controllers") {
                        ForEach(Array(controllers.connectedNames.enumerated()), id: \.offset) { index, name in
                            if let name {
                                infoRow(label: "Player \(index + 1)", value: name)
                            }
                        }
                        if controllers.connectedNames.allSatisfy({ $0 == nil }) {
                            infoRow(label: "No controller connected", value: "")
                        }
                        NavigationLink {
                            ControllerRemapView()
                        } label: {
                            actionRow(title: "Buttons", detail: "Map any button to any input", chevron: true)
                        }
                        .buttonStyle(.plain)
                    }

                    section("Server") {
                        if let host = session.serverURL?.host {
                            infoRow(label: "Connected to", value: host)
                        }
                        Button {
                            confirmingSignOut = true
                        } label: {
                            actionRow(title: "Sign out", detail: nil, chevron: false, destructive: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 80)
                .padding(.vertical, 50)
            }
            .task { controllers.start() }
            .alert("Sign out?", isPresented: $confirmingSignOut) {
                Button("Sign out", role: .destructive) { session.forgetServer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to pair this Apple TV with your server again.")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label).font(.title3)
            Spacer(minLength: 24)
            Text(value)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.5), in: .rect(cornerRadius: 16))
    }

    private func actionRow(
        title: String, detail: String?, chevron: Bool, destructive: Bool = false
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .foregroundStyle(destructive ? Color.red : Color.primary)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }
}
#endif
