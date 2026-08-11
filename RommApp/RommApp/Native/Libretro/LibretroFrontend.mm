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
#import "FlycastCore.h"
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#include <dlfcn.h>
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

// Flycast go/no-go spike: the only core here with no software renderer at
// all, so it needs a real GLES context via libretro's hardware-render
// interface instead of the plain memory-buffer path every other core
// uses. Kept file-static like the rest of this frontend's state, one
// core active at a time.
EAGLContext *gGLContext = nil;
struct retro_hw_render_callback gHWRender = {};
bool gUsesHWRender = false;
GLuint gFBO = 0;
GLuint gColorTexture = 0;
GLuint gDepthRenderbuffer = 0;
GLuint gFBOWidth = 0;
GLuint gFBOHeight = 0;
// Surfaced through -hwRenderDiagnostics for the Dreamcast spike UI, since
// there is no easy console log access from a real device without Xcode
// attached: cheaper to make the pipeline state visible in-app than to
// guess at it from behavior alone (e.g. "audio plays, screen is black"
// is consistent with several different failure points).
std::string gHWDiagnostic = "not requested";
// Setup (FBO creation, context_reset) happens once at load and would
// otherwise get overwritten by the per-frame readback diagnostic within
// a second, hiding exactly the information most useful for a first-boot
// failure. Kept separate and shown alongside it instead.
std::string gHWSetupDiagnostic;
std::atomic<uint32_t> gHWFrameCount{0};
// Debug-only: whether the core ever actually asked for
// reicast_threaded_rendering via GET_VARIABLE, distinguishing "we sent an
// override the core never read" from "the override was read and had no
// effect". Some cores skip GET_VARIABLE entirely for a key the frontend
// never acknowledged registering (SET_VARIABLES/SET_CORE_OPTIONS, which
// this frontend's environmentCallback does not answer), silently keeping
// their own hardcoded default regardless of what gOptions holds.
std::atomic<bool> gThreadedRenderingQueried{false};

uintptr_t hwGetCurrentFramebuffer(void) {
    return gFBO;
}

// Standard GL entry points are already linked straight into this binary
// via OpenGLES.framework, so a plain dlsym against the running process
// resolves them; no dynamic loader indirection needed the way EGL/GLX
// platforms require.
retro_proc_address_t hwGetProcAddress(const char *sym) {
    return (retro_proc_address_t)dlsym(RTLD_DEFAULT, sym);
}

// (Re)builds the offscreen FBO Flycast renders into, sized to the core's
// reported geometry. Color attachment is a real GL_TEXTURE_2D, not a
// renderbuffer: matched to Provenance's own shipping thin libretro
// frontend (PVThinLibretroFrontend.mm's setupHardwareContextFBOWidth:),
// the one concrete, currently-working reference available for this exact
// core. A renderbuffer-backed color attachment is a legal FBO per spec,
// but every fix that assumed the two FBOs' formats and sizes matching
// convention was "close enough" failed identically on real hardware, and
// this is the one structural difference from a proven-working
// implementation rather than another guess at GL state.
void setupHWFramebuffer(GLuint width, GLuint height) {
    if (gFBO != 0 && gFBOWidth == width && gFBOHeight == height) {
        return;
    }
    if (gFBO != 0) {
        glDeleteFramebuffers(1, &gFBO);
        gFBO = 0;
    }
    if (gColorTexture != 0) {
        glDeleteTextures(1, &gColorTexture);
        gColorTexture = 0;
    }
    if (gDepthRenderbuffer != 0) {
        glDeleteRenderbuffers(1, &gDepthRenderbuffer);
        gDepthRenderbuffer = 0;
    }

    glGenFramebuffers(1, &gFBO);
    glBindFramebuffer(GL_FRAMEBUFFER, gFBO);

    glGenTextures(1, &gColorTexture);
    glBindTexture(GL_TEXTURE_2D, gColorTexture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gColorTexture, 0);

    if (gHWRender.depth || gHWRender.stencil) {
        glGenRenderbuffers(1, &gDepthRenderbuffer);
        glBindRenderbuffer(GL_RENDERBUFFER, gDepthRenderbuffer);
        GLenum format = gHWRender.stencil ? GL_DEPTH24_STENCIL8 : GL_DEPTH_COMPONENT24;
        glRenderbufferStorage(GL_RENDERBUFFER, format, width, height);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, gDepthRenderbuffer);
        if (gHWRender.stencil) {
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, gDepthRenderbuffer);
        }
    }

    gFBOWidth = width;
    gFBOHeight = height;

    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    char buf[128];
    snprintf(buf, sizeof(buf), "FBO %ux%u status=0x%04X (%s)", width, height, status,
              status == GL_FRAMEBUFFER_COMPLETE ? "complete" : "INCOMPLETE");
    gHWSetupDiagnostic = buf;
}

void videoRefresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        // The frame is already sitting in gFBO on the GPU; read it back
        // once as BGRA (matching this frontend's existing XRGB8888 byte
        // layout, so the Metal display path needs no separate case for
        // it) instead of one glReadPixels call per row. GL's framebuffer
        // origin is bottom-left, everything else here assumes top-left,
        // so the row order is reversed on the way into gFrameBytes.
        if (!gGLContext || width == 0 || height == 0) {
            return;
        }
        std::lock_guard<std::mutex> lock(gFrameMutex);
        size_t bytesPerRow = (size_t)width * 4;
        size_t needed = bytesPerRow * height;
        if (gFrameBytes.size() != needed) {
            gFrameBytes.resize(needed);
        }
        // Drained before touching GL ourselves: glGetError returns and
        // clears one error at a time in the order they occurred, so a
        // single call after our own readback can actually be reporting
        // something Flycast's own draw calls left pending earlier in this
        // same frame, not a fault in the readback itself. Separating the
        // two was needed after the GL_INVALID_OPERATION seen here turned
        // out to survive fixing the actual readback bug (GL_BGRA_EXT was
        // not a valid glReadPixels format/type pair on this hardware).
        GLenum preExistingErr = GL_NO_ERROR;
        GLenum e;
        while ((e = glGetError()) != GL_NO_ERROR) {
            preExistingErr = e;
        }

        // GL_RGBA/GL_UNSIGNED_BYTE, not GL_BGRA_EXT: not a guaranteed-
        // valid glReadPixels format/type pair on every GLES3
        // implementation. R/B is swapped by hand below instead, since
        // RGBA/UNSIGNED_BYTE is the one combination every implementation
        // is required to accept.
        std::vector<uint8_t> flipped(needed);
        glBindFramebuffer(GL_FRAMEBUFFER, gFBO);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, flipped.data());
        GLenum readbackErr = glGetError();
        for (unsigned y = 0; y < height; y++) {
            const uint8_t *srcRow = flipped.data() + (height - 1 - y) * bytesPerRow;
            uint8_t *dstRow = gFrameBytes.data() + y * bytesPerRow;
            for (unsigned x = 0; x < width; x++) {
                dstRow[x * 4 + 0] = srcRow[x * 4 + 2]; // B
                dstRow[x * 4 + 1] = srcRow[x * 4 + 1]; // G
                dstRow[x * 4 + 2] = srcRow[x * 4 + 0]; // R
                dstRow[x * 4 + 3] = srcRow[x * 4 + 3]; // A
            }
        }
        gFrameWidth = width;
        gFrameHeight = height;
        gFrameBytesPerRow = (uint32_t)bytesPerRow;
        gPixelFormat = LibretroPixelFormatXRGB8888;
        gFrameDirty = true;

        uint32_t frameCount = gHWFrameCount.fetch_add(1, std::memory_order_relaxed) + 1;
        if (frameCount <= 3 || frameCount % 300 == 0) {
            // Every byte, not a sparse sample: a mostly-black scene with
            // a few real accent pixels (a HUD element, a loading spinner)
            // would pass a sampled "is any byte non-zero" check while
            // still looking solid black on screen, which is exactly the
            // ambiguity that made the first version of this diagnostic
            // less useful than it looked.
            uint32_t nonZeroBytes = 0;
            uint8_t maxByte = 0;
            for (uint8_t b : flipped) {
                if (b != 0) {
                    nonZeroBytes++;
                    if (b > maxByte) maxByte = b;
                }
            }
            char buf[224];
            snprintf(buf, sizeof(buf),
                      "read %ux%u frame #%u, %u/%zu bytes non-zero (max=%u), "
                      "preErr=0x%04X readbackErr=0x%04X",
                      width, height, frameCount, nonZeroBytes, flipped.size(), maxByte,
                      preExistingErr, readbackErr);
            gHWDiagnostic = buf;
        }
        return;
    }
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
            if (!strcmp(variable->key, "reicast_threaded_rendering")) {
                gThreadedRenderingQueried.store(true, std::memory_order_relaxed);
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
        case RETRO_ENVIRONMENT_SET_HW_RENDER: {
            // Flycast go/no-go spike: only GLES is supported here, nothing
            // else in this frontend has ever needed a GPU context. The
            // actual EAGLContext/FBO are created after load_game succeeds,
            // once the core's geometry is known; this only records what
            // the core asked for and hands back the two callbacks it needs.
            auto *hw = (struct retro_hw_render_callback *)data;
            if (!hw) {
                return false;
            }
            if (hw->context_type != RETRO_HW_CONTEXT_OPENGLES2 &&
                hw->context_type != RETRO_HW_CONTEXT_OPENGLES3) {
                return false;
            }
            hw->get_current_framebuffer = hwGetCurrentFramebuffer;
            hw->get_proc_address = hwGetProcAddress;
            gHWRender = *hw;
            gUsesHWRender = true;
            gHWDiagnostic = hw->context_type == RETRO_HW_CONTEXT_OPENGLES3
                ? "requested GLES3, context not yet created" : "requested GLES2, context not yet created";
            return true;
        }
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
        case LibretroCoreIDFlycast:
            return FlycastCoreAPI();
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
    gUsesHWRender = false;
    gHWRender = {};
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

    if (gUsesHWRender) {
        // base_width/base_height, not max_width/max_height: Flycast
        // renders into its own internal target sized to the actual frame
        // and composites into this externally-provided FBO every frame
        // via glBlitFramebuffer (PostProcessor::render in postprocess.cpp).
        // Sizing ours to the core's inflated maximum (853x853 here, versus
        // an actual 640x480 frame) made every one of those blits a
        // mismatched-size blit between two differently-sized FBOs, which
        // GLES3 drivers can validate more strictly than desktop GL and
        // reject outright; that produced a GL_INVALID_OPERATION on every
        // single frame on real hardware. A too-small FBO would silently
        // clip, but this core's own max is far larger than anything it
        // actually renders at, so matching its real per-frame geometry is
        // the correct size here regardless.
        GLuint width = avInfo.geometry.base_width;
        GLuint height = avInfo.geometry.base_height;
        if (width == 0) width = 640;
        if (height == 0) height = 480;

        // Always try GLES3 first, regardless of what context_type the
        // core actually requested: found on real hardware that Flycast
        // asks for GLES2 here, not because its own code needs GLES2, but
        // because libretro-common's GLSM hardcodes RETRO_HW_CONTEXT_
        // OPENGLES2 on iOS whenever HAVE_OPENGLES is defined, regardless
        // of the core's own HAVE_OPENGLES3 build flags. Flycast's actual
        // shaders use GLES3-only syntax (in/out, texture()), and it does
        // its own runtime capability detection via glGetString(GL_VERSION)
        // rather than trusting the requested context_type, so creating a
        // real GLES3 context here (when the device supports it) makes
        // Flycast correctly detect and use the GLES3 path its own
        // compiled code actually needs. A GLES2-only device would need
        // the fallback; every real device this app targets supports GLES3.
        EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES3;
        if (!gGLContext || gGLContext.API != api) {
            gGLContext = [[EAGLContext alloc] initWithAPI:api];
        }
        [EAGLContext setCurrentContext:gGLContext];
        setupHWFramebuffer(width, height);
        char resetBuf[64];
        if (gHWRender.context_reset) {
            gHWRender.context_reset();
            GLenum err = glGetError();
            snprintf(resetBuf, sizeof(resetBuf), ", context_reset called, glError=0x%04X", err);
        } else {
            snprintf(resetBuf, sizeof(resetBuf), ", core set no context_reset callback");
        }
        gHWSetupDiagnostic += resetBuf;
    }

    return nil;
}

- (void)runFrame {
    if (gInitialized && gGameLoaded) {
        if (gUsesHWRender && gGLContext) {
            // Nothing else in this app touches GLES, so this should
            // already be current, but making it current is cheap and
            // guards against something else on this thread having
            // changed it between frames.
            [EAGLContext setCurrentContext:gGLContext];
            // Flycast is built against libretro-common's GLSM ("GL State
            // Machine"), which normally sits between a full frontend like
            // RetroArch and the core, replaying a handful of GL defaults
            // fresh at the top of every retro_run before the core's own
            // drawing runs. A bare frontend like this one gets none of
            // that for free and has to set the same defaults by hand:
            // Provenance's own thin libretro frontend documents exactly
            // this same gap (PVThinLibretroFrontend.mm) for the same
            // reason, GLideN64 silently rendering solid-color fills
            // without it. GL_UNPACK_ALIGNMENT defaults to 4; Dreamcast's
            // PVR texture formats commonly upload rows that aren't a
            // multiple of 4 bytes, which some GL drivers reject outright
            // rather than silently reinterpreting.
            glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
            glBindFramebuffer(GL_FRAMEBUFFER, gFBO);
            glViewport(0, 0, gFBOWidth, gFBOHeight);
        }
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

- (nullable NSString *)hwRenderDiagnostics {
    if (!gUsesHWRender) {
        return nil;
    }
    std::string combined = gHWSetupDiagnostic + "\n" + gHWDiagnostic + "\nthreadedRenderingQueried="
        + (gThreadedRenderingQueried.load(std::memory_order_relaxed) ? "yes" : "NO");
    return [NSString stringWithUTF8String:combined.c_str()];
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
