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
//  state slot, and a per-game memory card that syncs to RomM. What is
//  NOT here yet, and is not hidden: no per-game picture settings, and
//  the C stick is only reachable through four digital directions
//  because GameControllerManager publishes no right-stick axis. PS2 has
//  that same gap and the same fix would close both.

import SwiftUI

struct GCPlayerView: View {
    private static let menuRows = ["Quit", "Save", "Load", "Resume"]

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
        }
        .padding(28)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
