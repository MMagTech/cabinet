//  Boots a GameCube disc straight from the command line, with a real
//  window.
//
//  The same reason PS2BenchHarness exists: the picture cannot be
//  checked by building, and the alternative is a person clicking
//  through sign-in and the library for every run. Give it a disc and it
//  opens the player at launch.
//
//  Inert unless asked for. With no -cabinetGCDisc on the command line
//  this file costs one UserDefaults read at startup and the app behaves
//  exactly as before.
//
//      "Cabinet Mac.app/Contents/MacOS/Cabinet Mac" \
//        -cabinetGCDisc /path/to/game.iso -cabinetGCSeconds 30
//
//  Seconds is a self-terminating budget so an automated run cannot
//  leave an emulator holding the display forever.

import SwiftUI

enum GCBenchHarness {
    static var discPath: String? {
        UserDefaults.standard.string(forKey: "cabinetGCDisc")
    }

    static var seconds: Int {
        let value = UserDefaults.standard.integer(forKey: "cabinetGCSeconds")
        return value > 0 ? value : 30
    }

    /// Seconds after boot to open the pause panel, hold it, then
    /// resume. Zero means never.
    ///
    /// Worth having from the start rather than added later: on PS2 its
    /// absence hid a real bug, where pausing shut the emulator down and
    /// a harness that only ever let a game run straight through
    /// reported a clean 60fps while the feature a person would actually
    /// use destroyed the VM.
    static var pauseAt: Int {
        UserDefaults.standard.integer(forKey: "cabinetGCPauseAt")
    }

    static var isActive: Bool { discPath?.isEmpty == false }
}

/// Wraps the player so the harness can end the run on its own.
struct GCBenchView: View {
    let discPath: String

    var body: some View {
        GCPlayerView(gamePath: discPath, title: "GameCube bench", romId: 0)
            .task {
                for tick in 1...GCBenchHarness.seconds {
                    try? await Task.sleep(for: .seconds(1))
                    if GCBenchHarness.pauseAt > 0, tick == GCBenchHarness.pauseAt {
                        print("GCBENCH pausing")
                        fflush(stdout)
                        CabinetDolphinSetPaused(true)
                    }
                    if GCBenchHarness.pauseAt > 0, tick == GCBenchHarness.pauseAt + 3 {
                        print("GCBENCH resuming")
                        fflush(stdout)
                        CabinetDolphinSetPaused(false)
                    }
                    // Printed rather than only shown, because the whole
                    // point of the harness is a run nobody is watching.
                    // A burst rather than one frame, and through
                    // Dolphin's own screenshot path rather than a screen
                    // capture: one frame lands on whatever the game
                    // happens to be showing, and a capture cannot tell a
                    // black picture from a display that is asleep.
                    if tick >= 12, tick < 18 {
                        CabinetDolphinScreenshot("cabinet-\(tick)")
                    }
                    let m = CabinetDolphinGetMetrics()
                    print(String(format: "GCBENCH t=%3ds fps=%6.2f vps=%6.2f speed=%6.1f%%",
                                 tick, m.fps, m.vps, m.speed))
                    fflush(stdout)
                }
                CabinetDolphinRequestStop()
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
    }
}
