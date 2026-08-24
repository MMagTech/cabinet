#import "LibretroFrontend.h"
#include "LibretroCoreAPI.h"
// The fourteen per-core static libraries are built for real tvOS/iOS
// hardware (arm64-apple-tvos), not for a simulator, and rebuilding
// emulator cores for a simulator target buys nothing: performance there
// is meaningless and the cores would still be a separate set of
// artefacts to keep in sync. So a simulator build deliberately carries no
// cores at all and exists purely for UI work, which is most of what
// anyone iterates on anyway. Everything above this line, the frontend
// itself, still compiles, so nothing else in the app needs to know.
#if !TARGET_OS_SIMULATOR
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
#import "VecxCore.h"
#import "Stella2014Core.h"
#import "OperaCore.h"
#import "BeetleVBCore.h"
#import "MelonDSCore.h"
#import "PicoDriveCore.h"
#import "PCSXReARMedCore.h"
#import "N64Core.h"
#import "FlycastCore.h"
#import "MAME2003PlusCore.h"
#import "PPSSPPCore.h"
#endif

#import <UIKit/UIKit.h>
// CABINET_ANGLE (test builds): GLES comes from ANGLE's Metal backend
// instead of Apple's deprecated OpenGLES stack. Same GLES3 dialect, so
// every gl* call in this file compiles against either. The context is
// EGL (a tiny offscreen pbuffer; all real rendering goes into gFBO), and
// proc addresses come from eglGetProcAddress. Measured motive: ANGLE's
// glReadPixels ran 0.7-1.2ms on the Mac lab where Apple's GLES floors at
// 4.4ms on this hardware; this build exists to take that measurement on
// the device itself.
#ifdef CABINET_ANGLE
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#else
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#endif
#include <dlfcn.h>
#include <string>
#include <vector>
#include <mutex>
#include <atomic>
#include <chrono>
#include <set>
#include <unordered_map>
#include <algorithm>
#include <algorithm>
#include <cstdarg>
#include <cstdio>

@implementation LibretroFrame
- (instancetype)initWithPixels:(NSData *)pixels width:(uint32_t)width height:(uint32_t)height bytesPerRow:(uint32_t)bytesPerRow pixelFormat:(LibretroPixelFormat)pixelFormat flippedVertically:(BOOL)flippedVertically {
    if ((self = [super init])) {
        _pixels = pixels;
        _width = width;
        _height = height;
        _bytesPerRow = bytesPerRow;
        _pixelFormat = pixelFormat;
        _flippedVertically = flippedVertically;
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
// Sized below kMaxPorts's own declaration, near gButtonMask, since both
// share the same port-count constant; declared here because they're set
// well before that point in the file and used at loadGame: time.
unsigned gPortDevice[2] = {0, 0};
bool gPortDeviceSet[2] = {false, false};
bool gInitialized = false;
// Whether the CURRENT core is initialized is `gInitialized`; this is the
// same fact for every core, which is only interesting for the cores
// `coreToleratesDeinit` refuses to tear down. Those stay initialized
// after their game unloads, so switching away and back must NOT run a
// second retro_init on them: that is exactly the sequence that made
// Flycast reserve fresh address space it never mapped anything into.
std::set<LibretroCoreID> gInitializedCores;
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
// Set only by the hardware-render readback, cleared by every other path,
// so a core switch or a software-rendered game can never inherit it. See
// LibretroFrame.flippedVertically for why the flip moved off the CPU.
bool gFrameFlipped = false;

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
// The core's own declared frame rate; see where it is read in loadGame.
std::atomic<double> gTargetFPS{60.0};

// Core options for RETRO_ENVIRONMENT_GET_VARIABLE, keyed and valued as
// the core spells them. Read from the core's thread, written from the
// main thread before a load; copied under a lock to keep that honest.
std::mutex gOptionsMutex;
NSDictionary<NSString *, NSString *> *gOptions = nil;
// Raised only by updateCoreOptions, consumed once by the next
// GET_VARIABLE_UPDATE answer. Every core polls that call; every core
// but melonDS sees a flag nothing ever raises, so their answer stays
// the constant false it has always been.
std::atomic<bool> gOptionsDirty{false};
// GET_VARIABLE hands out a borrowed pointer with no lifetime stated in
// libretro.h, and nothing stops a core from keeping it across calls. So
// answered values are interned in a set that only ever grows: a pointer
// handed out once stays valid for the life of the process, rather than
// being overwritten by the next lookup the way a single shared buffer
// would be. The pool stays tiny, one entry per distinct option value.
//
// Rumble: a core can call set_rumble_state every frame while an effect
// holds, not just on the transition, so this only fires a haptic on the
// actual off-to-on edge per (port, effect), the same "the motor turns on
// once" behaviour real hardware has, not a per-frame buzz. Gated by the
// same Settings toggle key SettingsView reads, checked fresh on every
// call rather than cached, since the player can flip it mid-game.
std::mutex gRumbleMutex;
bool gRumbleWasOn[4][2] = {}; // [port][RETRO_RUMBLE_STRONG/WEAK]
// Set by +[LibretroFrontend setRumbleHandler:], routed to
// GameControllerManager.fireRumble at launch. Nil until RommApp.swift
// wires it, which is why rumbleSetState below still carries its own
// direct UIImpactFeedbackGenerator fallback for that brief window.
static void (^gRumbleHandler)(NSInteger port, BOOL strong, uint16_t strength) = nil;
std::set<std::string> gVariableValuePool; // guarded by gOptionsMutex

// Two ports, one per local player. Each port owns its whole input state
// rather than sharing bits of one word: FBNeo's twin-stick digitizing
// (bits 20-23 below) belongs to player 1's second joystick, and folding a
// second player into spare bits of the same mask would alias directly
// onto it. Shaped like gRumbleWasOn, which was already port-indexed.
constexpr size_t kMaxPorts = 2;
std::atomic<uint32_t> gButtonMask[kMaxPorts];
std::atomic<uint32_t> gRotation{0};
// Dreamcast's left analog stick, -1 to 1, the only continuous (not
// digital-in-full-deflection-out) input any core here reads. See
// -setAnalogStickX:y: and inputState's RETRO_DEVICE_INDEX_ANALOG_LEFT
// case.
std::atomic<float> gAnalogLeftX[kMaxPorts];
std::atomic<float> gAnalogLeftY[kMaxPorts];
// Relative pointing devices: dials, spinners and trackballs arrive from
// the cores' side as RETRO_DEVICE_MOUSE deltas. The UI accumulates
// counts here; the poll callback latches them so every read inside one
// frame sees the same value, and a frame with no input reads zero.
// Nothing feeds these except the analog touch controls, so every core
// that does not ask, and every game without such a control, is exactly
// where it was when these did not exist.
std::atomic<int32_t> gMouseAccumX[kMaxPorts];
std::atomic<int32_t> gMouseAccumY[kMaxPorts];
int16_t gMouseLatchedX[kMaxPorts];
int16_t gMouseLatchedY[kMaxPorts];
// Absolute pointing: a touch on the game's own picture, which is what a
// lightgun means on a touchscreen. -0x7fff..0x7fff in libretro's
// convention, pressed while the finger is down.
std::atomic<int16_t> gPointerX[kMaxPorts];
std::atomic<int16_t> gPointerY[kMaxPorts];
std::atomic<bool> gPointerDown[kMaxPorts];
std::atomic<bool> gGunOffscreen[kMaxPorts];
// TEST BUILD, with cabinetInputTrace below: samples-per-frame and last
// value of the core's own analog-X reads on port 0.
std::atomic<uint32_t> gAnalogReads{0};
std::atomic<float> gAnalogLastRead{0};
// Defined in the Flycast core (Renderer_if.cpp in the spikes tree),
// written at every render-queue enqueue. Resolved at runtime with dlsym
// rather than linked, so an app paired with a Flycast archive that
// predates the symbol (the iPhone's, currently) still builds and runs,
// it just traces -1.
static int cabinetQueueDepthNow(void) {
    static int *p = (int *)dlsym(RTLD_DEFAULT, "cabinetPvrQueueDepth");
    return p ? *p : -1;
}

// Cartridge sensors, for the Game Boy Advance carts that shipped with
// hardware inside them. Only mGBA asks for any of this; every other core
// here never calls the sensor interface at all.
//
// Not port-indexed like the pad state above, deliberately. These are the
// device's own motion, and there is exactly one phone no matter how many
// controllers are paired, so a second player's port has nothing of its
// own to report here.
std::atomic<float> gAccelerationX{0};
std::atomic<float> gAccelerationY{0};
std::atomic<float> gAccelerationZ{0};
std::atomic<float> gRotationRateZ{0};
// What the core has actually asked for. CoreMotion is not started until
// a core enables a sensor and is stopped again when it disables one,
// because leaving the gyroscope running for the thirteen cores that
// never ask would be a battery cost paid by every game to serve one.
std::atomic<bool> gAccelerometerEnabled{false};
std::atomic<bool> gGyroscopeEnabled{false};
static void (^gMotionSensingHandler)(BOOL wantsAccelerometer, BOOL wantsGyroscope) = nil;

// Flycast: the only core here with no software renderer at all, so it
// needs a real GLES context via libretro's hardware-render interface
// instead of the plain memory-buffer path every other core uses. Kept
// file-static like the rest of this frontend's state, one core active
// at a time.
#ifdef CABINET_ANGLE
EGLDisplay gEGLDisplay = EGL_NO_DISPLAY;
EGLContext gEGLContext = EGL_NO_CONTEXT;
EGLSurface gEGLSurface = EGL_NO_SURFACE;
// Non-nil sentinel so every `if (gGLContext)` guard in this file keeps
// meaning "the GL world exists" without rewriting each site.
void *gGLContext = nullptr;
static bool cabinetAngleMakeCurrent(void) {
    // The N64 rainbow-noise root cause (2026-08-19) is fixed inside the
    // ANGLE frameworks themselves: mtl_buffer_pool.mm stamps retiring
    // stream buffers with the open command buffer's serial so the pool
    // cannot recycle memory that recorded draws still reference. The
    // earlier env-var workaround (flushAfterStreamVertexData) is gone;
    // it cost 41 vs 58 fps on the Apple TV.
    if (gEGLDisplay == EGL_NO_DISPLAY) {
        gEGLDisplay = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        EGLint maj, min;
        if (!eglInitialize(gEGLDisplay, &maj, &min)) { gEGLDisplay = EGL_NO_DISPLAY; return false; }
        EGLint cfgAttrs[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RED_SIZE, 8,
                              EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
                              EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
                              EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_NONE };
        EGLConfig cfg; EGLint n;
        if (!eglChooseConfig(gEGLDisplay, cfgAttrs, &cfg, 1, &n) || n < 1) return false;
        EGLint pb[] = { EGL_WIDTH, 4, EGL_HEIGHT, 4, EGL_NONE };
        gEGLSurface = eglCreatePbufferSurface(gEGLDisplay, cfg, pb);
        EGLint ctxAttrs[] = { EGL_CONTEXT_CLIENT_VERSION, 3,
#if DEBUG
                              // Debug contexts carry validation cost; the
                              // KHR_debug microscope is a Debug-build tool.
                              0x30FC /*EGL_CONTEXT_OPENGL_DEBUG*/, EGL_TRUE,
#endif
                              EGL_NONE };
        gEGLContext = eglCreateContext(gEGLDisplay, cfg, EGL_NO_CONTEXT, ctxAttrs);
        if (gEGLContext == EGL_NO_CONTEXT) return false;
        gGLContext = (void *)1;
        // TEST BUILD: ANGLE's KHR_debug callback, appended to the same
        // diag file the frame stats go to. ANGLE's messages name the
        // exact call and reason, which is the microscope for the N64
        // texture artifacts. Rate-limited; errors and warnings only.
        eglMakeCurrent(gEGLDisplay, gEGLSurface, gEGLSurface, gEGLContext);
#if DEBUG
        typedef void (*DebugProc)(const void *callback, const void *userParam);
        DebugProc dbg = (DebugProc)eglGetProcAddress("glDebugMessageCallbackKHR");
        if (dbg) {
            static auto cb = [](unsigned source, unsigned type, unsigned id,
                                unsigned severity, int length, const char *message,
                                const void *userParam) {
                (void)source; (void)length; (void)userParam;
                if (severity == 0x826B /*NOTIFICATION*/) return;
                static int count = 0;
                if (count >= 80) return;
                count++;
                NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
                FILE *df = fopen([dir stringByAppendingPathComponent:@"hw-diag.txt"].fileSystemRepresentation, "a");
                if (df) { fprintf(df, "GLDBG type=0x%X sev=0x%X id=%u: %s\n", type, severity, id, message ?: "?"); fclose(df); }
            };
            typedef void (GL_APIENTRY *RealDebugProc)(void (GL_APIENTRY *)(unsigned, unsigned, unsigned, unsigned, int, const char *, const void *), const void *);
            ((RealDebugProc)dbg)([](unsigned a, unsigned b, unsigned c, unsigned d, int e, const char *f, const void *g) GL_APIENTRY { cb(a,b,c,d,e,f,g); }, nullptr);
            glEnable(0x92E0 /*GL_DEBUG_OUTPUT_KHR*/);
        }
#endif
        // ANGLE's own feature set, name and status, once per process.
        // The Mac lab renders this core correctly under the same ANGLE
        // and the same Metal translator, so whatever differs between
        // the two feature sets is the short list of suspects for a
        // corruption that only appears on the Apple mobile GPUs.
        {
            typedef unsigned (*QDA)(void *, int, intptr_t *);
            typedef const char *(*QSI)(void *, int, int);
            QDA qda = (QDA)eglGetProcAddress("eglQueryDisplayAttribANGLE");
            QSI qsi = (QSI)eglGetProcAddress("eglQueryStringiANGLE");
            NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            FILE *ff = fopen([dir stringByAppendingPathComponent:@"angle-features.txt"].fileSystemRepresentation, "w");
            if (qda && qsi && ff) {
                intptr_t n = 0;
                qda(gEGLDisplay, 0x3465 /*EGL_FEATURE_COUNT_ANGLE*/, &n);
                for (int i = 0; i < (int)n; i++)
                    fprintf(ff, "%s = %s\n", qsi(gEGLDisplay, 0x3460 /*NAME*/, i),
                            qsi(gEGLDisplay, 0x3464 /*STATUS*/, i));
            }
            if (ff) fclose(ff);
        }
    }
    return eglMakeCurrent(gEGLDisplay, gEGLSurface, gEGLSurface, gEGLContext);
}
#else
EAGLContext *gGLContext = nil;
#endif
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

// Per-stage timings for the hardware-render path, milliseconds, each
// holding the most recent single sample rather than an average: the trace
// that reads them (FrameTrace, NativePlayerRenderer.swift) wants raw
// per-frame numbers so a stall shows up as a stall instead of being
// smeared across its neighbours.
//
// Temporary instrumentation for issue #6: Dreamcast holds correct emulated
// speed and correct realtime audio while the picture updates about 20
// times a second, which says the SH4 is keeping up and something after it
// is not. This splits "after it" into its actual parts so the answer is
// measured rather than argued.
std::atomic<double> gTimeCoreRunMS{0};
std::atomic<double> gTimeReadbackMS{0};
std::atomic<double> gTimeSwizzleMS{0};

// Cumulative counters alongside them, same temporary purpose. These three
// together answer the question the timings alone cannot: audio frames
// against 44,100 a second says whether emulated time is advancing at
// realtime, which is the only direct read on whether the SH4 interpreter
// is keeping up; hardware frames says how often the core actually handed
// over a new picture; run calls says how often we asked. Cumulative rather
// than per-frame so no sample can be missed or double counted.
std::atomic<uint64_t> gAudioFramesTotal{0};
std::atomic<uint64_t> gRunCallTotal{0};
// Duplicate-frame reports from a hardware-rendered core. This is the one
// signal that says which mode Flycast is actually running in, without
// inferring it: its non-threaded path returns true from every
// Emulator::render, so is_dupe is always false and a dupe can never be
// reported. Any dupe at all means threaded rendering is genuinely on.
std::atomic<uint64_t> gHWDupeCount{0};

static double nowMS() {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

static void recordStage(std::atomic<double> &slot, double sample) {
    slot.store(sample, std::memory_order_relaxed);
}

// Whether a core survives retro_deinit followed by a fresh retro_init in
// the same process. Most do, and get the full teardown, which is the one
// guarantee that holds across cores whose internal state does not reset
// from retro_unload_game alone (Genesis Plus GX corrupting memory across
// games, Beetle PCE Fast failing every game after the first, both real
// device crashes 2026-08-08).
//
// Two cores must never be deinitialized, for unrelated reasons, and both
// were found the same way, as a crash on the second game of a session:
//
// - FBNeo: a second retro_deinit in one process (its own BurnLibExit)
//   hits a bad free and takes the app down. Found 2026-08-11.
// - Flycast: its retro_deinit calls addrspace::release() on Apple but
//   NOT emu.term() (shell/libretro/libretro.cpp, an #if that terms the
//   emulator on every other platform), so the Emulator stays in state
//   Init with its address space gone. The next retro_init reserves fresh
//   address space, but Emulator::init() returns early on any state that
//   is not Uninitialized, so mem_Init() never re-runs and nothing is
//   mapped into it. The next dc_reset's mem_Reset then writes to
//   unmapped memory: SIGSEGV, refused by Flycast's own fault handler
//   since it is not a watched page, and die("segfault"). Found
//   2026-08-16 from three device crash reports plus a debug-info build
//   pinning it to emulator.cpp:594.
//
// Both are safe to leave initialized: retro_unload_game already returns
// them to a state a fresh retro_load_game accepts, which is the ordinary
// libretro contract, and Flycast's reserved address space is virtual,
// not committed.
static bool coreToleratesDeinit(LibretroCoreID coreID) {
    return coreID != LibretroCoreIDFBNeo && coreID != LibretroCoreIDFlycast;
}

// Completes the hardware-render half of the libretro contract, which this
// frontend had only ever driven one way: context_reset at every load,
// context_destroy at none. That was survivable right up until the core was
// also torn down, and it is what made a second N64 game kill the app.
//
// The mechanism is one variable inside libretro-common's GLSM, the state
// machine mupen64plus renders through (libretro-common/glsm/glsm.c, its
// GLSM_CTL_STATE_CONTEXT_RESET case). GLSM tracks whether it currently
// holds a live context in `window_first`. On the first context_reset of a
// process that flag is zero, so it merely arms it and does nothing else.
// On every later one it is set, so GLSM calls retroChangeWindow(), which
// goes through dwnd().changeWindow() into GLideN64's teardown.
//
// Meanwhile retro_deinit had already taken mupen through ROM_CLOSE into
// GLideN64's RomClosed and DisplayWindow::stop(), which runs
// _destroyData() and then gfxContext.destroy(), leaving graphics::Context
// holding a null implementation pointer. So the next launch's
// context_reset drove a second teardown over an already-destroyed context:
// a null deref in TexrectDrawer::destroy, reached from deep inside GLSM.
//
// glsm_state_ctx_destroy's entire body is `window_first = 0`, and the
// frontend calling context_destroy is the only thing that ever reaches it.
// Cabinet was tearing the core down without telling GLSM, so GLSM went on
// believing the old context was current. Confirmed 2026-08-16 by a
// breadcrumb trace through both the core and GLideN64, after two crash
// reports showed nothing at all between loadGame: and the fault.
//
// Deliberately paired with the deinit rather than called at every unload:
// the context is only actually invalidated when the core is torn down, and
// pairing it here means the two cores that never get a deinit, FBNeo and
// Flycast, reach none of this. Flycast is the only other hardware-render
// core and it works today; scoping by the deinit keeps it byte-identical
// without needing a core check of its own.
// Set the moment context_destroy has been driven for the current game,
// cleared when a game loads. Only PPSSPP can see this be true at the
// unload-time call site below, because it is the only core whose
// context_destroy is driven anywhere else; for every other core this is
// false there exactly as it always was.
static bool gHWContextDestroyed = false;

static void destroyHWContextIfNeeded(void) {
    if (!gUsesHWRender || !gHWRender.context_destroy || gHWContextDestroyed) {
        return;
    }
    gHWContextDestroyed = true;
    // The core is about to release GL objects, so the context those
    // objects live in has to be the current one.
    if (gGLContext) {
#ifdef CABINET_ANGLE
        cabinetAngleMakeCurrent();
#else
        [EAGLContext setCurrentContext:gGLContext];
#endif
    }
    gHWRender.context_destroy();
}

uintptr_t hwGetCurrentFramebuffer(void) {
    return gFBO;
}

// Standard GL entry points are already linked straight into this binary
// via OpenGLES.framework, so a plain dlsym against the running process
// resolves them; no dynamic loader indirection needed the way EGL/GLX
// platforms require.
#ifdef CABINET_ANGLE
// GLideN64 calls the indexed blend-state entry points, which are ES 3.2;
// ANGLE's Metal backend is a strict ES 3.0 and rejects them (validator:
// "glEnablei: Command requires OpenGL ES 3.2", 40 hits in one run), and
// every rejection left blend state wrong: the rainbow/white polygon
// tears seen on Hydro Thunder 2026-08-19. Apple's laxer driver let the
// same calls work. N64 rendering only ever touches draw buffer 0, so
// translating index 0 to the non-indexed calls is exact; any other index
// is dropped and counted rather than guessed at.
static void GL_APIENTRY cabShimEnablei(GLenum target, GLuint index) {
    if (index == 0) glEnable(target);
}
static void GL_APIENTRY cabShimDisablei(GLenum target, GLuint index) {
    if (index == 0) glDisable(target);
}
#endif

#ifdef CABINET_ANGLE
// Capability camouflage: GLideN64 picks texture-upload and state paths by
// sniffing extensions. Apple's GLES advertised almost nothing, so it took
// the plain paths for a week of correct rendering; ANGLE advertises the
// modern set, steering GLideN64 onto paths that produce silently-unfilled
// textures (the deterministic rainbow surfaces on Hydro Thunder,
// 2026-08-19: same scene, same triangle, no GL errors). Filter the
// extension queries so ANGLE presents Apple's capability surface and the
// core repeats its known-good choices.
static const char *cabBlockedExts[] = {
    "GL_EXT_buffer_storage", "GL_EXT_draw_buffers_indexed",
    "GL_OES_EGL_image", "GL_EXT_texture_storage", nullptr };
static bool cabExtBlocked(const char *e, size_t len) {
    for (int i = 0; cabBlockedExts[i]; i++)
        if (strlen(cabBlockedExts[i]) == len && strncmp(e, cabBlockedExts[i], len) == 0) return true;
    return false;
}
static const GLubyte *GL_APIENTRY cabShimGetString(GLenum name) {
    typedef const GLubyte *(GL_APIENTRY *P)(GLenum);
    static P real = (P)eglGetProcAddress("glGetString");
    if (name != GL_EXTENSIONS) return real(name);
    static std::string filtered;
    if (filtered.empty()) {
        const char *all = (const char *)real(GL_EXTENSIONS);
        if (!all) return nullptr;
        const char *w = all;
        while (*w) {
            const char *end = strchr(w, ' ');
            size_t len = end ? (size_t)(end - w) : strlen(w);
            if (!cabExtBlocked(w, len)) { filtered.append(w, len); filtered += ' '; }
            w += len; while (*w == ' ') w++;
        }
    }
    return (const GLubyte *)filtered.c_str();
}
static const GLubyte *GL_APIENTRY cabShimGetStringi(GLenum name, GLuint index) {
    typedef const GLubyte *(GL_APIENTRY *P)(GLenum, GLuint);
    static P real = (P)eglGetProcAddress("glGetStringi");
    if (name != GL_EXTENSIONS) return real(name, index);
    // Serve from the filtered list so indices stay dense.
    static std::vector<std::string> list;
    if (list.empty()) {
        const char *all = (const char *)cabShimGetString(GL_EXTENSIONS);
        const char *w = all;
        while (w && *w) {
            const char *end = strchr(w, ' ');
            size_t len = end ? (size_t)(end - w) : strlen(w);
            list.emplace_back(w, len);
            w += len; while (*w == ' ') w++;
        }
    }
    return index < list.size() ? (const GLubyte *)list[index].c_str() : nullptr;
}
#endif

retro_proc_address_t hwGetProcAddress(const char *sym) {
#ifdef CABINET_ANGLE
    if (strcmp(sym, "glEnablei") == 0)  return (retro_proc_address_t)cabShimEnablei;
    if (strcmp(sym, "glDisablei") == 0) return (retro_proc_address_t)cabShimDisablei;
    if (strcmp(sym, "glGetString") == 0)  return (retro_proc_address_t)cabShimGetString;
    if (strcmp(sym, "glGetStringi") == 0) return (retro_proc_address_t)cabShimGetStringi;
    // ANGLE's loader owns these symbols; dlsym would find Apple's.
    retro_proc_address_t p = (retro_proc_address_t)eglGetProcAddress(sym);
    if (p) return p;
#endif
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
    // A hardware-render core saying "same picture as last time". Counted
    // for the mode discriminator above; the early return below already
    // treated it as nothing-changed.
    if (gUsesHWRender && data == nullptr) {
        gHWDupeCount.fetch_add(1, std::memory_order_relaxed);
    }
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
        // implementation. RGBA/UNSIGNED_BYTE is the one combination every
        // implementation is required to accept.
        //
        // Straight into gFrameBytes, with no intermediate buffer and no
        // per-pixel work afterwards. This used to read into a fresh
        // std::vector allocated every frame (1.2MB at 640x480, about
        // 60MB/s of allocator churn at 50fps), then walk every pixel to
        // swap R and B and reverse the row order into gFrameBytes. Both
        // are gone: the bytes are handed to Metal as RGBA, and the upside
        // down GL origin is corrected by flipping the display quad's
        // texture coordinates, which costs nothing. Measured on Apple TV
        // 2026-08-16 at 1.15ms a frame for the swizzle alone, against a
        // 20ms budget the core was already missing in heavy scenes.
        glBindFramebuffer(GL_FRAMEBUFFER, gFBO);
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        double readbackStart = nowMS();
        glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, gFrameBytes.data());
        recordStage(gTimeReadbackMS, nowMS() - readbackStart);
        GLenum readbackErr = glGetError();
        // Kept, reporting zero, rather than removed with its accessor:
        // FrameTrace writes a fixed set of columns and a rebuilt trace
        // should stay comparable against the ones already captured.
        recordStage(gTimeSwizzleMS, 0);
        gFrameWidth = width;
        gFrameHeight = height;
        gFrameBytesPerRow = (uint32_t)bytesPerRow;
        gPixelFormat = LibretroPixelFormatRGBA8888;
        gFrameFlipped = true;
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
            for (uint8_t b : gFrameBytes) {
                if (b != 0) {
                    nonZeroBytes++;
                    if (b > maxByte) maxByte = b;
                }
            }
            char buf[224];
            snprintf(buf, sizeof(buf),
                      "read %ux%u frame #%u, %u/%zu bytes non-zero (max=%u), "
                      "preErr=0x%04X readbackErr=0x%04X",
                      width, height, frameCount, nonZeroBytes, gFrameBytes.size(), maxByte,
                      preExistingErr, readbackErr);
            gHWDiagnostic = buf;
#if DEBUG
            // Persist the render diagnostics so a headless black-screen
            // can be diagnosed from a pulled file. Debug builds only.
            {
                NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
                FILE *df = fopen([dir stringByAppendingPathComponent:@"hw-diag.txt"].fileSystemRepresentation, "a");
                if (df) {
                    fprintf(df, "core=%ld setup=[%s] frame=[%s]\n", (long)gCoreID,
                            gHWSetupDiagnostic.c_str(), buf);
                    fclose(df);
                }
                // Frame dumps so the artifacts can be SEEN headlessly:
                // raw RGBA, converted and eyeballed after pulling. Every
                // 300th frame, up to 12 files a session.
                if (frameCount % 300 == 0 && frameCount <= 3600) {
                    NSString *fp = [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"framedump-%ld-%u-%ux%u.raw", (long)gCoreID, frameCount, width, height]];
                    FILE *ff = fopen(fp.fileSystemRepresentation, "w");
                    if (ff) { fwrite(gFrameBytes.data(), 1, gFrameBytes.size(), ff); fclose(ff); }
                }
            }
#endif
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
    // Software-rendered frames are already top-left origin and always
    // were. Cleared rather than left alone so nothing here depends on a
    // core never having produced a hardware frame earlier in the process.
    gFrameFlipped = false;
    gFrameDirty = true;
}

void audioSample(int16_t left, int16_t right) {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    gAudioSamples.push_back(left);
    gAudioSamples.push_back(right);
    gAudioFramesTotal.fetch_add(1, std::memory_order_relaxed);
}

size_t audioSampleBatch(const int16_t *data, size_t frames) {
    std::lock_guard<std::mutex> lock(gAudioMutex);
    gAudioSamples.insert(gAudioSamples.end(), data, data + frames * 2);
    gAudioFramesTotal.fetch_add(frames, std::memory_order_relaxed);
    return frames;
}

void inputPoll(void) {
    // Mouse deltas are relative-since-last-poll by convention, so the
    // accumulator is swapped out here, once per frame, rather than
    // consumed on read: a core reads X and Y as separate calls and both
    // must describe the same frame. Clamped to int16 the way the API is.
    for (size_t p = 0; p < kMaxPorts; p++) {
        int32_t dx = gMouseAccumX[p].exchange(0, std::memory_order_relaxed);
        int32_t dy = gMouseAccumY[p].exchange(0, std::memory_order_relaxed);
        gMouseLatchedX[p] = (int16_t)std::clamp(dx, -32767, 32767);
        gMouseLatchedY[p] = (int16_t)std::clamp(dy, -32767, 32767);
    }
}

int16_t inputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    if (port >= kMaxPorts) {
        return 0;
    }
    uint32_t mask = gButtonMask[port].load(std::memory_order_relaxed);
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
        // melonDS reads this axis as a CURSOR SPEED, not a direction,
        // and that changes what full deflection means. Its joystick
        // touch mode moves the stylus by (value / 2048) pixels every
        // frame, so the 0x7fff every other core wants here is 16
        // pixels a frame: 960 a second across a screen 256 wide, at
        // one fixed speed, because this stick is digitized and has no
        // gentle. Reported on the Apple TV as the cursor jumping too
        // far. Three pixels a frame crosses the touch screen in about
        // a second and a half, which a thumb can actually aim.
        //
        // Scoped to this core alone: every other core reads this axis
        // as a direction, where anything short of full deflection is
        // simply a weaker push, and their lines here are unchanged.
        const int16_t full = gCoreID == LibretroCoreIDMelonDS ? 3 * 2048 : 0x7fff;
        if (id == RETRO_DEVICE_ID_ANALOG_X) {
            if ((mask >> 20) & 1) return full;
            if ((mask >> 21) & 1) return -full;
        } else if (id == RETRO_DEVICE_ID_ANALOG_Y) {
            if ((mask >> 22) & 1) return full;
            if ((mask >> 23) & 1) return -full;
        }
    }
    // Dreamcast's real analog stick, a true continuous value from
    // -setAnalogStickX:y:, not a digitized mask bit like every other
    // stick this frontend reads. y is already down-positive, matching
    // libretro's own convention, no flip needed here either.
    //
    // FBNeo is deliberately excluded. Its retro_input.cpp has a "fake
    // analog" fallback that reads this axis even for plain digital
    // joystick games and ORs the result into the digital directions.
    // Physical controllers have fed this channel unconditionally since
    // the two-player rework (GameController y is up-positive, opposite
    // libretro's convention on this path), so a Bluetooth pad pushing up
    // registered digital UP and fake-analog DOWN in the same frame:
    // exactly the "character doesn't go where the stick points" report
    // on Smash TV, github.com/MMagTech/cabinet#3, found 2026-08-15.
    // Arcade sticks are fully covered by the digital bits; FBNeo has no
    // real analog-stick hardware to serve here at all.
    if (device == RETRO_DEVICE_ANALOG && index == RETRO_DEVICE_INDEX_ANALOG_LEFT
        && gCoreID != LibretroCoreIDFBNeo) {
        float value = id == RETRO_DEVICE_ID_ANALOG_X ? gAnalogLeftX[port].load(std::memory_order_relaxed)
                    : id == RETRO_DEVICE_ID_ANALOG_Y ? gAnalogLeftY[port].load(std::memory_order_relaxed)
                    : 0.0f;
        // TEST BUILD trace: how often the core actually samples the axis,
        // and the last value it saw. Port 0 X only, the steering axis.
        if (port == 0 && id == RETRO_DEVICE_ID_ANALOG_X) {
            gAnalogReads.fetch_add(1, std::memory_order_relaxed);
            gAnalogLastRead.store(value, std::memory_order_relaxed);
        }
        return (int16_t)(std::clamp(value, -1.0f, 1.0f) * 0x7fff);
    }
    // Relative pointing, the dial/spinner/trackball channel. Latched at
    // poll time above; zero whenever nothing is feeding it, which for
    // every existing game and control is always.
    if (device == RETRO_DEVICE_MOUSE) {
        switch (id) {
            case RETRO_DEVICE_ID_MOUSE_X: return gMouseLatchedX[port];
            case RETRO_DEVICE_ID_MOUSE_Y: return gMouseLatchedY[port];
            default: return 0;
        }
    }
    // A lightgun is the same absolute aim with a cabinet's own extra
    // question: is the player pointing off the screen? That gesture is
    // how these games reload, and the core only honours it on this
    // device, not on the pointer.
    if (device == RETRO_DEVICE_LIGHTGUN) {
        switch (id) {
            case RETRO_DEVICE_ID_LIGHTGUN_SCREEN_X: return gPointerX[port].load(std::memory_order_relaxed);
            case RETRO_DEVICE_ID_LIGHTGUN_SCREEN_Y: return gPointerY[port].load(std::memory_order_relaxed);
            case RETRO_DEVICE_ID_LIGHTGUN_TRIGGER:  return gPointerDown[port].load(std::memory_order_relaxed) ? 1 : 0;
            case RETRO_DEVICE_ID_LIGHTGUN_IS_OFFSCREEN:
            case RETRO_DEVICE_ID_LIGHTGUN_RELOAD:
                return gGunOffscreen[port].load(std::memory_order_relaxed) ? 1 : 0;
            default: return 0;
        }
    }
    // Absolute pointing, a touch on the picture itself.
    if (device == RETRO_DEVICE_POINTER) {
        switch (id) {
            case RETRO_DEVICE_ID_POINTER_X: return gPointerX[port].load(std::memory_order_relaxed);
            case RETRO_DEVICE_ID_POINTER_Y: return gPointerY[port].load(std::memory_order_relaxed);
            case RETRO_DEVICE_ID_POINTER_PRESSED: return gPointerDown[port].load(std::memory_order_relaxed) ? 1 : 0;
            case RETRO_DEVICE_ID_POINTER_COUNT: return gPointerDown[port].load(std::memory_order_relaxed) ? 1 : 0;
            default: return 0;
        }
    }
    return 0;
}

// Fires a blunt UIKit impact haptic on the off-to-on edge of a rumble
// effect. Cores call this from the emulation thread, sometimes every
// frame while an effect holds, so gRumbleWasOn tracks state to fire once
// per edge rather than once per call; UIImpactFeedbackGenerator also
// needs the main thread. RETRO_RUMBLE_STRONG maps to .heavy, WEAK to
// .light, a real if approximate translation of libretro's two-motor
// model onto the single, undifferentiated Taptic Engine every iPhone
// actually has, not a full CHHapticEngine intensity curve: the simpler
// API for a first version, per this project's own weekend-sized bias.
bool rumbleSetState(unsigned port, enum retro_rumble_effect effect, uint16_t strength) {
    if (port >= 4 || effect > RETRO_RUMBLE_WEAK) {
        return false;
    }
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"com.mmagtech.RommApp.rumbleEnabled"]) {
        return true; // honored, as "stay off"
    }
    bool isOn = strength > 0;
    bool wasOn;
    {
        std::lock_guard<std::mutex> lock(gRumbleMutex);
        wasOn = gRumbleWasOn[port][effect];
        gRumbleWasOn[port][effect] = isOn;
    }
    if (isOn && !wasOn) {
        BOOL strong = effect == RETRO_RUMBLE_STRONG;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gRumbleHandler) {
                gRumbleHandler(port, strong, strength);
                return;
            }
            // Handler not wired yet (a rumble fired before app launch
            // finished setting it): fall back to a phone haptic directly
            // rather than silently dropping the event. tvOS has no Taptic
            // Engine to fall back to; a rumble that beats the handler wire-up
            // there is simply dropped, same as it would be on an iPhone with
            // haptics off.
#if !TARGET_OS_TV
            UIImpactFeedbackStyle style = strong ? UIImpactFeedbackStyleHeavy : UIImpactFeedbackStyleLight;
            UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
            [generator impactOccurred];
#endif
        });
    }
    return true;
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

// The two halves of libretro's sensor interface.
//
// A cartridge sensor is sampled, not evented: the core asks for whatever
// the current reading is, at whatever moment it happens to look. So
// these just hand back the latest value CoreMotion pushed, and the
// requested rate is accepted and ignored, exactly as RetroArch does,
// since CoreMotion delivers at the interval it was configured with
// rather than one negotiated per read.
bool sensorSetState(unsigned port, enum retro_sensor_action action, unsigned rate) {
    (void)rate;
    if (port != 0) {
        // One device, one set of sensors. A second player's port has no
        // phone of its own to tilt.
        return false;
    }
    switch (action) {
        case RETRO_SENSOR_ACCELEROMETER_ENABLE:
            gAccelerometerEnabled.store(true, std::memory_order_relaxed);
            break;
        case RETRO_SENSOR_ACCELEROMETER_DISABLE:
            gAccelerometerEnabled.store(false, std::memory_order_relaxed);
            break;
        case RETRO_SENSOR_GYROSCOPE_ENABLE:
            gGyroscopeEnabled.store(true, std::memory_order_relaxed);
            break;
        case RETRO_SENSOR_GYROSCOPE_DISABLE:
            gGyroscopeEnabled.store(false, std::memory_order_relaxed);
            break;
        case RETRO_SENSOR_ILLUMINANCE_ENABLE:
        case RETRO_SENSOR_ILLUMINANCE_DISABLE:
            // Refused rather than faked. This is Boktai's solar sensor,
            // and an iPhone's ambient light sensor is not available to
            // apps at all. Saying no is the honest answer, and mGBA
            // already exposes the sun as a core option ("Solar Sensor
            // Level") for exactly this case, which is a better control
            // than a light meter pointed at the ceiling anyway.
            return false;
        default:
            return false;
    }

    BOOL wantsAccelerometer = gAccelerometerEnabled.load(std::memory_order_relaxed);
    BOOL wantsGyroscope = gGyroscopeEnabled.load(std::memory_order_relaxed);
    if (gMotionSensingHandler) {
        // mGBA calls this from inside retro_run, on the emulation
        // thread, so the hop to main belongs here rather than in every
        // handler. CoreMotion's own start and stop are main-thread work.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gMotionSensingHandler) {
                gMotionSensingHandler(wantsAccelerometer, wantsGyroscope);
            }
        });
    }
    return true;
}

float sensorGetInput(unsigned port, unsigned id) {
    if (port != 0) {
        return 0;
    }
    switch (id) {
        case RETRO_SENSOR_ACCELEROMETER_X: return gAccelerationX.load(std::memory_order_relaxed);
        case RETRO_SENSOR_ACCELEROMETER_Y: return gAccelerationY.load(std::memory_order_relaxed);
        case RETRO_SENSOR_ACCELEROMETER_Z: return gAccelerationZ.load(std::memory_order_relaxed);
        // Only Z is reported. mGBA reads nothing else (see its
        // _updateRotation, which samples accelerometer X and Y and
        // gyroscope Z and no other axis), and a cartridge gyroscope
        // only ever measured the one rotation anyway: the plane of the
        // cartridge itself, which is the plane of the screen.
        case RETRO_SENSOR_GYROSCOPE_Z: return gRotationRateZ.load(std::memory_order_relaxed);
        default: return 0;
    }
}

bool environmentCallback(unsigned cmd, void *data) {
    switch (cmd) {
        case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
            // A core correcting its own timing once it knows the game's
            // real video mode. Flycast does this: its setAVInfo divides
            // the SPG-derived rate by the vsync swap interval and calls
            // this whenever that changes, so the rate declared at load
            // can be wrong for the game actually running. Ignoring it
            // meant the draw loop kept pacing against a stale figure and
            // the core handed over more audio per call than a frame's
            // worth, which is discarded and heard as sped-up playback.
            //
            // Only the frame rate and aspect are taken. The sample rate
            // is deliberately left alone: the audio engine's format is
            // fixed when playback starts and cannot follow a change
            // mid-session.
            const struct retro_system_av_info *info = (const struct retro_system_av_info *)data;
            if (!info) { return false; }
            if (info->timing.fps > 0) {
                gTargetFPS.store(info->timing.fps, std::memory_order_relaxed);
                NSLog(@"[core] av_info update: fps now %f", info->timing.fps);
            }
            if (info->geometry.aspect_ratio > 0) {
                gAspectRatio.store(info->geometry.aspect_ratio, std::memory_order_relaxed);
            }
            return true;
        }
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
            variable->value = gVariableValuePool.insert(value.UTF8String).first->c_str();
            return true;
        }
        case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE: {
            auto *rumble = (struct retro_rumble_interface *)data;
            if (!rumble) {
                return false;
            }
            rumble->set_rumble_state = rumbleSetState;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE: {
            auto *sensor = (struct retro_sensor_interface *)data;
            if (!sensor) {
                return false;
            }
            sensor->set_sensor_state = sensorSetState;
            sensor->get_sensor_input = sensorGetInput;
            return true;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            // False for every core whose options only change between
            // loads, which is all of them except melonDS: the phone
            // touch panel flips its touch mode mid-game through
            // updateCoreOptions, and this hands that one change to the
            // core exactly once.
            *(bool *)data = gOptionsDirty.exchange(false);
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
#if TARGET_OS_SIMULATOR
    // No cores in a simulator build; every launch path fails cleanly
    // before it gets here (see NativePlatform.platform(bySlug:)).
    (void)coreID;
    return nullptr;
#else
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
        case LibretroCoreIDMupen64Plus:
            return N64CoreAPI();
        case LibretroCoreIDFlycast:
            return FlycastCoreAPI();
        case LibretroCoreIDMAME2003Plus:
            return MAME2003PlusCoreAPI();
        case LibretroCoreIDVecx:
            return VecxCoreAPI();
        case LibretroCoreIDStella2014:
            return Stella2014CoreAPI();
        case LibretroCoreIDOpera:
            return OperaCoreAPI();
        case LibretroCoreIDBeetleVB:
            return BeetleVBCoreAPI();
        case LibretroCoreIDMelonDS:
            return MelonDSCoreAPI();
        case LibretroCoreIDPPSSPP:
            return PPSSPPCoreAPI();
        default:
            // This used to fall through to the PlayStation core, so a
            // core id with no case did not fail to load: it silently ran
            // PCSX ReARMed, which read as the new core being broken in a
            // baffling way rather than as a missing line here. Crash
            // with the answer instead. tools/lab/wiring/run.sh asserts
            // every declared id has a case before this can ever fire.
            NSLog(@"[LibretroFrontend] coreAPI: no case for core id %ld, add one to this switch", (long)coreID);
            abort();
    }
#endif
}

} // namespace

@implementation LibretroFrontend

+ (LibretroFrontend *)shared {
    static LibretroFrontend *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[LibretroFrontend alloc] init]; });
    return instance;
}

+ (void)setRumbleHandler:(void (^)(NSInteger port, BOOL strong, uint16_t strength))handler {
    gRumbleHandler = handler;
}

+ (void)setMotionSensingHandler:(void (^)(BOOL wantsAccelerometer, BOOL wantsGyroscope))handler {
    gMotionSensingHandler = handler;
}

- (void)setAccelerationX:(float)x y:(float)y z:(float)z {
    gAccelerationX.store(x, std::memory_order_relaxed);
    gAccelerationY.store(y, std::memory_order_relaxed);
    gAccelerationZ.store(z, std::memory_order_relaxed);
}

- (void)setRotationRateZ:(float)z {
    gRotationRateZ.store(z, std::memory_order_relaxed);
}

- (void)activateCore:(LibretroCoreID)coreID {
    if (gCore && gCoreID == coreID) {
        return;
    }
    if (gCore && gInitialized) {
        // A different core was live: give it the full shutdown it expects
        // before its callbacks stop meaning anything. Except where deinit
        // itself is the unsafe part, see coreToleratesDeinit: a core left
        // initialized here keeps only its own idle state, and this app
        // never runs two cores at once, so nothing else is reading it.
        // Switching away from Dreamcast and back was the original way to
        // hit Flycast's re-init crash, before an unconditional teardown
        // in loadGame briefly made it happen on every relaunch.
        if (gGameLoaded) {
            gCore->unload_game();
        }
        if (coreToleratesDeinit(gCoreID)) {
            destroyHWContextIfNeeded();
            gCore->deinit();
            gInitializedCores.erase(gCoreID);
        }
    }
    gCore = coreAPI(coreID);
    gCoreID = coreID;
    // Not blindly false: a core this app declined to deinitialize is
    // still initialized, and telling loadGame otherwise would run a
    // second retro_init on it.
    gInitialized = gInitializedCores.count(coreID) > 0;
    gGameLoaded = false;
    {
        std::lock_guard<std::mutex> lock(gFrameMutex);
        gFrameBytes.clear();
        gFrameDirty = false;
        gFrameFlipped = false;
    }
    {
        std::lock_guard<std::mutex> lock(gAudioMutex);
        gAudioSamples.clear();
    }
    for (size_t p = 0; p < kMaxPorts; p++) {
        gButtonMask[p].store(0, std::memory_order_relaxed);
        gAnalogLeftX[p].store(0, std::memory_order_relaxed);
        gAnalogLeftY[p].store(0, std::memory_order_relaxed);
        gMouseAccumX[p].store(0, std::memory_order_relaxed);
        gMouseAccumY[p].store(0, std::memory_order_relaxed);
        gMouseLatchedX[p] = 0;
        gMouseLatchedY[p] = 0;
        gPointerDown[p].store(false, std::memory_order_relaxed);
        gGunOffscreen[p].store(false, std::memory_order_relaxed);
        // Cleared per activation, or a platform that skips port 1 (a
        // handheld, say) after one that used it would inherit the
        // previous game's stale device type on a port it never asked for.
        gPortDeviceSet[p] = false;
        gPortDevice[p] = 0;
    }
    gRotation.store(0, std::memory_order_relaxed);
    gOptionsDirty.store(false, std::memory_order_relaxed);
    gUsesHWRender = false;
    gHWRender = {};
    gHWContextDestroyed = false;
}

- (void)setCoreOptions:(NSDictionary<NSString *, NSString *> *)options {
    std::lock_guard<std::mutex> lock(gOptionsMutex);
    gOptions = [options copy];
    // Deliberately does NOT raise gOptionsDirty: load-time option
    // setting has never signalled an update and must not start to.
}

- (void)updateCoreOptions:(NSDictionary<NSString *, NSString *> *)options {
    {
        std::lock_guard<std::mutex> lock(gOptionsMutex);
        gOptions = [options copy];
    }
    gOptionsDirty.store(true, std::memory_order_release);
}

- (void)addMouseDeltaX:(NSInteger)dx y:(NSInteger)dy port:(NSInteger)port {
    if (port < 0 || (size_t)port >= kMaxPorts) { return; }
    gMouseAccumX[port].fetch_add((int32_t)dx, std::memory_order_relaxed);
    gMouseAccumY[port].fetch_add((int32_t)dy, std::memory_order_relaxed);
}

- (void)setPointerX:(float)x y:(float)y down:(BOOL)down port:(NSInteger)port {
    if (port < 0 || (size_t)port >= kMaxPorts) { return; }
    gPointerX[port].store((int16_t)(std::clamp(x, -1.0f, 1.0f) * 0x7fff), std::memory_order_relaxed);
    gPointerY[port].store((int16_t)(std::clamp(y, -1.0f, 1.0f) * 0x7fff), std::memory_order_relaxed);
    gPointerDown[port].store(down, std::memory_order_relaxed);
}

- (void)setLightgunOffscreen:(BOOL)offscreen port:(NSInteger)port {
    if (port < 0 || (size_t)port >= kMaxPorts) { return; }
    gGunOffscreen[port].store(offscreen, std::memory_order_relaxed);
}

- (void)setControllerPortDevice:(unsigned)device port:(NSInteger)port {
    if (port < 0 || (size_t)port >= kMaxPorts) { return; }
    gPortDevice[port] = device;
    gPortDeviceSet[port] = true;
}

- (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory {
    return [self loadGame:romPath systemDirectory:systemDirectory saveDirectory:systemDirectory];
}

- (nullable NSString *)loadGame:(NSString *)romPath
                systemDirectory:(NSString *)systemDirectory
                  saveDirectory:(NSString *)saveDirectory {
    if (!gCore) {
        gCore = coreAPI(gCoreID);
    }
    gSystemDirectory = systemDirectory.fileSystemRepresentation;
    gSaveDirectory = saveDirectory.fileSystemRepresentation;

    // Drop whatever the previous game left on screen. activateCore: does
    // this too, but it returns early when the core has not changed, so a
    // second game on the same core inherited the last frame of the first
    // one: still in gFrameBytes, still flagged dirty, so the new player's
    // very first draw uploaded and displayed it. Reported 2026-08-17 as
    // the old game showing briefly before the new one starts, on an N64
    // to N64 relaunch. The same early return is why gUsesHWRender was
    // seen surviving a relaunch in that session's lifecycle trace.
    //
    // Every core runs this line, and every core wants it: none of them
    // benefits from showing the previous game's picture. The window it
    // closes is small, one frame's worth of load time, but it is only
    // ever wrong.
    {
        std::lock_guard<std::mutex> lock(gFrameMutex);
        gFrameBytes.clear();
        gFrameDirty = false;
        gFrameFlipped = false;
    }

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
    // Both conditions, deliberately. Widening this to gInitialized alone
    // was tried on 2026-08-16 as a first (wrong) guess at the Dreamcast
    // relaunch crash, and it made the teardown fire in a state it never
    // used to: a core still initialized whose game is already unloaded,
    // which took an N64 relaunch through the same TexrectDrawer::destroy
    // null deref destroyHWContextIfNeeded now explains in full. That crash
    // was reachable on the ordinary quit path too and predated the
    // widening, so reverting this was necessary but never sufficient. The
    // real Dreamcast fix is coreToleratesDeinit plus the first_run patch
    // in build-flycast.sh; neither needs anything widened here.
    if (gInitialized && gGameLoaded) {
        gCore->unload_game();
        gGameLoaded = false;
        // Plain unload_game without deinit for the cores that cannot take
        // one; see coreToleratesDeinit for what each of them does instead
        // of surviving it.
        if (coreToleratesDeinit(gCoreID)) {
            destroyHWContextIfNeeded();
            gCore->deinit();
            gInitialized = false;
            gInitializedCores.erase(gCoreID);
        }
    }
    gGameLoaded = false;

    // Reset to libretro's own documented default (0RGB1555) before this
    // load, not left however the last core's SET_PIXEL_FORMAT call (or
    // lack of one) happened to leave it. FBNeo and Saturn both request
    // XRGB8888 explicitly, which is why `gPixelFormat`'s own initial
    // value matched them by coincidence and nobody noticed this was
    // missing. A core whose real frames are 16 bits per pixel, read as
    // 32-bit XRGB8888 left over from whatever ran before it, gives the
    // wrong stride and the wrong byte count silently: no crash, just a
    // black screen. Found 2026-08-08 on Genesis Plus GX the same way as
    // the audio crash, a real device test with correct controls and
    // input but nothing on screen.
    //
    // That case used to be described here as Genesis Plus GX never
    // calling SET_PIXEL_FORMAT because FRONTEND_SUPPORTS_RGB565 was
    // undefined. That is not true of this build: the core's own Makefile
    // defines it, and its "Frontend supports RGB565" log string, which
    // only exists inside that #ifdef, is present in the shipped archive.
    // Checked 2026-08-16. The reset below is still needed, for the mGBA
    // ordering reason immediately after this.
    //
    // The reset has to happen BEFORE retro_init, not after: libretro
    // documents SET_PIXEL_FORMAT as callable from retro_load_game or
    // retro_get_system_av_info, but mGBA calls it once inside retro_init
    // (its libretro.c:1369-1382) and never again. This reset used to sit
    // after the init block below, silently wiping mGBA's real RGB565
    // declaration and leaving its frames decoded as RGB1555, a one-bit
    // green misalignment that showed as every GBA game's hues shifted
    // (blue reading magenta) against the same game in the web player.
    // Found 2026-08-11 by working the whole chain backward from real
    // frame dumps: mGBA's bytes and this frontend's RGB1555 decode were
    // each internally consistent, only the format label between them was
    // wrong.
    gPixelFormat = LibretroPixelFormatRGB1555;

    if (!gInitialized) {
        gCore->set_environment(environmentCallback);
        gCore->init();
        gCore->set_video_refresh(videoRefresh);
        gCore->set_audio_sample(audioSample);
        gCore->set_audio_sample_batch(audioSampleBatch);
        gCore->set_input_poll(inputPoll);
        gCore->set_input_state(inputState);
        gInitialized = true;
        gInitializedCores.insert(gCoreID);
    }

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

    for (size_t p = 0; p < kMaxPorts; p++) {
        if (gPortDeviceSet[p] && gPortDevice[p] != 0) {
            gCore->set_controller_port_device((unsigned)p, gPortDevice[p]);
        }
    }

    // Flycast only: its own retro_set_controller_port_device (see
    // shell/libretro/libretro.cpp) waits on first run for every one of
    // the four Maple ports to be explicitly set before it will do
    // anything else, expansion slot setup (where the VMU lives)
    // included. Port 1 now carries a real second player when the loop
    // above set it, so only ports 2-3 (which this app never drives) get
    // explicitly told RETRO_DEVICE_NONE to satisfy the gate; leaving
    // port 1 alone here is what stops this from stepping on the second
    // controller's own port-device call.
    if (gCoreID == LibretroCoreIDFlycast) {
        if (!gPortDeviceSet[1]) {
            gCore->set_controller_port_device(1, 0);
        }
        gCore->set_controller_port_device(2, 0);
        gCore->set_controller_port_device(3, 0);
    }

    struct retro_system_av_info avInfo = {};
    gCore->get_system_av_info(&avInfo);
    {
        std::lock_guard<std::mutex> lock(gAudioMutex);
        gAudioSampleRate = avInfo.timing.sample_rate > 0 ? avInfo.timing.sample_rate : 44100.0;
    }
    // The rate the core expects to be run at, which is not the rate the
    // display refreshes at. Read but never used until 2026-08-16, when
    // instrumenting Dreamcast audio showed the core producing 65,000 to
    // 85,000 audio frames a second against 44,100 of realtime: the draw
    // loop was calling retro_run once per display refresh, and an Apple
    // TV's display link runs far above the 59.94 Flycast asks for, so
    // the emulator was simply running too fast and the surplus audio was
    // being thrown away.
    gTargetFPS.store(avInfo.timing.fps > 0 ? avInfo.timing.fps : 60.0, std::memory_order_relaxed);
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
#ifdef CABINET_ANGLE
        if (!cabinetAngleMakeCurrent()) {
            gHWSetupDiagnostic = "ANGLE EGL context creation FAILED";
            return nil;
        }
        gHWSetupDiagnostic = (const char *)glGetString(GL_RENDERER) ?: "ANGLE, no renderer string";
#else
        EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES3;
        if (!gGLContext || gGLContext.API != api) {
            gGLContext = [[EAGLContext alloc] initWithAPI:api];
        }
        [EAGLContext setCurrentContext:gGLContext];
#endif
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

- (nullable NSString *)systemDirectory {
    return gSystemDirectory.empty() ? nil : [NSString stringWithUTF8String:gSystemDirectory.c_str()];
}

- (nullable NSString *)saveDirectory {
    return gSaveDirectory.empty() ? nil : [NSString stringWithUTF8String:gSaveDirectory.c_str()];
}

- (void)unloadGame {
    if (!gCore || !gInitialized || !gGameLoaded) {
        return;
    }
    // PPSSPP, and only PPSSPP, needs its context torn down BEFORE the
    // game unloads. Its retro_unload_game does `delete ctx; ctx =
    // nullptr`, and its context_destroy is a trampoline that
    // dereferences that same ctx, so driving the two in the order every
    // other core here wants is a null deref inside the core: crashed on
    // quit, on real hardware, 2026-08-24, symbolicated to
    // context_destroy +12 on the main thread. Calling it first is also
    // simply what the libretro contract means, the context is destroyed
    // while it still exists; the existing call site below is a
    // deliberate exception documented in destroyHWContextIfNeeded, kept
    // because N64's GLSM needs the pairing with deinit rather than with
    // unload.
    //
    // Additive on purpose: this runs for PPSSPP alone, and the flag it
    // sets is the only thing the later call site sees differently, so
    // Mupen64Plus and Flycast execute byte-identical code to before.
    if (gCoreID == LibretroCoreIDPPSSPP) {
        destroyHWContextIfNeeded();
    }
    gCore->unload_game();
    gGameLoaded = false;
    // Motion sensing belongs to the game that asked for it. Without this
    // the gyroscope would keep running after WarioWare Twisted quits,
    // draining the battery on behalf of a game that is no longer there,
    // and the next game to load would inherit an enabled sensor it never
    // requested.
    gAccelerometerEnabled.store(false, std::memory_order_relaxed);
    gGyroscopeEnabled.store(false, std::memory_order_relaxed);
    if (gMotionSensingHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gMotionSensingHandler) { gMotionSensingHandler(NO, NO); }
        });
    }
    // Same exception list as loadGame's own teardown, see
    // coreToleratesDeinit. Leaving gInitialized set is what makes the
    // next loadGame skip the fresh-init path, giving those cores exactly
    // the unload-without-deinit sequence they tolerate.
    //
    // This site is the one that mattered for Dreamcast: quitting a game
    // deinitialized Flycast, which on Apple releases its address space
    // without terming the emulator, so the NEXT launch of anything on
    // that core re-initialized into unmapped memory and died in
    // dc_reset. That is the "quit a Dreamcast game and the next one
    // closes the app" report, 2026-08-16.
    if (coreToleratesDeinit(gCoreID)) {
        destroyHWContextIfNeeded();
        gCore->deinit();
        gInitialized = false;
        gInitializedCores.erase(gCoreID);
    }
}

// TEST BUILD input trace: one line per frame, what the core is actually
// being fed. Answers, without inference: is the analog axis arriving, is
// anything pressing d-pad directions, and on which port. Buffered, flushed
// every 60 frames. Delete with the tvOS steering investigation.
static void cabinetInputTrace(void) {
    static FILE *f = nullptr;
    static uint32_t n = 0;
    if (!f) {
        const char *home = getenv("HOME");
        if (!home) return;
        char path[512];
        snprintf(path, sizeof(path), "%s/Library/Caches/input-trace.txt", home);
        f = fopen(path, "w");
        if (!f) return;
        fprintf(f, "frame,p0_ax,p0_ay,p0_up,p0_dn,p0_lt,p0_rt,p1_ax,p1_mask,analog_reads,last_read,qdepth\n");
    }
    uint32_t m0 = gButtonMask[0].load(std::memory_order_relaxed);
    uint32_t m1 = gButtonMask[1].load(std::memory_order_relaxed);
    fprintf(f, "%u,%.3f,%.3f,%d,%d,%d,%d,%.3f,%u,%u,%.3f,%d\n", n++,
            gAnalogLeftX[0].load(std::memory_order_relaxed),
            gAnalogLeftY[0].load(std::memory_order_relaxed),
            (m0 >> RETRO_DEVICE_ID_JOYPAD_UP) & 1,
            (m0 >> RETRO_DEVICE_ID_JOYPAD_DOWN) & 1,
            (m0 >> RETRO_DEVICE_ID_JOYPAD_LEFT) & 1,
            (m0 >> RETRO_DEVICE_ID_JOYPAD_RIGHT) & 1,
            gAnalogLeftX[1].load(std::memory_order_relaxed), m1,
            gAnalogReads.exchange(0, std::memory_order_relaxed),
            gAnalogLastRead.load(std::memory_order_relaxed),
            cabinetQueueDepthNow());
    if (n % 60 == 0) fflush(f);
}

- (void)runFrame {
    cabinetInputTrace();
    if (gInitialized && gGameLoaded) {
        if (gUsesHWRender && gGLContext) {
            // Nothing else in this app touches GLES, so this should
            // already be current, but making it current is cheap and
            // guards against something else on this thread having
            // changed it between frames.
#ifdef CABINET_ANGLE
            cabinetAngleMakeCurrent();
#else
            [EAGLContext setCurrentContext:gGLContext];
#endif
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
        double runStart = nowMS();
        gCore->run();
        recordStage(gTimeCoreRunMS, nowMS() - runStart);
        gRunCallTotal.fetch_add(1, std::memory_order_relaxed);
    }
}

- (BOOL)needsAudioGovernor {
    // Flycast and PPSSPP, the two cores whose emulation is not one
    // frame per retro_run. Every other core here advances exactly one
    // emulated frame per retro_run, so the frame pacing alone already
    // holds them to realtime, and a governor can only ever subtract
    // runs from them. Applying it to all cores slowed N64 down,
    // reported on device 2026-08-16 within hours of the governor
    // landing.
    //
    // Flycast: threaded rendering runs emulation on its own thread, so
    // frame pacing does not gate it and nothing else does either (its
    // libretro audio path drops samples rather than blocking):
    // measured free-running at up to 5x realtime.
    //
    // PPSSPP: its GL emu thread produces one SWAP per retro_run, and a
    // swap is one game frame, not one 60Hz vblank. A 30fps PSP game
    // flips every other vblank, so 60 swaps a second is two seconds of
    // emulated time per real one: Lumines measured at exactly 2.0x on
    // the Apple TV, 2026-08-24, 120 emulated vblanks a second against
    // 60 EmuFrames. In RetroArch the brake is the blocking audio
    // callback; here it is this governor, which skips retro_run while
    // the core's audio output is ahead of the wall clock, exactly the
    // Flycast arrangement. 60fps PSP games are at 1.0x already and the
    // governor never engages for them.
    return gCoreID == LibretroCoreIDFlycast || gCoreID == LibretroCoreIDPPSSPP;
}

- (double)debugCoreRunMS {
    return gTimeCoreRunMS.load(std::memory_order_relaxed);
}

- (uint64_t)debugAudioFramesTotal {
    return gAudioFramesTotal.load(std::memory_order_relaxed);
}

- (uint64_t)debugHWFramesTotal {
    return gHWFrameCount.load(std::memory_order_relaxed);
}

- (uint64_t)debugRunCallTotal {
    return gRunCallTotal.load(std::memory_order_relaxed);
}

- (uint64_t)debugHWDupeTotal {
    return gHWDupeCount.load(std::memory_order_relaxed);
}

- (double)debugReadbackMS {
    return gTimeReadbackMS.load(std::memory_order_relaxed);
}

- (double)debugSwizzleMS {
    return gTimeSwizzleMS.load(std::memory_order_relaxed);
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
                                     pixelFormat:gPixelFormat
                               flippedVertically:gFrameFlipped];
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

- (void)setButtonMask:(uint32_t)mask port:(NSInteger)port {
    if (port < 0 || (size_t)port >= kMaxPorts) { return; }
    gButtonMask[port].store(mask, std::memory_order_relaxed);
}

- (void)setAnalogStickX:(float)x y:(float)y port:(NSInteger)port {
    if (port < 0 || (size_t)port >= kMaxPorts) { return; }
    gAnalogLeftX[port].store(x, std::memory_order_relaxed);
    gAnalogLeftY[port].store(y, std::memory_order_relaxed);
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
    return [self memoryRegion:RETRO_MEMORY_SAVE_RAM];
}

- (double)targetFPS {
    return gTargetFPS.load(std::memory_order_relaxed);
}

- (size_t)saveRAMSize {
    if (!gInitialized || !gGameLoaded || !gCore->get_memory_size) {
        return 0;
    }
    return gCore->get_memory_size(RETRO_MEMORY_SAVE_RAM);
}

- (nullable NSData *)memoryRegion:(unsigned)regionId {
    if (!gInitialized || !gGameLoaded || !gCore->get_memory_data || !gCore->get_memory_size) {
        return nil;
    }
    void *bytes = gCore->get_memory_data(regionId);
    size_t size = gCore->get_memory_size(regionId);
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
    return [self loadMemoryRegion:data region:RETRO_MEMORY_SAVE_RAM];
}

- (BOOL)loadMemoryRegion:(NSData *)data region:(unsigned)regionId {
    if (!gInitialized || !gGameLoaded || !gCore->get_memory_data || !gCore->get_memory_size) {
        return NO;
    }
    void *bytes = gCore->get_memory_data(regionId);
    size_t size = gCore->get_memory_size(regionId);
    if (!bytes || size == 0 || data.length == 0) {
        return NO;
    }
    // The smaller of the two, not an exact match: see the header comment.
    // Genesis Plus GX reports its full 64KB at boot but trims the size to
    // the written bytes at capture, and mGBA reports the 128KB flash
    // maximum until save-type autodetection has run, so a core's own
    // capture legitimately comes back shorter than the region it restores
    // into. The rest of the buffer keeps the core's own initialized
    // erase pattern, exactly what RetroArch's short-.srm load leaves too.
    memcpy(bytes, data.bytes, MIN(data.length, size));
    return YES;
}

@end
