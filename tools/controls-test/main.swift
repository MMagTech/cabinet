// The controls lab: runs GameControllerManager's real direction state
// machines headless in the iOS simulator, driving them through the
// DEBUG test seam exactly the way a physical pad's handlers do. Built
// after 2026-08-20, when an experimental per-frame poll cleared
// stick-held directions and killed the left stick on arcade: the class
// of bug this file exists to catch before a device ever sees it.
//
// Build and run: tools/controls-test/run.sh (simctl spawn on a booted
// simulator; no UI, exit code 0 on green).

import Foundation
import GameController

@MainActor
func runTests() -> Int {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
    }

    let mgr = GameControllerManager.shared
    var events: [(player: Int, id: Int, down: Bool)] = []
    var stickEvents: [(player: Int, x: Float, y: Float)] = []
    mgr.send = { player, id, down in events.append((player, id, down)) }
    mgr.sendStick = { player, x, y in stickEvents.append((player, x, y)) }
    func reset() { events.removeAll(); stickEvents.removeAll() }

    // 1. The regression class: on a digitizing platform, no other
    // source's release may drop a stick-held direction.
    mgr.activePlatform = "arcade"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, true) },
          "arcade: stick right presses the direction")
    reset()
    mgr._testInjectDpad(RetroPad.right, down: false)
    check(events.isEmpty,
          "arcade: phantom d-pad release cannot drop a stick-held direction")
    mgr._testInjectDpad(RetroPad.right, down: true)
    check(events.isEmpty,
          "arcade: d-pad press on an already-held direction emits nothing")
    mgr._testInjectDpad(RetroPad.right, down: false)
    check(events.isEmpty,
          "arcade: d-pad release while the stick still holds emits nothing")
    mgr._testInjectStick(x: 0, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, false) },
          "arcade: stick release finally releases the direction")

    // 2. Union the other way round: the stick may not drop a d-pad hold.
    reset()
    mgr._testInjectDpad(RetroPad.left, down: true)
    check(events.contains { $0 == (0, RetroPad.left, true) },
          "arcade: d-pad press reaches the game")
    reset()
    mgr._testInjectStick(x: -1.0, y: 0)
    check(events.isEmpty,
          "arcade: stick engaging an already-held direction emits nothing")
    mgr._testInjectStick(x: 0, y: 0)
    check(events.isEmpty,
          "arcade: stick release while the d-pad still holds emits nothing")
    mgr._testInjectDpad(RetroPad.left, down: false)
    check(events.contains { $0 == (0, RetroPad.left, false) },
          "arcade: d-pad release finally releases the direction")

    // 3. Hysteresis survives the refactor: engage above 0.5, hold
    // through 0.45, release below 0.4.
    reset()
    mgr._testInjectStick(x: 0.45, y: 0)
    check(events.isEmpty, "hysteresis: 0.45 does not engage")
    mgr._testInjectStick(x: 0.6, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, true) }, "hysteresis: 0.6 engages")
    reset()
    mgr._testInjectStick(x: 0.45, y: 0)
    check(events.isEmpty, "hysteresis: held through 0.45")
    mgr._testInjectStick(x: 0.3, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, false) }, "hysteresis: 0.3 releases")

    // 4. Analog platforms do not digitize, and the analog value flows.
    mgr.activePlatform = "dreamcast"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0)
    check(!events.contains { $0.id == RetroPad.right },
          "dreamcast: stick presses no d-pad direction")
    check(stickEvents.contains { $0.player == 0 && $0.x == 1.0 },
          "dreamcast: analog value reaches sendStick")
    mgr._testInjectStick(x: 0, y: 0)

    // 5. Mode transition mid-hold releases the stick's claims.
    mgr.activePlatform = "arcade"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, true) }, "transition: held on arcade")
    reset()
    mgr.activePlatform = "n64"
    check(events.contains { $0 == (0, RetroPad.right, false) },
          "transition: switching to an analog platform releases the held direction")
    mgr.activePlatform = nil

    // 6. Second stick ids are their own space.
    mgr.activePlatform = "arcade"
    reset()
    mgr._testInjectStick2(x: 1.0, y: 0)
    check(events.contains { $0 == (0, 20, true) }, "stick2: right presses id 20")
    mgr._testInjectStick2(x: 0, y: 0)
    check(events.contains { $0 == (0, 20, false) }, "stick2: release")

    // 7. Players are independent.
    reset()
    mgr._testInjectStick(x: 1.0, y: 0, player: 1)
    check(events.contains { $0 == (1, RetroPad.right, true) }, "p2: stick right presses")
    check(!events.contains { $0.player == 0 }, "p2: no bleed into player 1")
    mgr._testInjectDpad(RetroPad.right, down: false, player: 0)
    mgr._testInjectStick(x: 0, y: 0, player: 1)
    check(events.contains { $0 == (1, RetroPad.right, false) }, "p2: release")

    // 8. Platform profile isolation: only n64 and dreamcast differ, and
    // only in the declared ways.
    let d = ControllerBindings.defaults
    for p in ["arcade", "snes", "nes", "gb", "gba", "genesis", "saturn", "psx",
              "pce", "ngp", "atari7800", "32x", "unknownfuture"] {
        let prof = ControllerBindings.profile(for: p)
        check(prof.base == d && prof.digitizesLeftStick,
              "profile[\(p)]: identical to defaults, digitizing on")
    }
    check(ControllerBindings.profile(for: nil).base == d
          && ControllerBindings.profile(for: nil).digitizesLeftStick,
          "profile[nil shell/webview]: defaults, digitizing on")
    let dc = ControllerBindings.profile(for: "dreamcast")
    check(dc.base == d && !dc.digitizesLeftStick,
          "profile[dreamcast]: defaults base, digitizing off")
    let n = ControllerBindings.profile(for: "n64")
    check(!n.digitizesLeftStick, "profile[n64]: digitizing off")
    check(n.base[GCInputButtonA] == RetroPad.b && n.base[GCInputButtonB] == RetroPad.y
          && n.base[GCInputButtonX] == RetroPad.a && n.base[GCInputButtonY] == RetroPad.x,
          "profile[n64]: the four face buttons land on the N64's own labels")
    check(n.base.filter { ![GCInputButtonA, GCInputButtonB, GCInputButtonX,
                            GCInputButtonY].contains($0.key) }
          == d.filter { ![GCInputButtonA, GCInputButtonB, GCInputButtonX,
                          GCInputButtonY].contains($0.key) },
          "profile[n64]: everything except the face buttons matches defaults")

    // 9. Saved remaps are edits against defaults, applied over the
    // platform base (review finding 2026-08-20: wholesale replacement
    // silently reverted the N64 map for anyone who ever remapped).
    let testPad = "harness-test-pad"
    var edited = ControllerBindings.defaults
    edited[GCInputLeftShoulder] = RetroPad.select      // moved Coin
    edited.removeValue(forKey: GCInputButtonOptions)   // cleared a binding
    ControllerBindings.save(edited, for: testPad)
    let onDefaults = ControllerBindings.effective(for: testPad)
    check(onDefaults[GCInputLeftShoulder] == RetroPad.select
          && onDefaults[GCInputButtonOptions] == nil,
          "remap: edit and clear both stick on default-base platforms")
    check(onDefaults == edited,
          "remap: default-base result reproduces old wholesale behaviour")
    let onN64 = ControllerBindings.effective(for: testPad, platform: "n64")
    check(onN64[GCInputButtonB] == RetroPad.y,
          "remap: untouched face buttons still get the N64 labels")
    check(onN64[GCInputLeftShoulder] == RetroPad.select
          && onN64[GCInputButtonOptions] == nil,
          "remap: the player's edit and clear survive on N64")
    var faceEdit = ControllerBindings.defaults
    faceEdit[GCInputButtonB] = RetroPad.l2              // deliberate face change
    ControllerBindings.save(faceEdit, for: testPad)
    check(ControllerBindings.effective(for: testPad, platform: "n64")[GCInputButtonB]
          == RetroPad.l2,
          "remap: a deliberate face-button edit outranks the N64 base")
    ControllerBindings.reset(for: testPad)

    // 10. A platform change releases anything held, so no press can
    // straddle a rebind and orphan its release under a different map.
    mgr.activePlatform = "arcade"
    reset()
    mgr._testInjectDpad(RetroPad.up, down: true)
    check(events.contains { $0 == (0, RetroPad.up, true) }, "rebind: held before switch")
    reset()
    mgr.activePlatform = "n64"
    check(events.contains { $0 == (0, RetroPad.up, false) },
          "rebind: platform change releases held inputs")
    mgr.activePlatform = nil

    print(failures == 0 ? "ALL GREEN" : "\(failures) FAILURES")
    return failures
}

exit(Int32(MainActor.assumeIsolated { runTests() }))
