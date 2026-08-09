#import "LibretroFrontend.h"
#include "LibretroCoreAPI.h"
#import "FBNeoCore.h"
#import "SaturnCore.h"
#import "GambatteCore.h"
#import "MGBACore.h"
#import "GenesisPlusGXCore.h"
#import "BeetlePCEFastCore.h"
#import "Snes9xCore.h"
#import "FCEUmmCore.h"
#import "BeetleNGPCore.h"
#import "ProSystemCore.h"
#import "PicoDriveCore.h"
#import "PCSXReARMedCore.h"
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
unsigned gPortDevice = 0;
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

// The core's own reported display aspect ratio, captured once at load
// alongside the sample rate. 0 means the core left it unset, libretro's
// documented signal to fall back to raw pixel width/height, which is
// what every caller already did before this existed. Arcade boards are
// square-pixel, so raw pixels and this always agreed and nobody noticed
// the frontend never read it; Saturn commonly is not.
std::atomic<double> gAspectRatio{0.0};

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

int16_t inputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port != 0) {
        return 0;
    }
    uint32_t mask = gButtonMask.load(std::memory_order_relaxed);
    if (device == RETRO_DEVICE_JOYPAD) {
        return id <= 13 ? (mask >> id) & 1 : 0;
    }
    // A twin-stick arcade game's second joystick. FBNeo reads it as the
    // analog right stick (confirmed against its own retro_input.cpp)
    // even though the real cabinet's control is a plain 4-way joystick,
    // not a true analog one: digital in, full deflection out, bits
    // 20 (right) / 21 (left) / 22 (down) / 23 (up) in the same mask the
    // ordinary joypad buttons live in. Y-positive is down, matching
    // libretro's own convention and confirmed against the touch pad's
    // identical stick, which already relies on it.
    if (device == RETRO_DEVICE_ANALOG && index == RETRO_DEVICE_INDEX_ANALOG_RIGHT) {
        if (id == RETRO_DEVICE_ID_ANALOG_X) {
            if ((mask >> 20) & 1) return 0x7fff;
            if ((mask >> 21) & 1) return -0x7fff;
        } else if (id == RETRO_DEVICE_ID_ANALOG_Y) {
            if ((mask >> 22) & 1) return 0x7fff;
            if ((mask >> 23) & 1) return -0x7fff;
        }
    }
    return 0;
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
        case RETRO_ENVIRONMENT_GET_CAN_DUPE:
            // videoRefresh already treats a null data pointer as "same as
            // last frame, nothing changed" and skips the copy, exactly
            // what this flag promises; it was just never actually
            // advertised. Gambatte is the one core so far that refuses
            // to load at all without an explicit yes here ("[Gambatte]
            // Cannot dupe frames!", found 2026-08-08 on a real device,
            // a valid, correctly-extracted ROM rejected outright).
            *(bool *)data = true;
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
        case LibretroCoreIDGambatte:
            return GambatteCoreAPI();
        case LibretroCoreIDMGBA:
            return MGBACoreAPI();
        case LibretroCoreIDGenesisPlusGX:
            return GenesisPlusGXCoreAPI();
        case LibretroCoreIDBeetlePCEFast:
            return BeetlePCEFastCoreAPI();
        case LibretroCoreIDSnes9x:
            return Snes9xCoreAPI();
        case LibretroCoreIDFCEUmm:
            return FCEUmmCoreAPI();
        case LibretroCoreIDBeetleNGP:
            return BeetleNGPCoreAPI();
        case LibretroCoreIDProSystem:
            return ProSystemCoreAPI();
        case LibretroCoreIDPicoDrive:
            return PicoDriveCoreAPI();
        case LibretroCoreIDPCSXReARMed:
            return PCSXReARMedCoreAPI();
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

- (void)setControllerPortDevice:(unsigned)device {
    gPortDevice = device;
}

- (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory {
    if (!gCore) {
        gCore = coreAPI(gCoreID);
    }
    gSystemDirectory = systemDirectory.fileSystemRepresentation;
    gSaveDirectory = systemDirectory.fileSystemRepresentation;

    // A second game on the same already-active core skipped all of this
    // entirely: `activateCore:` only tears a core down when switching to
    // a different one, never when staying on the same one for a second
    // game, so `loadGame:` itself has to enforce it. A plain
    // retro_unload_game before the new retro_load_game (what this used
    // to do) was enough to stop Genesis Plus GX corrupting memory across
    // games (a real EXC_BAD_ACCESS in blip_delete, found 2026-08-08 from
    // a crash log), but Beetle PCE Fast needs more: it loads correctly
    // as the first game a process ever runs and then fails every game
    // after, unload included, confirmed on a real device by loading the
    // exact same game alone in a fresh process versus second in a
    // session. Not every core's internal state resets cleanly from
    // unload_game alone, so a full deinit before the fresh init below is
    // the one guarantee that holds for all of them: this is exactly the
    // teardown a core switch already gets, just now applied every time,
    // not only when the core itself changes.
    if (gInitialized && gGameLoaded) {
        gCore->unload_game();
        gCore->deinit();
        gInitialized = false;
    }
    gGameLoaded = false;

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

    // Reset to libretro's own documented default (0RGB1555) before this
    // load, not left however the last core's SET_PIXEL_FORMAT call (or
    // lack of one) happened to leave it. FBNeo and Saturn both request
    // XRGB8888 explicitly, which is why `gPixelFormat`'s own initial
    // value matched them by coincidence and nobody noticed this was
    // missing. Genesis Plus GX never calls SET_PIXEL_FORMAT at all in
    // this build (FRONTEND_SUPPORTS_RGB565 isn't defined, so it always
    // stays on the spec default), so without this reset its real
    // 16-bit-per-pixel frames get read as 32-bit XRGB8888 leftover from
    // whatever ran before it, wrong stride, wrong byte count, silently:
    // no crash, just a black screen. Found 2026-08-08 the same way as
    // the audio crash, a real device test with correct controls and
    // input but nothing on screen.
    gPixelFormat = LibretroPixelFormatRGB1555;

    struct retro_game_info info = {};
    std::string path = romPath.fileSystemRepresentation;
    info.path = path.c_str();
    info.data = nullptr;
    info.size = 0;
    info.meta = nullptr;

    // FBNeo and Beetle Saturn, the only two cores this frontend carried
    // until this session, both read the ROM themselves given a path
    // (need_fullpath true in their own retro_get_system_info), so a
    // path-only retro_game_info was never wrong, just accidentally
    // narrow. Several of the cores added alongside them, Gambatte, mGBA,
    // Snes9x and ProSystem confirmed by reading each core's own
    // retro_get_system_info, report need_fullpath false: they expect the
    // frontend to have already read the file and handed over the bytes,
    // and reject anything with a null data pointer outright. Found
    // 2026-08-08 from "the core rejected the ROM" on every one of them.
    // std::vector, not NSData: its buffer must outlive this call but
    // needs no cleanup after, load_game copies out whatever it keeps.
    std::vector<uint8_t> fileBytes;
    struct retro_system_info sysInfo = {};
    gCore->get_system_info(&sysInfo);
    if (!sysInfo.need_fullpath) {
        NSData *data = [NSData dataWithContentsOfFile:romPath];
        if (!data) {
            return @"Couldn't read the ROM file from disk";
        }
        fileBytes.assign((const uint8_t *)data.bytes, (const uint8_t *)data.bytes + data.length);
        info.data = fileBytes.data();
        info.size = fileBytes.size();
    }

    if (!gCore->load_game(&info)) {
        return @"retro_load_game returned false, the core rejected the ROM or couldn't find its BIOS";
    }
    gGameLoaded = true;

    if (gPortDevice != 0) {
        gCore->set_controller_port_device(0, gPortDevice);
    }

    struct retro_system_av_info avInfo = {};
    gCore->get_system_av_info(&avInfo);
    {
        std::lock_guard<std::mutex> lock(gAudioMutex);
        gAudioSampleRate = avInfo.timing.sample_rate > 0 ? avInfo.timing.sample_rate : 44100.0;
    }
    gAspectRatio.store(avInfo.geometry.aspect_ratio > 0 ? avInfo.geometry.aspect_ratio : 0.0,
                        std::memory_order_relaxed);

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

- (double)aspectRatio {
    return gAspectRatio.load(std::memory_order_relaxed);
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

- (nullable NSData *)saveRAM {
    if (!gInitialized || !gGameLoaded || !gCore->get_memory_data || !gCore->get_memory_size) {
        return nil;
    }
    void *bytes = gCore->get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = gCore->get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!bytes || size == 0) {
        return nil;
    }
    return [NSData dataWithBytes:bytes length:size];
}

- (BOOL)loadSaveRAM:(NSData *)data {
    if (!gInitialized || !gGameLoaded || !gCore->get_memory_data || !gCore->get_memory_size) {
        return NO;
    }
    void *bytes = gCore->get_memory_data(RETRO_MEMORY_SAVE_RAM);
    size_t size = gCore->get_memory_size(RETRO_MEMORY_SAVE_RAM);
    if (!bytes || size == 0 || data.length != size) {
        return NO;
    }
    memcpy(bytes, data.bytes, size);
    return YES;
}

@end
