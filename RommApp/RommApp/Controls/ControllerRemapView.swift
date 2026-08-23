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
    /// 0 while capturing the hotkey's first button, 1 for the second, nil
    /// otherwise. Distinct from `capturing`: a hotkey capture does not bind
    /// a RetroPad input, it just names one of the two buttons that must be
    /// held together.
    @State private var capturingHotkeySlot: Int?
    @State private var hotkeyButtonA = MenuHotkey.buttonA
    @State private var hotkeyButtonB = MenuHotkey.buttonB

    var body: some View {
        List {
            // tvOS gets its title as content rather than chrome:
            // .navigationTitle paints over the list there instead of
            // reserving space above it, which had "Buttons" sitting on
            // top of the first rows. Same pattern every other tvOS
            // screen in this app already uses.
            #if os(tvOS)
            Text("Buttons")
                .font(.largeTitle.weight(.bold))
                .listRowBackground(Color.clear)
            #endif
            // Leads the screen, not buried under the six-button and
            // per-input sections: unlike everything below it, this applies
            // to both players and is a standing preference rather than
            // something tied to whichever pad happens to be attached right
            // now, so it is shown even with nothing connected.
            Section {
                hotkeyRow(label: "First button", value: hotkeyButtonA, slot: 0)
                if let hotkeyButtonB {
                    hotkeyRow(label: "Second button", value: hotkeyButtonB, slot: 1)
                    Button("Use one button") {
                        self.hotkeyButtonB = nil
                        MenuHotkey.save(buttonA: hotkeyButtonA, buttonB: nil)
                    }
                } else {
                    Button("Add a second button") {
                        beginHotkeyCapture(slot: 1)
                    }
                    .disabled(!controllers.isConnected)
                }
                if !MenuHotkey.isDefault {
                    Button("Reset to L3 + R3") {
                        MenuHotkey.reset()
                        hotkeyButtonA = MenuHotkey.buttonA
                        hotkeyButtonB = MenuHotkey.buttonB
                    }
                }
            } header: {
                Text("Menu hotkey · Either player")
            } footer: {
                Text(hotkeyButtonB == nil
                     ? "Press this button on either controller to open the menu."
                     : "Hold both together, on either controller, to open the menu.")
            }

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
                        Text("This controller isn't presenting as a standard gamepad. Many have a mode switch, often held at power on.")
                    } else {
                        Text("Connect a controller to change its buttons. Settings are remembered per controller.")
                    }
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
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(preset.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if controllers.matchesBindings(preset.map) {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(.rect)
                        }
                        #if os(tvOS)
                        // .plain paints a system focus effect over the
                        // row's own background and reserves no headroom
                        // for its focus growth, so a focused row grows
                        // into its neighbour. This app's own style
                        // instead, per the tvOS conventions.
                        .buttonStyle(RowFocusStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    }
                } header: {
                    Text("Six button fighters")
                } footer: {
                    Text("Punches on top, kicks below. Editing any button makes it custom.")
                }
            }

            // Above the per-input rows on purpose: swapping the face
            // pair is the one remap almost everybody wants and nobody
            // should have to rebind two inputs by hand to get. It edits
            // the same stored map those rows show, so the change is
            // visible there rather than hidden behind a second
            // mechanism, and Reset clears it with everything else.
            if controllers.isConnected {
                Section {
                    Toggle(isOn: Binding(
                        get: { controllers.faceButtonsSwapped },
                        set: { _ in controllers.swapFaceButtons() }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Swap A and B")
                            Text(controllers.faceButtonsSwapped
                                 ? "Matching the letters on the pad."
                                 : "Matching where the buttons sit, not their letters.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // The instruction leads right into the rows it explains, rather
            // than sitting above the presets section it has nothing to do
            // with: pressing a controller button before choosing an input
            // below is the obvious first thing to try and does nothing,
            // which reads as broken without this.
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

            Section {
                ForEach(RetroPad.bindable, id: \.id) { input in
                    row(for: input)
                }
            } header: {
                Text("Game inputs · Player 1")
            } footer: {
                // Explicit now that a second controller is a real thing:
                // this whole screen only ever edits player 1's pad, which
                // was invisible when a second controller could not exist at
                // all. Player 2's bindings still resolve automatically from
                // its own vendor name; there is no screen for editing them.
                Text("Without Coin an arcade game can't start. Player 1 only; player 2 is set automatically.")
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
                    Text("Buttons player 1's controller reports")
                } footer: {
                    Text("A button missing here is one this controller never reports, so no app can read it.")
                }

                Section {
                    Button("Reset to defaults", role: .destructive) {
                        confirmingReset = true
                    }
                }
            }
        }
        // iOS only, deliberately: see the title row at the top of the
        // list for what tvOS does instead and why.
        #if os(iOS)
        .navigationTitle("Buttons")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { controllers.start() }
        .onDisappear { controllers.captureHandler = nil }
        .overlay {
            if let capturing {
                capturePrompt(for: capturing)
            } else if capturingHotkeySlot != nil {
                hotkeyCapturePrompt()
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

    private func hotkeyRow(label: String, value: String, slot: Int) -> some View {
        Button {
            beginHotkeyCapture(slot: slot)
        } label: {
            HStack {
                Text(label)
                    .foregroundStyle(.primary)
                Spacer()
                Text(GameControllerManager.friendlyName(value))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(!controllers.isConnected)
    }

    private func beginHotkeyCapture(slot: Int) {
        capturingHotkeySlot = slot
        controllers.captureHandler = { [self] name in
            if slot == 0 {
                hotkeyButtonA = name
                MenuHotkey.save(buttonA: name, buttonB: hotkeyButtonB)
            } else {
                hotkeyButtonB = name
                MenuHotkey.save(buttonA: hotkeyButtonA, buttonB: name)
            }
            endHotkeyCapture()
        }
    }

    private func endHotkeyCapture() {
        controllers.captureHandler = nil
        capturingHotkeySlot = nil
    }

    /// The shell both capture prompts wear. Sized for the device it is
    /// on rather than once for a phone: a card tuned to arm's length
    /// floats as a small dark box on a television, which is what this
    /// looked like on real hardware. tvOS gets the room's type sizes
    /// and the app's own glass; iOS keeps exactly what it had.
    @ViewBuilder
    private func capturePromptShell(
        title: String, detail: String, @ViewBuilder actions: () -> some View
    ) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            #if os(tvOS)
            VStack(spacing: 24) {
                Text(title)
                    .font(.largeTitle.bold())
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .padding(.vertical, 8)
                HStack(spacing: 20) { actions() }
            }
            .padding(56)
            .frame(minWidth: 700)
            .background {
                if #available(tvOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(.clear)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 32))
                } else {
                    RoundedRectangle(cornerRadius: 32).fill(.regularMaterial)
                }
            }
            #else
            VStack(spacing: 14) {
                Text(title)
                    .font(.title3.bold())
                Text(detail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
                    .padding(.vertical, 4)
                HStack(spacing: 12) { actions() }
            }
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .padding(40)
            #endif
        }
    }

    private func hotkeyCapturePrompt() -> some View {
        capturePromptShell(title: "Press a button", detail: "for the menu hotkey") {
            Button("Cancel") { endHotkeyCapture() }
                .buttonStyle(.bordered)
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
        capturePromptShell(
            title: "Press a button",
            detail: "on player 1's controller, for \(RetroPad.label(for: id))"
        ) {
            Button("Cancel") { endCapture() }
                .buttonStyle(.bordered)
            Button("Leave unset", role: .destructive) {
                controllers.clearBinding(for: id)
                endCapture()
            }
            .buttonStyle(.bordered)
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
