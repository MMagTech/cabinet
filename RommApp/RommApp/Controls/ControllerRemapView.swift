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
        platformBody
            // iOS only, deliberately: on tvOS .navigationTitle paints
            // over content instead of reserving space above it, so the
            // title is a plain view inside the scroll content there.
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

    #if os(tvOS)
    /// The television's own shape, matching TVSettingsView rather than
    /// the phone's.
    ///
    /// A plain List on tvOS gives every row the full width of a 1920pt
    /// canvas with a focus plate to match, so a screen of short rows
    /// reads as a stack of enormous grey bands. The rest of this app's
    /// tvOS screens were built out of bounded glass cards for exactly
    /// that reason and this one, shared with iOS, had never had the
    /// pass. Same content and the same order; only the frame differs.
    private var platformBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                Text("Buttons")
                    .font(.largeTitle.weight(.bold))

                tvSection("Menu hotkey · Either player") {
                    hotkeyRow(label: "First button", value: hotkeyButtonA, slot: 0)
                    if let hotkeyButtonB {
                        hotkeyRow(label: "Second button", value: hotkeyButtonB, slot: 1)
                        tvButton("Use one button") {
                            self.hotkeyButtonB = nil
                            MenuHotkey.save(buttonA: hotkeyButtonA, buttonB: nil)
                        }
                    } else {
                        tvButton("Add a second button", enabled: controllers.isConnected) {
                            beginHotkeyCapture(slot: 1)
                        }
                    }
                    if !MenuHotkey.isDefault {
                        tvButton("Reset to L3 + R3") {
                            MenuHotkey.reset()
                            hotkeyButtonA = MenuHotkey.buttonA
                            hotkeyButtonB = MenuHotkey.buttonB
                        }
                    }
                    tvFootnote(hotkeyButtonB == nil
                               ? "Press this button on either controller to open the menu."
                               : "Hold both together, on either controller, to open the menu.")
                }

                if !controllers.isConnected {
                    tvSection("Controller") {
                        if let unsupported = controllers.unsupportedController {
                            tvInfoRow("\(unsupported) is paired but not usable", tint: .orange)
                            tvFootnote("This controller isn't presenting as a standard gamepad. Many have a mode switch, often held at power on.")
                        } else {
                            tvInfoRow("No controller connected", tint: .secondary)
                            tvFootnote("Connect a controller to change its buttons. Settings are remembered per controller.")
                        }
                    }
                }

                if controllers.isConnected {
                    tvSection("Six button fighters") {
                        ForEach(ControllerBindings.presets, id: \.name) { preset in
                            Button {
                                controllers.applyBindings(preset.map)
                            } label: {
                                tvRowLabel(
                                    title: preset.name,
                                    detail: preset.detail,
                                    trailing: controllers.matchesBindings(preset.map) ? "checkmark" : nil
                                )
                            }
                            .buttonStyle(RowFocusStyle())
                        }
                        tvFootnote("Punches on top, kicks below. Editing any button makes it custom.")
                    }

                    tvSection("Face buttons") {
                        Toggle(isOn: Binding(
                            get: { controllers.faceButtonsSwapped },
                            set: { _ in controllers.swapFaceButtons() }
                        )) {
                            tvRowLabel(
                                title: "Swap A and B",
                                detail: controllers.faceButtonsSwapped
                                    ? "Matching the letters on the pad."
                                    : "Matching where the buttons sit, not their letters.",
                                trailing: nil
                            )
                        }
                        .toggleStyle(.switch)
                    }

                    tvSection("Game inputs · Player 1") {
                        tvFootnote("Select an input, then press the controller button you want for it. Pressing a button on its own does nothing here.")
                        ForEach(RetroPad.bindable, id: \.id) { input in
                            row(for: input)
                        }
                        tvFootnote("Without Coin an arcade game can't start. Player 1 only; player 2 is set automatically.")
                    }

                    tvSection("Buttons player 1's controller reports") {
                        ForEach(controllers.availableButtons, id: \.self) { name in
                            tvRowLabel(
                                title: GameControllerManager.friendlyName(name),
                                detail: controllers.bindings(for: name)
                                    .map { "\u{2192} \(RetroPad.label(for: $0))" } ?? "not assigned",
                                trailing: nil
                            )
                                        }
                        tvFootnote("A button missing here is one this controller never reports, so no app can read it.")
                    }

                    tvSection("") {
                        Button("Reset to defaults", role: .destructive) {
                            confirmingReset = true
                        }
                        .buttonStyle(RowFocusStyle())
                    }
                }
            }
            // Wider than the 1100 the settings hub uses, and smaller
            // type inside it. That screen is five short rows where a
            // narrow column reads as deliberate; this one carries the
            // whole bindable pad with an explanation beside each row,
            // and at the hub's measurements it starved the text while
            // leaving most of a 1920pt canvas empty.
            .frame(maxWidth: 1500, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 50)
        }
    }

    @ViewBuilder
    private func tvSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !title.isEmpty {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    /// Explanatory text at a size the room can read, rather than the
    /// footnote a phone gets.
    private func tvFootnote(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func tvInfoRow(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(tint)
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { tvRowBackground() }
    }

    private func tvButton(
        _ title: String, enabled: Bool = true, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            tvRowLabel(title: title, detail: nil, trailing: nil)
        }
        .buttonStyle(RowFocusStyle())
        .disabled(!enabled)
    }

    /// Real Liquid Glass on tvOS 26 with the flat material below it,
    /// the same treatment TVSettingsView gives its rows. Duplicated
    /// rather than shared because that one is private to its own file
    /// and this is four lines.
    @ViewBuilder
    private func tvRowBackground() -> some View {
        if #available(tvOS 26.0, *) {
            RoundedRectangle(cornerRadius: 16)
                .fill(.clear)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
        }
    }

    /// The shared row face: title, optional second line, optional
    /// trailing glyph, at the sizes a television needs.
    private func tvRowLabel(title: String, detail: String?, trailing: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            if let trailing {
                Image(systemName: trailing)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { tvRowBackground() }
    }
    #else
    private var platformBody: some View {
        List {
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
    }
    #endif

    #if os(tvOS)
    private func hotkeyRow(label: String, value: String, slot: Int) -> some View {
        Button {
            beginHotkeyCapture(slot: slot)
        } label: {
            tvRowLabel(
                title: label,
                detail: GameControllerManager.friendlyName(value),
                trailing: nil
            )
        }
        .buttonStyle(RowFocusStyle())
        .disabled(!controllers.isConnected)
    }
    #else
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
    #endif

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

    #if os(tvOS)
    private func row(for input: (id: Int, label: String, detail: String)) -> some View {
        Button {
            beginCapture(for: input.id)
        } label: {
            tvRowLabel(
                title: input.label,
                detail: input.detail,
                trailing: nil
            )
            .overlay(alignment: .trailing) {
                if let bound = controllers.boundButton(for: input.id) {
                    Text(GameControllerManager.friendlyName(bound))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 32)
                } else {
                    Text("Not set")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.trailing, 32)
                }
            }
        }
        .buttonStyle(RowFocusStyle())
        .disabled(!controllers.isConnected)
    }
    #else
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
    #endif

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
