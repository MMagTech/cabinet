import SwiftUI

/// Shows live what the app receives from a physical controller.
///
/// This exists because "a button is not working" is otherwise impossible to
/// diagnose from inside a game: a press that does nothing could be the pad,
/// the mapping, the emulator, or the game itself ignoring that input. Here
/// there is only one link in the chain, so a button that lights up is proven
/// good all the way to the emulator's door.
///
/// It is also the evidence that decides whether a remapping flow is worth
/// building. iOS hands apps semantic buttons rather than raw indices, so a
/// certified pad should light the right rows without any remapping at all.
struct ControllerTestView: View {
    @StateObject private var controllers = GameControllerManager()

    var body: some View {
        List {
            Section {
                if controllers.isConnected {
                    Label(
                        controllers.controllerName ?? "Controller connected",
                        systemImage: "gamecontroller.fill"
                    )
                    .foregroundStyle(.green)
                } else {
                    Label("No controller connected", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Press every button and stick direction. Anything that lights up here reaches the emulator correctly.")
            }

            Section {
                ForEach(GameControllerManager.Pad.names, id: \.id) { entry in
                    let active = controllers.pressedInputs.contains(entry.id)
                    HStack {
                        Image(systemName: active ? "circle.fill" : "circle")
                            .foregroundStyle(active ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                            .font(.caption)
                        Text(entry.label)
                            .foregroundStyle(active ? .primary : .secondary)
                        Spacer()
                        if active {
                            Text("pressed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                    .animation(.easeOut(duration: 0.12), value: active)
                }
            } header: {
                Text("Inputs")
            } footer: {
                Text("Arcade button numbers match the on screen layout: 1 to 3 are the top row, 4 to 6 the bottom.")
            }
        }
        .navigationTitle("Test controller")
        .navigationBarTitleDisplayMode(.inline)
        .task { controllers.start() }
        .onDisappear { controllers.stop() }
    }
}
