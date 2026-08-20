#if DEBUG
import SwiftUI

/// A way to run one kept game, headless, for a fixed number of seconds and
/// then quit, so a core's cost can be measured without anybody playing.
///
/// This exists because the quality pass of 2026-08-17 needed to A/B core
/// options on real hardware, and the alternative was asking Marcus to play
/// each of twelve systems by hand after every single change. `FrameTrace`
/// already writes everything worth knowing; the only missing piece was a
/// way to start a game and stop it again from a shell.
///
/// Deliberately `#if DEBUG` and deliberately gated on a launch argument
/// nothing else passes: with no `-cabinetBench` on the command line this
/// file's only effect is one `UserDefaults` read at startup, and the app
/// takes exactly the path it took before. It never ships in a release
/// build at all.
///
/// Compiles for both platforms. tvOS gets it because nine platforms' worth
/// of this pass's changes ship there on the strength of iPhone measurements
/// alone, and the Apple TV 4K 3rd gen is a slower, fanless machine where
/// that extrapolation is least safe.
///
/// Drive it with:
///
///     xcrun devicectl device process launch --terminate-existing \
///       --device <id> com.mmagtech.CabinetDev \
///       -cabinetBench <romId> -cabinetBenchSeconds 45
///
/// then pull `Library/Caches/frame-trace-<core>.csv` off the device.
enum NativeBenchHarness {
    struct Plan {
        let rom: Rom
        let core: NativeCore
        let seconds: Double
    }

    /// The plan this launch asked for, or nil for an ordinary launch.
    ///
    /// Read from `UserDefaults`, not `CommandLine.arguments`, because
    /// `-key value` pairs on the command line are exactly what
    /// `UserDefaults` already parses into the argument domain, and going
    /// through it means no hand-rolled flag parsing to get wrong.
    /// The rom id this launch asked for, or nil for an ordinary launch.
    @MainActor
    static var requestedRomId: Int? {
        let id = UserDefaults.standard.integer(forKey: "cabinetBench")
        return id > 0 ? id : nil
    }

    static var seconds: Double {
        let s = UserDefaults.standard.double(forKey: "cabinetBenchSeconds")
        return s > 0 ? s : 40
    }

    /// A kept game resolves with no network at all, which is the fast path
    /// and the one repeat runs want.
    ///
    /// Anything else falls back to fetching the rom from the server, which
    /// `NativeLauncher.prepare` then downloads exactly as a real launch
    /// would. This used to be kept-games-only, on the reasoning that a
    /// benchmark which downloads first measures the network rather than the
    /// core. True for the first run, but it also meant the harness could
    /// only ever see what somebody had already chosen to keep: 46 titles,
    /// one of them SNES, against a library of 813. Measuring Mode 7 needed
    /// a Mode 7 game, and none was kept, so the restriction was costing far
    /// more than the download it avoided. The download happens before
    /// `FrameTrace.begin`, so it never lands in the numbers.
    @MainActor
    static func plan(session: Session) async -> Plan? {
        guard let romId = requestedRomId else { return nil }
        if let kept = KeptGameStore.shared.games.first(where: { $0.romId == romId }),
           let core = NativeCore.core(
               bySlug: kept.resolvedCanonicalSlug, isArcade: kept.rom.isArcade
           ) {
            return Plan(rom: kept.rom, core: core, seconds: seconds)
        }
        guard let rom = try? await session.rom(id: romId) else { return nil }
        let slug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        guard let core = NativeCore.core(for: rom, canonicalSlug: slug) else { return nil }
        return Plan(rom: rom, core: core, seconds: seconds)
    }
}

/// Presents the native player for a bench plan and quits the app when the
/// run is up.
///
/// Exiting with `exit(0)` rather than leaving the app open is what makes
/// this scriptable: the launching shell waits on the process, so a run is
/// finished when the command returns, with no polling and no guessing at
/// how long a game takes to settle. `FrameTrace.end()` runs first through
/// the player's own `onDisappear`, so the tail of the trace is on disk
/// before the process goes away.
struct NativeBenchRunnerView: View {
    @EnvironmentObject private var session: Session
    @State private var plan: NativeBenchHarness.Plan?
    @State private var ready = false
    @State private var failure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let failure {
                Text(failure).foregroundStyle(.white).padding()
            } else if !ready {
                ProgressView().tint(.white)
            }
        }
        .fullScreenCover(isPresented: $ready) {
            if let plan {
                // Each platform's own player, the same split HomeView makes.
                #if os(iOS)
                NativePlayerView(rom: plan.rom, core: plan.core)
                    .environmentObject(session)
                #else
                TVPlayerView(rom: plan.rom, core: plan.core)
                    .environmentObject(session)
                #endif
            }
        }
        .task {
            // The platform mapping has to be in hand before launching.
            // `NativeLauncher.prepare` resolves a rom's platform through
            // `session.platformsVersions`, and a bench launch starts with
            // that empty, so a kept NES game arrives carrying its RomM
            // folder name ("Nintendo") rather than "nes" and resolves to no
            // core at all. The real app never hits this because the library
            // screen has already loaded the mapping by the time anybody can
            // press play.
            await session.loadPlatformConfigIfNeeded()
            guard let plan = await NativeBenchHarness.plan(session: session) else {
                NSLog("[bench] could not resolve rom %d", NativeBenchHarness.requestedRomId ?? -1)
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(70)
            }
            self.plan = plan
            do {
                NSLog("[bench] rom=%d fsName=%@ slug=%@ isArcade=%d core=%@",
                      plan.rom.id, plan.rom.fsName, plan.rom.platformFsSlug,
                      plan.rom.isArcade ? 1 : 0, "\(plan.core)")
                _ = try await NativeLauncher.prepare(rom: plan.rom, session: session)
                ready = true
            } catch {
                NSLog("[bench] prepare failed: %@", "\(error)")
                failure = "bench prepare failed: \(error.localizedDescription)"
                // Still exit, with a distinct status, so a scripted run
                // reports a failure instead of hanging until its timeout.
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(70)
            }
            try? await Task.sleep(nanoseconds: UInt64(plan.seconds * 1_000_000_000))
            // What the core is actually emitting. Logged rather than added
            // to FrameTrace: that file is shared with the in-flight
            // Dreamcast investigation and is not this pass's to touch.
            // This is the only direct read on whether an option that
            // changes a core's output format (FBNeo's 32-bit colour depth,
            // PCSX ReARMed's rgb32 output) really took effect, as opposed
            // to being sent and quietly ignored.
            //
            // Polled, not read once: `latestFrame` hands back nil unless a
            // frame is dirty, and the renderer's own draw loop consumes and
            // clears it sixty times a second, so a single call loses that
            // race almost every time. Stealing one frame from the renderer
            // is harmless here because the run is over by this point and
            // every measurement has already been recorded.
            for _ in 0..<120 {
                if let frame = LibretroFrontend.shared.latestFrame() {
                    NSLog("[bench] pixelFormat=%d size=%dx%d bytesPerRow=%d",
                          frame.pixelFormat.rawValue, frame.width, frame.height,
                          frame.bytesPerRow)
                    break
                }
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            ready = false
            // One runloop turn for the player's onDisappear to flush the
            // trace and shut the core down cleanly.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            exit(0)
        }
    }
}
#endif
