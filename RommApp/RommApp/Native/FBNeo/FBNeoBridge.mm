#import "FBNeoBridge.h"
#include "libretro.h"
#include <string>
#include <vector>
#include <mutex>
#include <atomic>

extern "C" {
    unsigned retro_api_version(void);
    void retro_set_environment(retro_environment_t);
    void retro_set_video_refresh(retro_video_refresh_t);
    void retro_set_audio_sample(retro_audio_sample_t);
    void retro_set_audio_sample_batch(retro_audio_sample_batch_t);
    void retro_set_input_poll(retro_input_poll_t);
    void retro_set_input_state(retro_input_state_t);
    void retro_init(void);
    bool retro_load_game(const struct retro_game_info *);
    void retro_run(void);
    void retro_get_system_av_info(struct retro_system_av_info *);
    size_t retro_serialize_size(void);
    bool retro_serialize(void *, size_t);
    bool retro_unserialize(const void *, size_t);
}

@implementation FBNeoFrame
- (instancetype)initWithPixels:(NSData *)pixels width:(uint32_t)width height:(uint32_t)height bytesPerRow:(uint32_t)bytesPerRow pixelFormat:(FBNeoPixelFormat)pixelFormat {
    if ((self = [super init])) {
        _pixels = pixels;
        _width = width;
        _height = height;
        _bytesPerRow = bytesPerRow;
        _pixelFormat = pixelFormat;
    }
    return self;
}
@end

namespace {

std::string gSystemDirectory;
std::string gSaveDirectory;
bool gInitialized = false;
FBNeoPixelFormat gPixelFormat = FBNeoPixelFormatXRGB8888;

std::mutex gFrameMutex;
std::vector<uint8_t> gFrameBytes;
uint32_t gFrameWidth = 0;
uint32_t gFrameHeight = 0;
uint32_t gFrameBytesPerRow = 0;
bool gFrameDirty = false;

std::mutex gAudioMutex;
std::vector<int16_t> gAudioSamples; // interleaved stereo
double gAudioSampleRate = 44100.0;

uint32_t bytesPerPixel(FBNeoPixelFormat fmt) {
    switch (fmt) {
        case FBNeoPixelFormatXRGB8888: return 4;
        case FBNeoPixelFormatRGB1555:
        case FBNeoPixelFormatRGB565:
        default: return 2;
    }
}

void videoRefresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data || width == 0 || height == 0) {
        return; // duplicate-frame signal, nothing changed
    }
    std::lock_guard<std::mutex> lock(gFrameMutex);
    size_t needed = pitch * height;
    if (gFrameBytes.size() != needed) {
        gFrameBytes.resize(needed);
    }
    memcpy(gFrameBytes.data(), data, needed);
    gFrameWidth = width;
    gFrameHeight = height;
    gFrameBytesPerRow = (uint32_t)pitch;
    gFrameDirty = true;
}

void audioSample(int16_t left, int16_t right) {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    gAudioSamples.push_back(left);
    gAudioSamples.push_back(right);
}

size_t audioSampleBatch(const int16_t *data, size_t frames) {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    gAudioSamples.insert(gAudioSamples.end(), data, data + frames * 2);
    return frames;
}

std::atomic<uint32_t> gButtonMask{0};

void inputPoll(void) {}

int16_t inputState(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0 || device != RETRO_DEVICE_JOYPAD || id > 13) {
        return 0;
    }
    return (gButtonMask.load(std::memory_order_relaxed) >> id) & 1;
}

bool environmentCallback(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            *(const char **)data = gSystemDirectory.c_str();
            return true;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            *(const char **)data = gSaveDirectory.c_str();
            return true;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            gPixelFormat = (FBNeoPixelFormat)*(const enum retro_pixel_format *)data;
            return true;
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
            return true;
        default:
            return false;
    }
}

} // namespace

@implementation FBNeoBridge

+ (uint32_t)coreAPIVersion {
    return retro_api_version();
}

+ (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory {
    gSystemDirectory = systemDirectory.fileSystemRepresentation;
    gSaveDirectory = systemDirectory.fileSystemRepresentation;

    if (!gInitialized) {
        retro_set_environment(environmentCallback);
        retro_init();
        retro_set_video_refresh(videoRefresh);
        retro_set_audio_sample(audioSample);
        retro_set_audio_sample_batch(audioSampleBatch);
        retro_set_input_poll(inputPoll);
        retro_set_input_state(inputState);
        gInitialized = true;
    }

    struct retro_game_info info = {};
    std::string path = romPath.fileSystemRepresentation;
    info.path = path.c_str();
    info.data = nullptr;
    info.size = 0;
    info.meta = nullptr;

    if (!retro_load_game(&info)) {
        return @"retro_load_game returned false, FBNeo rejected the ROM or couldn't find the BIOS";
    }

    struct retro_system_av_info avInfo = {};
    retro_get_system_av_info(&avInfo);
    {
        std::lock_guard<std::mutex> lock(gAudioMutex);
        gAudioSampleRate = avInfo.timing.sample_rate > 0 ? avInfo.timing.sample_rate : 44100.0;
    }

    return nil;
}

+ (void)runFrame {
    if (gInitialized) {
        retro_run();
    }
}

+ (nullable FBNeoFrame *)latestFrame {
    std::lock_guard<std::mutex> lock(gFrameMutex);
    if (!gFrameDirty || gFrameBytes.empty()) {
        return nil;
    }
    NSData *pixels = [NSData dataWithBytes:gFrameBytes.data() length:gFrameBytes.size()];
    gFrameDirty = false;
    return [[FBNeoFrame alloc] initWithPixels:pixels
                                         width:gFrameWidth
                                        height:gFrameHeight
                                   bytesPerRow:gFrameBytesPerRow
                                   pixelFormat:gPixelFormat];
}

+ (nullable NSData *)drainAudio {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    if (gAudioSamples.empty()) {
        return nil;
    }
    NSData *data = [NSData dataWithBytes:gAudioSamples.data() length:gAudioSamples.size() * sizeof(int16_t)];
    gAudioSamples.clear();
    return data;
}

+ (double)audioSampleRate {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    return gAudioSampleRate;
}

+ (void)setButtonMask:(uint32_t)mask {
    gButtonMask.store(mask, std::memory_order_relaxed);
}

+ (nullable NSData *)serializeState {
    if (!gInitialized) {
        return nil;
    }
    size_t size = retro_serialize_size();
    if (size == 0) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!retro_serialize(data.mutableBytes, size)) {
        return nil;
    }
    return data;
}

+ (BOOL)unserializeState:(NSData *)state {
    if (!gInitialized || state.length == 0) {
        return NO;
    }
    return retro_unserialize(state.bytes, state.length);
}

@end
