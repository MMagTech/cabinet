//  Runs a GameCube game, and holds what the screen needs to show while
//  it does.
//
//  Dolphin is not driven a frame at a time the way a libretro core is,
//  and it is not driven the way PCSX2 is either. CabinetDolphinRun boots
//  the game and does not return until it stops, so it gets a thread of
//  its own; underneath, Dolphin runs its emulation and its video work on
//  threads of its own again. Everything here is about talking to that
//  from the main one.
//
//  Mac only, deliberately and permanently. See CabinetDolphinBridge.h.

import Foundation
import Observation

@Observable
@MainActor
final class GCPlayer {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The pause panel. Owned here rather than by the view because the
    /// emulator has to be paused in step with it.
    var menuVisible = false
    var menuSelection = 0
    var menuUsingController = false

    /// Where Dolphin writes this session's saves, memory cards, config
    /// and shader cache. Under Cabinet's own folder rather than
    /// Dolphin's, so nothing here collides with a real Dolphin install
    /// on the same Mac.
    nonisolated static var dataRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "Cabinet/GameCube")
    }

    /// One writable root per game rather than one shared: it keeps a
    /// game's memory card, its config and its shader cache together and
    /// makes "delete this game's data" a single directory.
    nonisolated static func userDirectory(romId: Int) -> URL {
        dataRoot.appending(path: "games/\(romId)")
    }

    /// Dolphin's own read-only Sys folder, bundled with the app. Boot
    /// fails without it rather than degrading: the GameCube IPL fonts
    /// live here and a game that draws text needs them.
    ///
    /// resourcePath, not bundlePath. On iOS those are the same folder,
    /// which is why the PSP core can use the bundle root, but a
    /// Catalyst app is a real macOS bundle and its resources sit in
    /// Contents/Resources. Copying the PSP line fails at runtime with
    /// the folder sitting right there.
    nonisolated static var sysPath: String {
        (Bundle.main.resourcePath ?? Bundle.main.bundlePath) + "/DolphinSys"
    }

    func start(gamePath: String, romId: Int, view: UnsafeMutableRawPointer) {
        guard state != .running else { return }

        let userDir = Self.userDirectory(romId: romId)
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        state = .running
        GCControls.attach(onMenu: { [weak self] in self?.toggleMenu() })

        Thread.detachNewThread { [weak self] in
            var error = [CChar](repeating: 0, count: 512)
            var ok = false

            gamePath.withCString { game in
                Self.sysPath.withCString { sys in
                    userDir.path.withCString { user in
                        var config = CabinetDolphinConfig(
                            game_path: game,
                            sys_dir: sys,
                            user_dir: user,
                            verbose_log: true
                        )
                        ok = CabinetDolphinRun(&config, &error, error.count)
                    }
                }
            }

            let message = ok ? "" : String(cString: error)
            Task { @MainActor in
                GCControls.detach()
                self?.state = ok
                    ? .idle
                    : .failed(message.isEmpty ? "GameCube failed to start." : message)
            }
        }
        _ = view
    }

    func toggleMenu() {
        setMenu(!menuVisible)
    }

    func setMenu(_ visible: Bool) {
        guard menuVisible != visible else { return }
        menuVisible = visible
        menuSelection = 0
        menuUsingController = false
        CabinetDolphinSetPaused(visible)
    }

    func stop() {
        // Controls first, the same ordering PS2 documents: the pad
        // state is read from Dolphin's emulation thread every frame,
        // and a button released during teardown should not be racing
        // shutdown.
        GCControls.detach()
        CabinetDolphinRequestStop()
    }
}
