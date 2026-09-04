import SwiftUI

/// The connected pads, one line per player, or "None connected".
/// Extracted from SettingsView so the Mac's Settings window shows the
/// identical row; nothing about it changed in the move.
struct ControllerStatusRow: View {
    @ObservedObject private var controllers = GameControllerManager.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controllers.isConnected
                  ? "gamecontroller.fill" : "gamecontroller")
                .foregroundStyle(controllers.isConnected
                                 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text("Controller")
                if controllers.isConnected {
                    // One line per connected slot, not just player 1:
                    // this row used to show a single name back when
                    // only one controller could ever be attached at
                    // once, and kept doing that even after a second
                    // player became possible.
                    ForEach(Array(controllers.connectedNames.enumerated()), id: \.offset) { index, name in
                        if let name {
                            Text("Player \(index + 1): \(name)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                } else {
                    Text("None connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
