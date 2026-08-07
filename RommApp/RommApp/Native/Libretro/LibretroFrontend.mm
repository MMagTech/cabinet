#import "LibretroFrontend.h"
#include "LibretroCoreAPI.h"
#import "FBNeoCore.h"
#import "SaturnCore.h"
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <cstdarg>
#include <cstdio>

@implementation LibretroFrame
- (instancetype)initWithPixels:(NSData *)pixels width:(uint32_t)width height:(uint32_t)height bytesPerRow:(uint32_t)bytesPerRow pixelFormat:(LibretroPixelFormat)pixelFormat {
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

// File-static rather than instance state on purpose: libretro callbacks
// are plain C function pointers with no context argument, so the process
// holds exactly one frontend's worth of state no matter how the ObjC
// surface is shaped. The singleton above is the honest interface to that.
namespace {

const LibretroCoreAPI *gCore = nullptr;
LibretroCoreID gCoreID = LibretroCoreIDFBNeo;
bool gInitialized = false;
bool gGameLoaded = false;

std::string gSystemDirectory;
std::string gSaveDirectory;
LibretroPixelFormat gPixelFormat = LibretroPixelFormatXRGB8888;

std::mutex gFrameMutex;
std::vector<uint8_t> gFrameBytes;
uint32_t gFrameWidth = 0;
uint32_t gFrameHeight = 0;
uint32_t gFrameBytesPerRow = 0;
bool gFrameDirty = false;

std::mutex gAudioMutex;
std::vector<int16_t> gAudioSamples; // interleaved stereo
double gAudioSampleRate = 44100.0;

// Core options for RETRO_ENVIRONMENT_GET_VARIABLE, keyed and valued as
// the core spells them. Read from the core's thread, written from the
// main thread before a load; copied under a lock to keep that honest.
std::mutex gOptionsMutex;
NSDictionary<NSString *, NSString *> *gOptions = nil;
// GET_VARIABLE hands out a borrowed pointer, so the string it points into
// has to outlive the call; cores copy the value immediately by convention,
// but the buffer must at least survive until the next lookup.
std::string gLastVariableValue;

std::atomic<uint32_t> gButtonMask{0};
std::atomic<uint32_t> gRotation{0};

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

void inputPoll(void) {}

int16_t inputState(unsigned port, unsigned device, unsigned, unsigned id) {
    if (port != 0 || device != RETRO_DEVICE_JOYPAD || id > 13) {
        return 0;
    }
    return (gButtonMask.load(std::memory_order_relaxed) >> id) & 1;
}

void logCallback(enum retro_log_level level, const char *fmt, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);
    static const char *names[] = {"debug", "info", "warn", "error"};
    unsigned idx = level <= RETRO_LOG_ERROR ? level : RETRO_LOG_ERROR;
    NSLog(@"[core %s] %s", names[idx], buffer);
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
            gPixelFormat = (LibretroPixelFormat)*(const enum retro_pixel_format *)data;
            return true;
        case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
            return true;
        case RETRO_ENVIRONMENT_SET_ROTATION:
            // Vertical (TATE) boards render sideways in the framebuffer
            // and ask the frontend to rotate the picture. Value is in
            // 90-degree counter-clockwise steps.
            gRotation.store(*(const unsigned *)data, std::memory_order_relaxed);
            return true;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            ((struct retro_log_callback *)data)->log = logCallback;
            return true;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            auto *variable = (struct retro_variable *)data;
            if (!variable || !variable->key) {
                return false;
            }
            std::lock_guard<std::mutex> lock(gOptionsMutex);
            NSString *value = gOptions[[NSString stringWithUTF8String:variable->key]];
            if (!value) {
                variable->value = nullptr;
                return false; // core falls back to its own default
            }
            gLastVariableValue = value.UTF8String;
            variable->value = gLastVariableValue.c_str();
            return true;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            // Options only change between loads, never mid-game.
            *(bool *)data = false;
            return true;
        default:
            return false;
    }
}

// The one place a core id becomes a function table. Adding a core means
// one wiring file and one line here.
const LibretroCoreAPI *coreAPI(LibretroCoreID coreID) {
    switch (coreID) {
        case LibretroCoreIDFBNeo:
            return FBNeoCoreAPI();
        case LibretroCoreIDBeetleSaturn:
            return BeetleSaturnCoreAPI();
    }
    return FBNeoCoreAPI();
}

} // namespace

@implementation LibretroFrontend

+ (LibretroFrontend *)shared {
    static LibretroFrontend *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[LibretroFrontend alloc] init]; });
    return instance;
}

- (uint32_t)apiVersionForCore:(LibretroCoreID)coreID {
    return coreAPI(coreID)->api_version();
}

- (void)activateCore:(LibretroCoreID)coreID {
    if (gCore && gCoreID == coreID) {
        return;
    }
    if (gCore && gInitialized) {
        // A different core was live: give it the full shutdown it expects
        // before its callbacks stop meaning anything.
        if (gGameLoaded) {
            gCore->unload_game();
        }
        gCore->deinit();
    }
    gCore = coreAPI(coreID);
    gCoreID = coreID;
    gInitialized = false;
    gGameLoaded = false;
    {
        std::lock_guard<std::mutex> lock(gFrameMutex);
        gFrameBytes.clear();
        gFrameDirty = false;
    }
    {
        std::lock_guard<std::mutex> lock(gAudioMutex);
        gAudioSamples.clear();
    }
    gButtonMask.store(0, std::memory_order_relaxed);
    gRotation.store(0, std::memory_order_relaxed);
}

- (void)setCoreOptions:(NSDictionary<NSString *, NSString *> *)options {
    std::lock_guard<std::mutex> lock(gOptionsMutex);
    gOptions = [options copy];
}

- (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory {
    if (!gCore) {
        gCore = coreAPI(gCoreID);
    }
    gSystemDirectory = systemDirectory.fileSystemRepresentation;
    gSaveDirectory = systemDirectory.fileSystemRepresentation;

    if (!gInitialized) {
        gCore->set_environment(environmentCallback);
        gCore->init();
        gCore->set_video_refresh(videoRefresh);
        gCore->set_audio_sample(audioSample);
        gCore->set_audio_sample_batch(audioSampleBatch);
        gCore->set_input_poll(inputPoll);
        gCore->set_input_state(inputState);
        gInitialized = true;
    }

    struct retro_game_info info = {};
    std::string path = romPath.fileSystemRepresentation;
    info.path = path.c_str();
    info.data = nullptr;
    info.size = 0;
    info.meta = nullptr;

    if (!gCore->load_game(&info)) {
        return @"retro_load_game returned false, the core rejected the ROM or couldn't find its BIOS";
    }
    gGameLoaded = true;

    struct retro_system_av_info avInfo = {};
    gCore->get_system_av_info(&avInfo);
    {
        std::lock_guard<std::mutex> lock(gAudioMutex);
        gAudioSampleRate = avInfo.timing.sample_rate > 0 ? avInfo.timing.sample_rate : 44100.0;
    }

    return nil;
}

- (void)runFrame {
    if (gInitialized && gGameLoaded) {
        gCore->run();
    }
}

- (nullable LibretroFrame *)latestFrame {
    std::lock_guard<std::mutex> lock(gFrameMutex);
    if (!gFrameDirty || gFrameBytes.empty()) {
        return nil;
    }
    NSData *pixels = [NSData dataWithBytes:gFrameBytes.data() length:gFrameBytes.size()];
    gFrameDirty = false;
    return [[LibretroFrame alloc] initWithPixels:pixels
                                           width:gFrameWidth
                                          height:gFrameHeight
                                     bytesPerRow:gFrameBytesPerRow
                                     pixelFormat:gPixelFormat];
}

- (nullable NSData *)drainAudio {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    if (gAudioSamples.empty()) {
        return nil;
    }
    NSData *data = [NSData dataWithBytes:gAudioSamples.data() length:gAudioSamples.size() * sizeof(int16_t)];
    gAudioSamples.clear();
    return data;
}

- (double)audioSampleRate {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    return gAudioSampleRate;
}

- (void)setButtonMask:(uint32_t)mask {
    gButtonMask.store(mask, std::memory_order_relaxed);
}

- (uint32_t)rotation {
    return gRotation.load(std::memory_order_relaxed);
}

- (nullable NSData *)serializeState {
    if (!gInitialized || !gGameLoaded) {
        return nil;
    }
    size_t size = gCore->serialize_size();
    if (size == 0) {
        return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!gCore->serialize(data.mutableBytes, size)) {
        return nil;
    }
    return data;
}

- (BOOL)unserializeState:(NSData *)state {
    if (!gInitialized || !gGameLoaded || state.length == 0) {
        return NO;
    }
    return gCore->unserialize(state.bytes, state.length);
}

@end
