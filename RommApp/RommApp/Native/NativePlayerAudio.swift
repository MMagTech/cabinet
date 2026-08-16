import AVFoundation

/// Feeds the core's audio batches into CoreAudio through a small ring
/// buffer, decoupling the core's variable per-frame sample count from the
/// fixed render callback AVAudioEngine expects. Core-agnostic, same as
/// LibretroFrontend itself, and shared between iOS's real player
/// (NativePlayerView) and tvOS's test harness (PS1PlayTestView) rather
/// than duplicated between them.
final class NativePlayerAudio {
    private let engine = AVAudioEngine()
    private var ringBuffer: [Int16] = []
    private let lock = NSLock()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let sampleRate = LibretroFrontend.shared.audioSampleRate()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        let sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let framesNeeded = Int(frameCount)

            self.lock.lock()
            let available = min(framesNeeded, self.ringBuffer.count / 2)
            let samples = Array(self.ringBuffer.prefix(available * 2))
            if available > 0 {
                self.ringBuffer.removeFirst(available * 2)
            }
            self.lock.unlock()

            // Non-interleaved format: `buffers` is one mono buffer per
            // channel (left, then right), each needing its own offset into
            // the interleaved ring buffer the core fills. Writing
            // `samples[frame * 2]` into every channel plays
            // left-channel-duplicated mono instead of real stereo.
            //
            // Fixed once already, in 72f8a4e on 2026-08-10, and silently
            // undone the next day: that fix landed in NativePlayerView.swift
            // while the tvOS branch had eight hours earlier extracted this
            // code into this file, so the merge kept the extraction, dropped
            // the inline copy the fix lived in, and conflicted on nothing.
            // Every native core has played mono since. Restored 2026-08-16.
            for (channel, buffer) in buffers.enumerated() {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                for frame in 0..<framesNeeded {
                    if frame < available {
                        data[frame] = Float32(samples[frame * 2 + channel]) / Float32(Int16.max)
                    } else {
                        data[frame] = 0
                    }
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func enqueue(_ data: Data) {
        let samples = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        lock.lock()
        ringBuffer.append(contentsOf: samples)
        // Cap the buffer so a stalled render loop can't grow this forever.
        let maxSamples = 44100 * 2 // ~1 second, stereo
        if ringBuffer.count > maxSamples {
            ringBuffer.removeFirst(ringBuffer.count - maxSamples)
        }
        lock.unlock()
    }
}
