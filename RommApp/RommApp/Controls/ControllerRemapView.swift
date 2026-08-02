import SwiftUI

/// Point any button on any controller at any emulator input.
///
/// This exists because controllers genuinely differ in what they expose. A
/// full size pad reports Menu and Options where Start and Coin belong, but a
/// compact pad may report neither, and an arcade game with no Coin button
/// cannot be played at all. Rather than guess at a preset per controller
/// family, this asks: press the button you want for this.
struct ControllerRemapView: View {
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var capturing: Int?
    @State private var confirmingReset = false

    var body: some View {
        List {
            if !controllers.isConnected {
                Section {
                    if let unsupported = controllers.unsupportedController {
                        Label(
                            "\(unsupported) is paired but not usable",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    } else {
                        Label("No controller connected", systemImage: "gamecontroller")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if controllers.unsupportedController != nil {
                        Text("iOS sees this controller but it does not present itself as a standard gamepad, so no app can read its buttons. Some controllers need a mode switch, often held at power on, to behave as one.")
                    } else {
                        Text("Connect a controller to change its buttons. Settings are remembered per controller.")
                    }
                }
            }

            // The instruction leads, because pressing a controller button
            // before choosing an input is the obvious first thing to try and
            // does nothing, which reads as broken.
            if controllers.isConnected {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "hand.tap.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tap an input below first")
                                .font(.subheadline.weight(.semibold))
                            Text("Then press the controller button you want for it. Pressing a button on its own does nothing here.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // Whole arrangements first, per button surgery second. Six
            // arcade buttons on a four button pad is a solved problem with
            // two good answers, and most people just want to pick one.
            if controllers.isConnected {
                Section {
                    ForEach(ControllerBindings.presets, id: \.name) { preset in
                        Button {
                            controllers.applyBindings(preset.map)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: controllers.matchesBindings(preset.map)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(controllers.matchesBindings(preset.map)
                                                     ? AnyShapeStyle(.tint)
                                                     : AnyShapeStyle(.tertiary))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(preset.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Six button fighters")
                } footer: {
                    Text("Punches across the top row, kicks across the bottom, matching the arcade panel. Editing any button below makes the arrangement custom.")
                }
            }

            Section {
                ForEach(RetroPad.bindable, id: \.id) { input in
                    row(for: input)
                }
            } header: {
                Text("Game inputs")
            } footer: {
                Text("Coin and Start matter most: without Coin an arcade game cannot start.")
            }

            if controllers.isConnected {
                Section {
                    ForEach(controllers.availableButtons, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(GameControllerManager.friendlyName(name))
                            if let id = controllers.bindings(for: name) {
                                Text("→ \(RetroPad.label(for: id))")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Text("not assigned")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Buttons this controller reports")
                } footer: {
                    Text("If a button you expect is missing here, this controller does not report it to iOS and no app can use it.")
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        confirmingReset = true
                    }
                }
            }
        }
        .navigationTitle("Buttons")
        .navigationBarTitleDisplayMode(.inline)
        .task { controllers.start() }
        .onDisappear { controllers.captureHandler = nil }
        .overlay {
            if let capturing {
                capturePrompt(for: capturing)
            }
        }
        .confirmationDialog(
            "Reset button assignments?",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { controllers.resetBindings() }
        }
    }

    private func row(for input: (id: Int, label: String, detail: String)) -> some View {
        Button {
            beginCapture(for: input.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(input.label)
                        .foregroundStyle(.primary)
                    Text(input.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let bound = controllers.boundButton(for: input.id) {
                    Text(GameControllerManager.friendlyName(bound))
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 130)
                } else {
                    Text("Not set")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .disabled(!controllers.isConnected)
    }

    private func capturePrompt(for id: Int) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Press a button")
                    .font(.title3.bold())
                Text("for \(RetroPad.label(for: id))")
                    .foregroundStyle(.secondary)
                ProgressView()
                    .padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button("Cancel") { endCapture() }
                        .buttonStyle(.bordered)
                    Button("Leave unset", role: .destructive) {
                        controllers.clearBinding(for: id)
                        endCapture()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .padding(40)
        }
    }

    private func beginCapture(for id: Int) {
        capturing = id
        controllers.captureHandler = { name in
            controllers.bind(button: name, to: id)
            endCapture()
        }
    }

    private func endCapture() {
        controllers.captureHandler = nil
        capturing = nil
    }
}
