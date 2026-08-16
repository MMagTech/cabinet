import AVFoundation
import os

/// Feeds the core's audio batches into CoreAudio through a small ring
/// buffer, decoupling the core's variable per-frame sample count from the
/// fixed render callback AVAudioEngine expects. Core-agnostic, same as
/// LibretroFrontend itself, and shared between iOS's player
/// (NativePlayerView) and tvOS's (TVPlayerView) rather than duplicated.
///
/// The render callback runs on CoreAudio's realtime thread, which must
/// never allocate, never do work proportional to the buffer, and never
/// block on a lock that a lower-priority thread can hold. The first
/// version of this class did all three (it built a fresh Swift Array per
/// callback, called `removeFirst` on an Array holding up to a second of
/// audio, and took an NSLock), which glitches by construction and was
/// reported as static on both platforms. This one preallocates its
/// storage once, copies with memcpy, and holds an os_unfair_lock across
/// nothing but index arithmetic and that copy.
final class NativePlayerAudio {
    private let engine = AVAudioEngine()
    /// Interleaved stereo Int16, exactly as the cores hand it over, sized
    /// at about a second so a stalled draw loop cannot grow it and a
    /// brief hitch cannot empty it.
    private let capacity = 44_100 * 2
    /// How much audio is allowed to sit queued, in samples. The ring is
    /// allocated far larger, but letting it actually fill would pin
    /// playback a full second behind the picture: cores run slightly
    /// faster than the hardware consumes (we drive them at the display's
    /// 60Hz while NTSC systems want 59.94, about 0.1% surplus), so the
    /// buffer creeps to full and stays there, roughly 17 minutes into a
    /// session. Trimming to a target instead bounds the delay and sheds
    /// the drift a fraction of a percent at a time, which is inaudible,
    /// rather than accumulating it into a second of lag plus continuous
    /// drops. 64ms matches RetroArch's own default audio latency
    /// (DEFAULT_OUT_LATENCY in its config.def.h).
    private var highWaterSamples = Int(44_100.0 * 0.064) * 2
    private let ring: UnsafeMutablePointer<Int16>
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    /// Allocated rather than stored inline: os_unfair_lock must never be
    /// copied, and Swift does not promise a stable address for a stored
    /// property, so `&self.lock` can silently lock a copy.
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private var started = false
    /// The last frame handed to CoreAudio, faded to silence across an
    /// underrun rather than either repeated or cut to zero. Repeating it
    /// drones and smears music (Crazy Taxi, on device, 2026-08-16) and
    /// cutting straight to zero clicks; a short ramp does neither.
    private var lastLeft: Float32 = 0
    private var lastRight: Float32 = 0
    /// Whether enough audio is queued to play from without immediately
    /// running dry. Touched only on the render thread.
    ///
    /// Without this the callback starts draining the moment a single
    /// sample arrives, so the buffer lives at the edge of empty and every
    /// hitch in the draw loop is an underrun, which is a continuous
    /// crackle on any core that cannot comfortably hold realtime. Delta
    /// solves the same problem the same way (its audio manager refuses to
    /// play until primed and re-primes after a starve); this is that
    /// approach, written here rather than borrowed, since Delta is AGPL
    /// and this project is MIT.
    private var isPrimed = false

    init() {
        ring = UnsafeMutablePointer<Int16>.allocate(capacity: capacity)
        ring.initialize(repeating: 0, count: capacity)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        engine.stop()
        ring.deinitialize(count: capacity)
        ring.deallocate()
        lock.deallocate()
    }

    func start() {
        guard !started else { return }
        started = true

        // The same session the webview player has always set
        // (PlayerView's own setCategory/setActive pair). The native
        // player never set one, so native games ran under whatever
        // category the process happened to have, which is not the
        // category a game wants and leaves the I/O buffer at whatever
        // the system picked. Two players in one app should not disagree
        // about this.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        let sampleRate = LibretroFrontend.shared.audioSampleRate()
        highWaterSamples = min(capacity, Int(sampleRate * 0.064) * 2)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let framesNeeded = Int(frameCount)
            // Standard format is non-interleaved, so this is one mono
            // buffer per channel. Reading each channel's own offset out of
            // the interleaved ring is what makes this real stereo rather
            // than left-channel-duplicated mono; see 72f8a4e, and the
            // merge that undid it, recorded in CLAUDE.md.
            let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float32.self) : nil
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float32.self) : nil

            os_unfair_lock_lock(self.lock)
            // Refuse to start (or restart) from a nearly empty buffer:
            // stay silent until there is more than one callback's worth
            // of slack, so a single late batch from the draw loop does
            // not put us straight back into an underrun.
            if !self.isPrimed {
                if self.count / 2 < framesNeeded * 2 {
                    os_unfair_lock_unlock(self.lock)
                    for frame in 0..<framesNeeded {
                        left?[frame] = 0
                        right?[frame] = 0
                    }
                    self.lastLeft = 0
                    self.lastRight = 0
                    return noErr
                }
                self.isPrimed = true
            }
            let framesAvailable = min(framesNeeded, self.count / 2)
            var index = self.readIndex
            let scale = Float32(Int16.max)
            for frame in 0..<framesAvailable {
                let l = Float32(self.ring[index]) / scale
                let r = Float32(self.ring[(index + 1) % self.capacity]) / scale
                index = (index + 2) % self.capacity
                left?[frame] = l
                right?[frame] = r
                self.lastLeft = l
                self.lastRight = r
            }
            self.readIndex = index
            self.count -= framesAvailable * 2
            os_unfair_lock_unlock(self.lock)

            if framesAvailable < framesNeeded {
                // Ramp the last frame down to silence over about a
                // millisecond, then stay there for the rest of this
                // callback.
                let rampFrames = min(framesNeeded - framesAvailable, 48)
                for frame in framesAvailable..<framesNeeded {
                    let step = frame - framesAvailable
                    let gain = step < rampFrames ? 1 - Float32(step) / Float32(rampFrames) : 0
                    left?[frame] = self.lastLeft * gain
                    right?[frame] = self.lastRight * gain
                }
                self.lastLeft = 0
                self.lastRight = 0
                // Starved: refill before playing again rather than
                // dribbling out each late batch as it trickles in.
                self.isPrimed = false
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    /// Called from the draw loop with whatever the core produced this
    /// frame. Wrap-aware memcpy rather than a per-sample loop, and the
    /// oldest audio is dropped when the buffer is full, which only
    /// happens if the render side has stopped consuming.
    func enqueue(_ data: Data) {
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            guard !source.isEmpty, let base = source.baseAddress else { return }
            var offset = 0
            var remaining = source.count
            // A batch larger than the whole ring can only be the tail of
            // itself; skip straight to that.
            if remaining > capacity {
                offset = remaining - capacity
                remaining = capacity
            }

            os_unfair_lock_lock(lock)
            while remaining > 0 {
                let chunk = min(remaining, capacity - writeIndex)
                (ring + writeIndex).update(from: base + offset, count: chunk)
                writeIndex = (writeIndex + chunk) % capacity
                offset += chunk
                remaining -= chunk
                count += chunk
            }
            if count > highWaterSamples {
                // Past the latency target: keep the newest audio, drop
                // what fell behind.
                // Rounded up to a whole stereo frame, because the ring is
                // interleaved and dropping an odd number of samples
                // shifts every later read by one, swapping left and right
                // for the rest of the session.
                var dropped = count - capacity
                if dropped % 2 != 0 { dropped += 1 }
                readIndex = (readIndex + dropped) % capacity
                count -= dropped
            }
            os_unfair_lock_unlock(lock)
        }
    }
}
