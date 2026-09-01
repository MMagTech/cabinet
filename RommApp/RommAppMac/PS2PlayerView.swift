//  The PS2 screen on the Mac.
//
//  Deliberately its own screen rather than a branch inside
//  NativePlayerView. PS2 shares no code with the libretro path: not the
//  frontend, not the renderer, not the audio. Routing it through the
//  screen twenty-three other cores use would put a PS2-shaped branch
//  into the most blast-radius-heavy file in the app to gain nothing.
//
//  What is not here yet, and is not hidden: there is no sound, no
//  controller, no pause menu, and no save state or memory card sync.
//  This screen exists to put a picture on the display.

import SwiftUI

struct PS2PlayerView: View {
    private static let menuRows = ["Quit", "Save", "Load", "Resume"]

    let discPath: String
    let title: String

    /// Present for a real launch, absent for the bench harness, which
    /// has no session to sync against.
    var rom: Rom? = nil
    var session: Session? = nil

    @State private var player = PS2Player()
    /// What the card looked like before play, so the upload afterwards
    /// can tell whether the game actually saved anything.
    @State private var cardDigestBefore: Data?
    /// What the panel says under the title: the result of the last
    /// action, or nothing, in which case it reads "Paused".
    @State private var menuStatus: String?
    @State private var menuBusy = false

    @AppStorage("ps2-shader") private var shaderIndex: Int = 0
    @AppStorage("ps2-blending") private var blending: Int = 1
    @AppStorage("ps2-upscale") private var upscale: Double = 1.0
    /// Per game rather than machine-wide: whether a title is widescreen
    /// is a fact about the title.
    @State private var aspect: String = PS2Graphics.aspects[0]
    /// Per game, like aspect: which renderer a title needs is a fact
    /// about the title.
    @State private var renderer: Int = 17
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PS2MetalSurface { view in
                if let rom {
                    cardDigestBefore = PS2MemoryCard.currentDigest(romId: rom.id)
                }
                // Before the boot, so the game starts with the settings
                // rather than PCSX2's defaults until the panel is opened.
                //
                // Recovery first: if the last session never closed
                // cleanly, these go back to defaults before being
                // applied, so a setting that broke the picture cannot
                // break it again on every launch after.
                if PS2Graphics.recoverIfLastSessionFailed() {
                    shaderIndex = PS2Graphics.shaderIndex
                    blending = PS2Graphics.blending
                    upscale = PS2Graphics.upscale
                    menuStatus = "Picture settings were reset after the last session ended unexpectedly."
                }
                PS2Graphics.markSessionOpen()
                PS2Graphics.apply(romId: rom?.id)
                player.start(
                    discPath: discPath,
                    cardFileName: rom.map { PS2MemoryCard.fileName(romId: $0.id) },
                    view: view
                )
            }
            .ignoresSafeArea()

            if player.menuVisible {
                pauseMenu
            }

            if case .failed(let message) = player.state {
                VStack(spacing: 12) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Back") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        // Escape opens and closes it too, since a Mac keyboard is the
        // other thing always within reach even when the game itself is
        // never played on one.
        //
        // Sized to nothing rather than hidden with .opacity(0): this OS
        // version stops delivering interaction to a fully transparent
        // view, which is the same trap ios26-opacity-kills-uikit-touch
        // records, and a shortcut on a dead button never fires.
        .overlay(alignment: .topLeading) {
            Button("Pause") { player.toggleMenu() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
        }
        .onAppear {
            // PS2 runs in the shell's own window rather than through
            // MacWindow.setGameMode, which belongs to the libretro
            // player. The toolbar still has no business across the top
            // of a game, so this is asked for directly.
            MacWindow.setToolbarAutoHide(true)
            aspect = PS2Graphics.aspect(romId: rom?.id)
            renderer = PS2Graphics.renderer(romId: rom?.id)
            PS2Controls.menuIsOpen = { player.menuVisible }
            PS2Controls.onMenuButton = { id in menuButton(id) }
        }
        .onDisappear {
            MacWindow.setToolbarAutoHide(false)
            // A clean exit, so the settings that were live are cleared
            // of suspicion.
            PS2Graphics.markSessionClosed()
            player.stop()
            // Fired here rather than when the emulator thread returns,
            // because leaving the screen is the moment the save is
            // final and the moment a person expects it to travel.
            if let rom, let session {
                let before = cardDigestBefore
                Task { await PS2MemoryCard.store(rom: rom, session: session, since: before) }
            }
        }
    }

    /// The same shape as the native player's macPauseMenu: the game's
    /// name, what just happened, then the actions.
    ///
    /// Two of that panel's rows are deliberately absent rather than
    /// forgotten. Shader and letterbox glow are properties of
    /// NativePlayerRenderer, and PS2 does not use it: PCSX2 owns its
    /// own renderer, which is the whole reason this screen exists
    /// separately. PCSX2 has its own post-processing, so an equivalent
    /// is possible, but it is different work and an inert row that
    /// looks like the native player's would be a lie.
    @ViewBuilder
    private var pauseMenu: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    // The numbers belong here rather than over the
                    // game: they are what tells you whether the
                    // blending and resolution above are affordable.
                    Text(menuStatus ?? String(format: "Paused  ·  %.0f%% speed  ·  EE %.0f%%",
                                              player.speed, player.eeUsage))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)

                VStack(spacing: 8) {
                    settingRow("Shader", systemImage: "camera.filters",
                               value: PS2Graphics.shaderLabel(shaderIndex)) {
                        ForEach(PS2Graphics.shaders) { candidate in
                            Button {
                                shaderIndex = candidate.index
                                applyGraphics()
                            } label: {
                                if candidate.index == shaderIndex {
                                    Label(candidate.label, systemImage: "checkmark")
                                } else {
                                    Text(candidate.label)
                                }
                            }
                        }
                    }
                    settingRow("Renderer", systemImage: "cpu",
                               value: PS2Graphics.rendererLabel(renderer)) {
                        ForEach(PS2Graphics.renderers, id: \.value) { candidate in
                            Button {
                                renderer = candidate.value
                                PS2Graphics.setRenderer(candidate.value, romId: rom?.id)
                                applyGraphics()
                            } label: {
                                if candidate.value == renderer {
                                    Label(candidate.label, systemImage: "checkmark")
                                } else {
                                    Text(candidate.label)
                                }
                            }
                        }
                    }
                    settingRow("Aspect ratio", systemImage: "rectangle.ratio.16.to.9",
                               value: aspect) {
                        ForEach(PS2Graphics.aspects, id: \.self) { candidate in
                            Button {
                                aspect = candidate
                                PS2Graphics.setAspect(candidate, romId: rom?.id)
                                applyGraphics()
                            } label: {
                                if candidate == aspect {
                                    Label(candidate, systemImage: "checkmark")
                                } else {
                                    Text(candidate)
                                }
                            }
                        }
                    }
                    settingRow("Blending", systemImage: "drop",
                               value: PS2Graphics.blendingLabels[min(blending, 5)]) {
                        ForEach(Array(PS2Graphics.blendingLabels.enumerated()), id: \.offset) { index, label in
                            Button {
                                blending = index
                                applyGraphics()
                            } label: {
                                if index == blending {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    }
                    settingRow("Resolution", systemImage: "arrow.up.left.and.arrow.down.right",
                               value: PS2Graphics.upscaleLabel(upscale)) {
                        ForEach(PS2Graphics.upscales, id: \.value) { candidate in
                            Button {
                                upscale = Double(candidate.value)
                                applyGraphics()
                            } label: {
                                if Double(candidate.value) == upscale {
                                    Label(candidate.label, systemImage: "checkmark")
                                } else {
                                    Text(candidate.label)
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 20)

                HStack(spacing: 10) {
                    ForEach(Array(Self.menuRows.enumerated()), id: \.offset) { index, row in
                        menuRowButton(row: row, index: index)
                    }
                }
            }
            .frame(width: 460, alignment: .leading)
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .disabled(menuBusy)
        }
    }

    /// Split the same way the native player splits its own rows: the
    /// style and role vary per row, and expressing that inline defeats
    /// the type checker.
    @ViewBuilder
    private func menuRowButton(row: String, index: Int) -> some View {
        // The ring is drawn only once a pad has actually moved the
        // selection. With a pointer in hand it would be a second cursor
        // arguing with the real one.
        let selected = player.menuUsingController && index == player.menuSelection
        let ring = RoundedRectangle(cornerRadius: 7)
            .stroke(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
            .padding(-2)
        let action = {
            player.menuSelection = index
            activate(index)
        }

        if row == "Resume" {
            Button(action: action) {
                Text(row).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .overlay(ring)
            // Return resumes, the way a Mac panel's default button
            // does. Escape already closes it.
            .keyboardShortcut(.defaultAction)
        } else {
            Button(role: row == "Quit" ? .destructive : nil, action: action) {
                Text(row).frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .overlay(ring)
        }
    }

    /// The shape a Mac uses for a setting: a label, its current value,
    /// and a menu to change it. Same as the native player's.
    private func settingRow<Content: View>(
        _ title: String,
        systemImage: String,
        value: String,
        @ViewBuilder menu: () -> Content
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Menu {
                menu()
            } label: {
                HStack(spacing: 4) {
                    Text(value).foregroundStyle(.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 8))
    }

    private func applyGraphics() {
        PS2Graphics.shaderIndex = shaderIndex
        PS2Graphics.blending = blending
        PS2Graphics.upscale = upscale
        PS2Graphics.apply(romId: rom?.id)
    }

    private func menuButton(_ id: Int) {
        player.menuUsingController = true
        switch id {
        case PS2Controls.RetroPad.up, PS2Controls.RetroPad.left:
            player.menuSelection = max(0, player.menuSelection - 1)
        case PS2Controls.RetroPad.down, PS2Controls.RetroPad.right:
            player.menuSelection = min(Self.menuRows.count - 1, player.menuSelection + 1)
        case PS2Controls.RetroPad.a, PS2Controls.RetroPad.start:
            activate(player.menuSelection)
        case PS2Controls.RetroPad.b:
            player.setMenu(false)
        default:
            break
        }
    }

    private func activate(_ index: Int) {
        switch Self.menuRows[index] {
        case "Quit":
            player.setMenu(false)
            dismiss()
        case "Save":
            runStateAction("Saved.", "Could not save.") { CabinetPS2SaveStateToSlot(1) }
        case "Load":
            runStateAction("Loaded.", "No save state to load.") { CabinetPS2LoadStateFromSlot(1) }
        default:
            player.setMenu(false)
        }
    }

    /// Save and load block on the emulation thread, so they run off the
    /// main one and report what happened rather than leaving the panel
    /// looking like nothing was pressed.
    private func runStateAction(
        _ success: String, _ failure: String, _ work: @escaping () -> Bool
    ) {
        menuBusy = true
        menuStatus = nil
        Task {
            let ok = await Task.detached { work() }.value
            menuBusy = false
            menuStatus = ok ? success : failure
        }
    }
}
