//  The GameCube screen on the Mac.
//
//  Deliberately its own screen rather than a branch inside
//  NativePlayerView, and for the same reason PS2 has its own: GameCube
//  shares no code with the libretro path. Not the frontend, not the
//  renderer, not the audio, not the input. Routing it through the screen
//  twenty-three other cores use would put a Dolphin-shaped branch into
//  the most blast-radius-heavy file in the app to gain nothing.
//
//  What is here: picture, sound, controllers, a pause panel, one save
//  state slot, a per-game memory card that syncs to RomM, and the three
//  picture settings that matter on a big display. No shaders; see
//  GCGraphics for why.

import SwiftUI

struct GCPlayerView: View {
    private static let menuRows = ["Quit", "Save", "Load", "Resume"]

    /// Live, so the panel redraws when a row is stepped. The values
    /// themselves live in GCGraphics, machine-wide.
    @State private var resolutionIndex = GCGraphics.resolutionIndex
    @State private var antialiasingIndex = GCGraphics.antialiasingIndex
    @State private var anisotropyIndex = GCGraphics.anisotropyIndex

    let gamePath: String
    let title: String
    let romId: Int

    /// Present for a real launch, absent for the bench harness, which
    /// has no session to sync against.
    var rom: Rom? = nil
    var session: Session? = nil
    /// The harness's way to exercise the per-game card path without a
    /// rom behind it. Ignored on a real launch, which derives the path
    /// from the rom.
    var cardPathOverride: String? = nil

    @State private var player = GCPlayer()
    /// What the card looked like before play, so the upload afterwards
    /// can tell whether the game actually saved anything.
    @State private var cardDigestBefore: Data?
    /// What the panel says under the title: the result of the last
    /// action, or nothing, in which case it reads "Paused".
    @State private var menuStatus: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GCMetalSurface { view in
                if let rom {
                    cardDigestBefore = GCMemoryCard.currentDigest(romId: rom.id)
                }
                // Before the boot, so the game starts with these rather
                // than Dolphin's defaults for its first few seconds.
                GCGraphics.apply()
                player.start(
                    gamePath: gamePath,
                    romId: romId,
                    // The harness has no rom, so it gets Dolphin's
                    // shared card rather than a per-game one it would
                    // then have to clean up.
                    cardPath: rom.map { GCMemoryCard.url(romId: $0.id).path } ?? cardPathOverride,
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
        // view, which is the trap ios26-opacity-kills-uikit-touch
        // records, and a shortcut on a dead button never fires.
        .overlay(alignment: .topLeading) {
            Button("Pause") { player.toggleMenu() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0)
                .clipped()
                .accessibilityHidden(true)
        }
        .onAppear {
            GCControls.menuIsOpen = { player.menuVisible }
            GCControls.onMenuButton = { id in menuButton(id) }
        }
        .onDisappear {
            player.stop()
            // Dolphin flushes the card as it shuts down, so the upload
            // has to wait for that rather than read the file while the
            // emulator is still holding it. The task outlives this view
            // deliberately; it is the last chance a save has to travel.
            if let rom, let session {
                let before = cardDigestBefore
                Task.detached {
                    // Long enough for Dolphin's own shutdown to finish
                    // writing. It is not instant and there is no
                    // callback for it.
                    try? await Task.sleep(for: .seconds(3))
                    await GCMemoryCard.store(rom: rom, session: session, since: before)
                }
            }
        }
        .onChange(of: player.state) { _, state in
            // Dolphin stopping by itself, which is what a game's own
            // quit or a fatal error looks like from here, should leave
            // the screen rather than sit on a black rectangle.
            if state == .idle { dismiss() }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var pauseMenu: some View {
        VStack(spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(menuStatus ?? "Paused")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ForEach(Array(Self.menuRows.enumerated()), id: \.offset) { index, row in
                Button(row) { activate(index) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    // The controller drives the panel while it is up, so
                    // the focused row is drawn rather than left to the
                    // system, which has no idea a pad is being used.
                    .background(
                        player.menuUsingController && player.menuSelection == index
                            ? Color.accentColor.opacity(0.35)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
            }

            Divider()
            picture
        }
        .padding(28)
        .frame(maxWidth: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// The picture rows. Pickers rather than buttons because these are
    /// settings someone leaves alone, unlike the four actions above,
    /// which are things they do and then close the panel.
    private var picture: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Resolution", selection: $resolutionIndex) {
                ForEach(Array(GCGraphics.resolutions.enumerated()), id: \.offset) { index, entry in
                    Text(entry.label).tag(index)
                }
            }
            Picker("Smoothing", selection: $antialiasingIndex) {
                ForEach(Array(GCGraphics.antialiasing.enumerated()), id: \.offset) { index, entry in
                    Text(entry.label).tag(index)
                }
            }
            Picker("Texture detail", selection: $anisotropyIndex) {
                ForEach(Array(GCGraphics.anisotropy.enumerated()), id: \.offset) { index, entry in
                    Text(entry.label).tag(index)
                }
            }
        }
        .font(.callout)
        // One apply for all three, because Dolphin re-reads its whole
        // video config in one step and three separate calls would mean
        // three of those.
        .onChange(of: resolutionIndex) { _, new in
            GCGraphics.resolutionIndex = new
            GCGraphics.apply()
        }
        .onChange(of: antialiasingIndex) { _, new in
            GCGraphics.antialiasingIndex = new
            GCGraphics.apply()
        }
        .onChange(of: anisotropyIndex) { _, new in
            GCGraphics.anisotropyIndex = new
            GCGraphics.apply()
        }
    }

    private func activate(_ index: Int) {
        switch Self.menuRows[index] {
        case "Quit":
            player.stop()
            dismiss()
        case "Save":
            player.saveState()
            // Said rather than shown, because Dolphin schedules the
            // write onto its CPU thread rather than doing it here:
            // there is nothing to observe at the moment the row is
            // pressed, and a panel that changed nothing reads as a
            // button that did nothing.
            menuStatus = "Saving where you are."
        case "Load":
            player.loadState()
            menuStatus = "Going back to your last save."
        default:
            player.setMenu(false)
        }
    }

    /// A pad press while the panel is up. RetroPad ids, the same
    /// vocabulary everything else in Cabinet speaks.
    private func menuButton(_ retroId: Int) {
        player.menuUsingController = true
        switch retroId {
        case GCControls.RetroPad.up:
            player.menuSelection = max(0, player.menuSelection - 1)
        case GCControls.RetroPad.down:
            player.menuSelection = min(Self.menuRows.count - 1, player.menuSelection + 1)
        case GCControls.RetroPad.b, GCControls.RetroPad.a:
            activate(player.menuSelection)
        default:
            break
        }
    }
}
