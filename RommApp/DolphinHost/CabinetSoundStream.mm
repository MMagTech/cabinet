// Dolphin's audio out, on AVAudioEngine.
//
// Dolphin ships seven SoundStream backends and not one of them works
// here. cubeb is the Apple one and its vendored copy will not compile
// for an iOS-family target: its audiounit backend does have real iOS
// support, but this copy declares the CoreAudio device-property
// constants at file scope outside the guard that includes the header
// declaring them. OpenAL, ALSA, PulseAudio, OpenSLES and WASAPI are all
// other platforms. That leaves NullSound, which is silence.
//
// So Cabinet supplies its own, the same answer and the same shape as
// RommApp/PCSX2Host/CabinetAudioStream.mm. It is small because Dolphin's
// Mixer already does the work that makes audio hard: it buffers, it
// resamples from the console's rate to ours, and it stretches to absorb
// the difference between emulated time and real time. All this has to
// do is pull from it on demand.
//
// AVAudioSourceNode rather than a render callback on an audio unit: it
// is the supported way to push a block of samples into the engine from
// UIKit-family code, and it hands us a real-time thread without our
// having to make one.
//
// Compiled by tools/build-dolphin-mac.sh, never by Xcode.

#import <AVFoundation/AVFoundation.h>

#include <memory>
#include <vector>

#include "AudioCommon/SoundStream.h"

namespace
{
// 48 kHz stereo, which is what Dolphin's Mixer is constructed with and
// what the GameCube's DSP produces. Asking the engine for anything else
// would only add a second resample on top of the Mixer's own.
constexpr double kSampleRate = 48000.0;

class CabinetSoundStream final : public SoundStream
{
public:
  ~CabinetSoundStream() override { SetRunning(false); }

  bool Init() override
  {
    @autoreleasepool
    {
      m_engine = [[AVAudioEngine alloc] init];

      AVAudioFormat* format =
          [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kSampleRate channels:2];

      Mixer* mixer = GetMixer();
      __block std::vector<short>* scratch = &m_scratch;

      // Interleaved shorts from the Mixer, deinterleaved floats to the
      // engine. Mix returns how many frames it actually had; the rest
      // of the buffer must be silenced rather than left alone, or an
      // underrun repeats the tail of the last block as a buzz.
      m_source = [[AVAudioSourceNode alloc]
          initWithFormat:format
             renderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
                                   AVAudioFrameCount frameCount, AudioBufferList* outputData) {
               (void)timestamp;
               if (scratch->size() < frameCount * 2)
                 scratch->resize(frameCount * 2);

               const unsigned int got = mixer->Mix(scratch->data(), frameCount);
               // Once, the first time real samples arrive. Silence and a
               // stream that was never asked for anything look identical
               // from outside, and "we wired the audio" has been claimed
               // on that basis before.
               static bool announced = false;
               if (!announced && got > 0)
               {
                 announced = true;
                 NSLog(@"[GC] cabinet: audio flowing, %u frames on the first pull", got);
               }

               float* left = (float*)outputData->mBuffers[0].mData;
               float* right = outputData->mNumberBuffers > 1
                                  ? (float*)outputData->mBuffers[1].mData
                                  : nullptr;
               const short* in = scratch->data();
               for (AVAudioFrameCount frame = 0; frame < frameCount; ++frame)
               {
                 float l = 0.0f;
                 float r = 0.0f;
                 if (frame < got)
                 {
                   l = in[frame * 2] / 32768.0f;
                   r = in[frame * 2 + 1] / 32768.0f;
                 }
                 if (left)
                   left[frame] = l;
                 if (right)
                   right[frame] = r;
               }
               *isSilence = (got == 0);
               return noErr;
             }];

      [m_engine attachNode:m_source];
      [m_engine connect:m_source to:m_engine.mainMixerNode format:format];
      // Prepare, not start. Dolphin starts and stops the stream around
      // pauses and boots through SetRunning, and starting here would
      // mean audio before the first frame.
      [m_engine prepare];
      return true;
    }
  }

  bool SetRunning(bool running) override
  {
    @autoreleasepool
    {
      if (running == m_running)
        return true;
      if (running)
      {
        NSError* error = nil;
        if (![m_engine startAndReturnError:&error])
        {
          NSLog(@"[GC] audio engine would not start: %@", error);
          return false;
        }
      }
      else
      {
        [m_engine pause];
      }
      m_running = running;
      return true;
    }
  }

  void SetVolume(int volume) override
  {
    m_engine.mainMixerNode.outputVolume = volume / 100.0f;
  }

private:
  AVAudioEngine* m_engine = nil;
  AVAudioSourceNode* m_source = nil;
  std::vector<short> m_scratch;
  bool m_running = false;
};
}  // namespace

// Called from AudioCommon.cpp's CreateSoundStreamForBackend, through the
// declaration tools/patch-dolphin-mac.py inserts there.
std::unique_ptr<SoundStream> CabinetCreateSoundStream()
{
  return std::make_unique<CabinetSoundStream>();
}
