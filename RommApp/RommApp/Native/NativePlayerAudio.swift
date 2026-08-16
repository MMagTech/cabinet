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

        let sampleRate = LibretroFrontend.shared.audioSampleRate()
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
            if count > capacity {
                // Overrun: keep the newest second, drop what fell behind.
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
