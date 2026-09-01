// PS2 sound, through AVAudioEngine.
//
// PCSX2 ships two audio backends and neither survives Mac Catalyst:
// SDL3 does not build at all, and the vendored cubeb reaches for
// CoreAudio device APIs that exist only on desktop macOS. So this is a
// third, and it is small because AudioStream already does the hard
// part: the ring buffer, the resampling and the time stretching all
// live in the base class, and a backend only has to pull ReadFrames
// from a device callback at the right rate.
//
// AVAudioEngine rather than an AudioUnit directly, because it is the
// one output path already proven on this target: Cabinet's
// NativePlayerAudio drives all twenty-three other cores through it.

#include "common/Console.h"
#include "common/Error.h"

#include "pcsx2/Host/AudioStream.h"

#import <AVFoundation/AVFoundation.h>

namespace
{
	class CabinetAudioStream final : public AudioStream
	{
	public:
		CabinetAudioStream(u32 sample_rate, const AudioStreamParameters& parameters)
			: AudioStream(sample_rate, parameters)
		{
		}

		~CabinetAudioStream() override
		{
			Destroy();
		}

		bool Initialize(bool stretch_enabled, Error* error)
		{
			BaseInitialize(&StereoSampleReaderImpl, stretch_enabled);
			m_internal_channels = 2;
			m_output_channels = 2;

			@autoreleasepool
			{
				m_engine = [[AVAudioEngine alloc] init];

				AVAudioFormat* format =
					[[AVAudioFormat alloc] initStandardFormatWithSampleRate:static_cast<double>(m_sample_rate)
																  channels:2];
				if (!format)
				{
					Error::SetString(error, "Could not describe the PS2 audio format.");
					return false;
				}

				// Deinterleaved float, which is what
				// initStandardFormatWithSampleRate gives and what
				// AVAudioSourceNode hands back: two separate channel
				// buffers, where AudioStream reads interleaved. The
				// split happens in the callback.
				__block CabinetAudioStream* self_ptr = this;
				m_source = [[AVAudioSourceNode alloc]
					initWithFormat:format
					   renderBlock:^OSStatus(BOOL* isSilence, const AudioTimeStamp* timestamp,
									   AVAudioFrameCount frameCount, AudioBufferList* outputData) {
						   return self_ptr->Render(isSilence, frameCount, outputData);
					   }];

				[m_engine attachNode:m_source];
				[m_engine connect:m_source to:m_engine.mainMixerNode format:format];

				NSError* start_error = nil;
				if (![m_engine startAndReturnError:&start_error])
				{
					Error::SetString(error, [[start_error localizedDescription] UTF8String]);
					m_engine = nil;
					m_source = nil;
					return false;
				}
			}

			Console.WriteLnFmt("[PS2] Audio: AVAudioEngine started at {} Hz, stereo.", m_sample_rate);
			return true;
		}

		void SetPaused(bool paused) override
		{
			if (m_paused == paused)
				return;

			// The engine keeps running and the callback keeps being
			// asked; it just answers with silence. Stopping the engine
			// instead makes every pause and resume rebuild the audio
			// graph, which is both slower and a source of clicks.
			m_paused = paused;
		}

	private:
		OSStatus Render(BOOL* isSilence, AVAudioFrameCount frames, AudioBufferList* output)
		{
			if (m_paused || output->mNumberBuffers < 2)
			{
				*isSilence = YES;
				return noErr;
			}

			if (frames > m_scratch.size() / 2)
				m_scratch.resize(static_cast<size_t>(frames) * 2);

			ReadFrames(m_scratch.data(), frames);

			float* const left = static_cast<float*>(output->mBuffers[0].mData);
			float* const right = static_cast<float*>(output->mBuffers[1].mData);
			for (AVAudioFrameCount i = 0; i < frames; i++)
			{
				left[i] = m_scratch[i * 2];
				right[i] = m_scratch[i * 2 + 1];
			}

			// Once, on the first callback. "Stream created" only means
			// the graph was built; this is the line that says the
			// device is actually pulling samples, which is the
			// difference between working audio and silent success.
			if (!m_rendered_once)
			{
				m_rendered_once = true;
				Console.WriteLnFmt("[PS2] Audio: first {} frames pulled.", frames);
			}

			*isSilence = NO;
			return noErr;
		}

		void Destroy()
		{
			@autoreleasepool
			{
				if (m_engine)
				{
					[m_engine stop];
					if (m_source)
						[m_engine detachNode:m_source];
				}
				m_engine = nil;
				m_source = nil;
			}
		}

		AVAudioEngine* m_engine = nil;
		AVAudioSourceNode* m_source = nil;
		std::vector<SampleType> m_scratch;
		bool m_rendered_once = false;
	};
} // namespace

std::unique_ptr<AudioStream> CabinetCreateAudioStream(
	u32 sample_rate, const AudioStreamParameters& parameters, bool stretch_enabled, Error* error)
{
	std::unique_ptr<CabinetAudioStream> stream =
		std::make_unique<CabinetAudioStream>(sample_rate, parameters);
	if (!stream->Initialize(stretch_enabled, error))
		return nullptr;

	return stream;
}
