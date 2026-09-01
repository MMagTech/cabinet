//  Boots a PS2 disc straight from the command line, with a real window.
//
//  cabinet-ps2-smoke already proves the emulator runs, but it draws
//  nothing: no view, no window, null renderer. This is the other half,
//  the path a person actually takes, and it exists because the picture
//  cannot be checked by building. Give it a disc and it opens the
//  player at launch, skipping sign-in, the library and every tap in
//  between.
//
//  Inert unless asked for, the same way NativeBenchHarness is: with no
//  -cabinetPS2Disc on the command line this file costs one UserDefaults
//  read at startup and the app behaves exactly as before.
//
//      "Cabinet Mac.app/Contents/MacOS/Cabinet Mac" \
//        -cabinetPS2Disc /path/to/game.chd -cabinetPS2Seconds 20
//
//  Seconds is a self-terminating budget so an automated run cannot
//  leave an emulator holding the display forever.

import SwiftUI

enum PS2BenchHarness {
    static var discPath: String? {
        UserDefaults.standard.string(forKey: "cabinetPS2Disc")
    }

    static var seconds: Int {
        let value = UserDefaults.standard.integer(forKey: "cabinetPS2Seconds")
        return value > 0 ? value : 30
    }

    static var isActive: Bool { discPath?.isEmpty == false }

    /// Seconds after boot to change a graphics setting, for testing the
    /// runtime apply path. Zero means never.
    static var changeAt: Int {
        UserDefaults.standard.integer(forKey: "cabinetPS2ChangeAt")
    }

    /// Seconds after boot to open the pause panel, hold it, then
    /// resume. Zero means never.
    ///
    /// Exists because its absence hid a real bug: pausing shut the
    /// emulator down, and a harness that only ever let a game run
    /// straight through reported a clean 60fps while the feature a
    /// person would actually use destroyed the VM.
    static var pauseAt: Int {
        UserDefaults.standard.integer(forKey: "cabinetPS2PauseAt")
    }

    /// Where to write a PNG of the rendered frame, if anywhere.
    static var shotPath: String? {
        UserDefaults.standard.string(forKey: "cabinetPS2Shot")
    }
}

/// Wraps the player so the harness can end the run on its own.
struct PS2BenchView: View {
    let discPath: String

    var body: some View {
        PS2PlayerView(discPath: discPath, title: "PS2 bench")
            .task {
                // Printed rather than only shown, because the whole
                // point of the harness is a run nobody is watching.
                for tick in 1...(PS2BenchHarness.seconds) {
                    try? await Task.sleep(for: .seconds(1))
                    if let shot = PS2BenchHarness.shotPath, tick == 6 {
                        print("PS2BENCH screenshot -> \(shot)")
                        fflush(stdout)
                        CabinetPS2Screenshot(shot)
                    }
                    if PS2BenchHarness.pauseAt > 0, tick == PS2BenchHarness.pauseAt {
                        print("PS2BENCH pausing")
                        fflush(stdout)
                        CabinetPS2SetPaused(true)
                    }
                    if PS2BenchHarness.pauseAt > 0, tick == PS2BenchHarness.pauseAt + 3 {
                        print("PS2BENCH resuming")
                        fflush(stdout)
                        CabinetPS2SetPaused(false)
                    }
                    if PS2BenchHarness.pauseAt > 0, tick == PS2BenchHarness.pauseAt + 4 {
                        // The other thing a paused panel does, and the
                        // one that would deadlock if the queue stopped
                        // draining while paused.
                        print("PS2BENCH save slot 1 -> \(CabinetPS2SaveStateToSlot(1))")
                        fflush(stdout)
                    }
                    if PS2BenchHarness.changeAt > 0, tick == PS2BenchHarness.changeAt {
                        print("PS2BENCH changing graphics now")
                        fflush(stdout)
                        // Aspect specifically: it is the one runtime
                        // change not yet exercised, and the one that
                        // locked the emulator up in real use.
                        PS2Graphics.setAspect("16:9", romId: 604)
                        PS2Graphics.blending = 3
                        PS2Graphics.apply(romId: 604)
                    }
                    let m = CabinetPS2GetMetrics()
                    print(String(format: "PS2BENCH t=%3ds fps=%6.2f speed=%6.1f%% ee=%5.1f%% gs=%5.1f%%",
                                 tick, m.fps, m.speed, m.ee_usage, m.gs_usage))
                    fflush(stdout)
                }
                CabinetPS2RequestStop()
                // A harness run is a clean exit, and has to say so.
                // Without this every run looks like a crash to the
                // recovery check, which then wipes the very settings
                // the run was meant to test.
                PS2Graphics.markSessionClosed()
                try? await Task.sleep(for: .seconds(2))
                exit(0)
            }
    }
}
