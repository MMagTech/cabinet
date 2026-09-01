//  The GameCube screen on the Mac.
//
//  Deliberately its own screen rather than a branch inside
//  NativePlayerView, and for the same reason PS2 has its own: GameCube
//  shares no code with the libretro path. Not the frontend, not the
//  renderer, not the audio, not the input. Routing it through the screen
//  twenty-three other cores use would put a Dolphin-shaped branch into
//  the most blast-radius-heavy file in the app to gain nothing.
//
//  What is here: picture, sound, controllers, and a pause panel that can
//  quit. What is NOT here yet, and is not hidden: no save states, no
//  memory card sync back to RomM, and no per-game picture settings. PS2
//  grew all three after it was first playable and this will too.

import SwiftUI

struct GCPlayerView: View {
    private static let menuRows = ["Quit", "Resume"]

    let gamePath: String
    let title: String
    let romId: Int

    @State private var player = GCPlayer()
    @State private var menuStatus: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GCMetalSurface { view in
                player.start(gamePath: gamePath, romId: romId, view: view)
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
