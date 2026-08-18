import Foundation

/// Temporary per-frame trace for GitHub issue #6, where Dreamcast holds
/// correct emulated speed and realtime audio while the picture arrives at
/// about twenty frames a second on hardware two generations apart.
///
/// Writes one CSV row per `draw(in:)` into the app container, to be pulled
/// off the device afterwards with:
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer \
///       --domain-identifier com.mmagtech.CabinetDev \
///       --source Library/Caches/frame-trace.csv --destination .
///
/// A file rather than a screen readout on purpose: the question is where
/// one frame's time goes, and answering it needs every frame at full
/// precision over a stretch of real play, not a smoothed average someone
/// reads off a moving picture and relays back.
///
/// The trace must not perturb what it measures, so rows accumulate in
/// memory and are handed to a background queue in batches; nothing touches
/// the filesystem on the draw thread.
///
/// Delete this file, its call site in `NativePlayerRenderer.draw(in:)`, and
/// the `debug*MS` accessors on `LibretroFrontend` together once the
/// Dreamcast frame path is settled.
final class FrameTrace {
    static let shared = FrameTrace()

    /// Roughly ten minutes at sixty rows a second. Past this the trace
    /// stops rather than growing without bound, since a session long
    /// enough to hit it has long since captured the answer.
    private static let maxRows = 36_000

    private let queue = DispatchQueue(label: "cabinet.frametrace", qos: .utility)
    private var pending: [String] = []
    private var written = 0
    private var started: CFAbsoluteTime = 0
    private var handle: FileHandle?

    /// Named per core rather than one shared file: sessions truncate on
    /// start, so a single name means launching any other game after the
    /// one under investigation silently destroys its trace. Cost a full
    /// Dreamcast run to a Game Boy game started afterwards.
    private var core = "unknown"

    /// The OS's own thermal verdict, cached from a notification rather
    /// than polled per frame. Added 2026-08-17: a fixed-work calibration
    /// loop inside Flycast proved the Apple TV slows itself down on a
    /// roughly two-minute rhythm with nobody playing, escalating as a run
    /// goes on, which is thermal throttling rather than anything in the
    /// emulator. This column is tvOS/iOS confirming that in its own words,
    /// and it stays useful afterwards: any future "it got slow" report can
    /// be checked against whether the box was hot at the time.
    private var thermal: Int32 = 0
    private var thermalObserver: NSObjectProtocol?

    private func startThermalWatch() {
        updateThermal()
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.updateThermal() }
    }

    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = 0
        case .fair: thermal = 1
        case .serious: thermal = 2
        case .critical: thermal = 3
        @unknown default: thermal = -1
        }
    }

    var fileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("frame-trace-\(core).csv")
    }

    /// Truncates any previous trace and writes the header. Called when a
    /// native game starts, so one file is one play session and there is no
    /// question which run the numbers came from.
    func begin(core: String) {
        self.core = core
        // The rate the core declared, so audio frames per wall second can
        // be read against the right target: 44,100 for Flycast, about
        // 32,768 for Gambatte. Comparing against a guessed rate is how a
        // core that is keeping up perfectly reads as if it were not.
        let sampleRate = LibretroFrontend.shared.audioSampleRate()
        queue.async {
            self.written = 0
            self.pending.removeAll(keepingCapacity: true)
            try? FileManager.default.removeItem(at: self.fileURL)
            FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: self.fileURL)
            // New columns append rather than insert, so a trace captured
            // before they existed still parses against the same offsets.
            let header = "# core=\(core) sample_rate=\(sampleRate)\n"
                + "elapsed_ms,draw_gap_ms,frames_run,run_ms,readback_ms,swizzle_ms,upload_ms,"
                + "audio_frames,hw_frames,run_calls,hw_dupes,target_fps,frame_w,frame_h,thermal\n"
            self.handle?.write(Data(header.utf8))
        }
        startThermalWatch()
        started = CFAbsoluteTimeGetCurrent()
    }

    /// One row. `run` is the whole `retro_run`; `readback` and `swizzle`
    /// are the parts of it this app itself owns on the hardware-render
    /// path (the synchronous `glReadPixels` off the core's FBO, then the
    /// per-pixel byte swizzle and vertical flip); `upload` is the copy
    /// into the Metal texture afterwards. `run` minus the other two is
    /// what the core actually spent emulating and drawing, which is the
    /// number that says whether the interpreter is the wall.
    func record(
        drawGap: Double, framesRun: Int,
        run: Double, readback: Double, swizzle: Double, upload: Double,
        audioFrames: UInt64, hwFrames: UInt64, runCalls: UInt64, hwDupes: UInt64,
        targetFPS: Double, frameWidth: Int, frameHeight: Int
    ) {
        guard started != 0, written < Self.maxRows else { return }
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
        let row = String(
            format: "%.1f,%.2f,%d,%.3f,%.3f,%.3f,%.3f,%llu,%llu,%llu,%llu,%.4f,%d,%d,%d\n",
            elapsed, drawGap, framesRun, run, readback, swizzle, upload,
            audioFrames, hwFrames, runCalls, hwDupes, targetFPS, frameWidth, frameHeight,
            thermal
        )
        pending.append(row)
        // Batched at about two seconds of play: small enough that a crash
        // or a force quit loses almost nothing, large enough that the
        // draw thread hands off work a hundred times a session rather
        // than sixty times a second.
        guard pending.count >= 120 else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        written += batch.count
        queue.async { self.handle?.write(Data(batch.joined().utf8)) }
    }

    /// Flushes whatever has not reached the batch threshold. Called when
    /// the player goes away, so the tail of a session survives even if
    /// nobody force quits cleanly.
    func end() {
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        started = 0
        queue.async {
            if !batch.isEmpty { self.handle?.write(Data(batch.joined().utf8)) }
            try? self.handle?.close()
            self.handle = nil
        }
    }
}
