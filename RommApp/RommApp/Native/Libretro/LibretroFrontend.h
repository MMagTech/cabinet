#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, LibretroPixelFormat) {
    LibretroPixelFormatRGB1555 = 0,
    LibretroPixelFormatXRGB8888 = 1,
    LibretroPixelFormatRGB565 = 2,
};

// The statically linked cores this build carries. One core is active at a
// time by design: libretro callbacks are process-global, cores are not
// re-entrant, and the app never runs two games at once.
typedef NS_ENUM(NSInteger, LibretroCoreID) {
    LibretroCoreIDFBNeo NS_SWIFT_NAME(fbneo) = 0,
    LibretroCoreIDBeetleSaturn NS_SWIFT_NAME(beetleSaturn) = 1,
    LibretroCoreIDGambatte NS_SWIFT_NAME(gambatte) = 2,
    LibretroCoreIDMGBA NS_SWIFT_NAME(mgba) = 3,
    LibretroCoreIDGenesisPlusGX NS_SWIFT_NAME(genesisPlusGX) = 4,
    LibretroCoreIDBeetlePCEFast NS_SWIFT_NAME(beetlePCEFast) = 5,
    LibretroCoreIDSnes9x NS_SWIFT_NAME(snes9x) = 6,
    LibretroCoreIDFCEUmm NS_SWIFT_NAME(fceumm) = 7,
    LibretroCoreIDBeetleNGP NS_SWIFT_NAME(beetleNGP) = 8,
    LibretroCoreIDProSystem NS_SWIFT_NAME(prosystem) = 9,
    LibretroCoreIDPicoDrive NS_SWIFT_NAME(picoDrive) = 10,
    LibretroCoreIDPCSXReARMed NS_SWIFT_NAME(pcsxReARMed) = 11,
    // Interpreter-only SH4 (no dynarec, same no-JIT exception as
    // Saturn/PS1), hardware-rendered through a real GLES3 context since
    // Flycast has no software renderer. Passed its go/no-go 2026-08-10
    // and is wired into NativePlatform as of the same week.
    LibretroCoreIDFlycast NS_SWIFT_NAME(flycast) = 12,
    // Interpreter-only R4300 (mupen64plus-cpucore core option forced to
    // pure_interpreter, no dynarec, same no-JIT exception as Flycast),
    // hardware-rendered through a real GLES3 context via GLideN64, this
    // core's own default RDP plugin already, forced explicitly rather
    // than trusted. Passed its go/no-go 2026-08-11 and is wired into
    // NativePlatform as of the same week.
    LibretroCoreIDMupen64Plus NS_SWIFT_NAME(mupen64Plus) = 13,
};

@interface LibretroFrame : NSObject
@property (nonatomic, readonly) NSData *pixels;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) uint32_t bytesPerRow;
@property (nonatomic, readonly) LibretroPixelFormat pixelFormat;
@end

// The shared libretro frontend: video, audio, input, and state plumbing
// that every core needs, driven through a LibretroCoreAPI struct so cores
// wire in as data. Grown out of the FBNeo spike's one-file bridge exactly
// when the second core arrived, as docs/scope-native-saturn.md planned.
@interface LibretroFrontend : NSObject

@property (class, readonly) LibretroFrontend *shared;

// Routes a core's rumble event to wherever it should actually land: a
// connected physical controller's own motor, or the phone's Taptic Engine
// as a fallback. Set once at launch (RommApp.swift) to
// GameControllerManager.shared.fireRumble, since that decision genuinely
// belongs to GameController/CoreHaptics, both Swift-only APIs this
// Objective-C++ frontend has no direct access to. Never called off the
// main thread by this class's own callback, so the handler does not need
// to hop threads itself.
+ (void)setRumbleHandler:(void (^ _Nullable)(NSInteger port, BOOL strong, uint16_t strength))handler;

// Makes this core the one every later call drives. Switching away from a
// core with a game loaded unloads and deinitializes it first; activating
// the already-active core changes nothing, so callers can activate
// unconditionally before every load.
- (void)activateCore:(LibretroCoreID)coreID;

// Core options applied at the next load, consulted whenever the core asks
// RETRO_ENVIRONMENT_GET_VARIABLE. Keys the dictionary lacks fall back to
// the core's own defaults. FBNeo needs none; Beetle Saturn's speed levers
// live here.
- (void)setCoreOptions:(NSDictionary<NSString *, NSString *> *)options;

// The device type port 0 is told to present, applied right after the game
// loads. Not a core variable: Genesis Plus GX picks 3-button versus
// 6-button through retro_set_controller_port_device, so it cannot ride
// along in the options dictionary. 0 leaves the core's own default alone.
- (void)setControllerPortDevice:(unsigned)device;

// romPath: full path to the game file (zip for arcade, chd for CD systems).
// systemDirectory: where the core looks up BIOS files by name, the same
// convention as RetroArch's system directory.
// Returns nil on success, or an error description on failure.
- (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory;

// The directory passed to the last -loadGame:systemDirectory: call. Some
// cores manage their own save files on disk rather than exposing them
// through RETRO_MEMORY_SAVE_RAM (Flycast's VMU saves are the first case
// here), so a caller that needs to find those files needs this path;
// NativeLauncher itself only ever threads it into loadGame, nothing kept
// it around for later.
- (nullable NSString *)systemDirectory;

// Runs exactly one emulated frame. Call this from a display-link-driven
// loop; each call may produce a new video frame and some audio samples.
- (void)runFrame;

// The most recently produced video frame, if any. Copies out of the
// core's own buffer since cores reuse it across calls.
- (nullable LibretroFrame *)latestFrame;

// Drains whatever audio has queued since the last call, as interleaved
// 16-bit stereo PCM at the core's native sample rate.
- (nullable NSData *)drainAudio;
- (double)audioSampleRate;

// The core's own reported display aspect ratio (width/height), captured
// once at load. 0 means the core left it unset, the frontend's own
// signal to derive the ratio from the video frame's raw pixel
// dimensions instead, which is what every caller did before this
// existed. Most systems are square-pixel, where the two always agree;
// some, Saturn included, are not.
- (double)aspectRatio;

// Bit N set means RetroPad button N (matching this codebase's existing
// RetroPad id constants, which already line up with libretro's
// RETRO_DEVICE_ID_JOYPAD_* ordering) is currently held. Call once per
// frame before -runFrame with touch pad and game controller state merged
// by the caller. Single player/port only, still.
- (void)setButtonMask:(uint32_t)mask;

// Left analog stick position, -1 to 1 on each axis, y-positive down
// (matching screen y and libretro's own RETRO_DEVICE_ID_ANALOG_Y
// convention, confirmed against TouchControlPad's identical sign
// choice for the touch stick). Call once per frame alongside
// -setButtonMask:. Dreamcast is the first core here to read this;
// the digital-only right stick FBNeo's twin-stick games use lives
// entirely in -setButtonMask:'s own bits instead.
- (void)setAnalogStickX:(float)x y:(float)y;

// Display rotation the core requested, in 90-degree counter-clockwise
// steps (0-3). Vertical arcade boards render sideways and rely on the
// frontend applying this.
- (uint32_t)rotation;

// Full machine state via the core's retro_serialize. Returns nil if the
// core has no game loaded or serialization fails. Call these on the same
// thread that drives runFrame; a snapshot taken mid-retro_run is corrupt
// by definition.
- (nullable NSData *)serializeState;

// Restores a state previously produced by serializeState. Returns NO if
// the core rejects the bytes, the expected failure mode for a state
// written by a different core build.
- (BOOL)unserializeState:(NSData *)state;

// The core's battery-backed save RAM (RETRO_MEMORY_SAVE_RAM): a PS1
// memory card, a cartridge battery. Nil when the active core's wiring
// does not export the memory API or the core reports no save RAM for
// the loaded game. Same threading rule as serializeState: the core
// mutates this buffer inside retro_run, so only touch it from the
// thread driving runFrame.
- (nullable NSData *)saveRAM;

// Debug-only: the hardware-render pipeline's own state, for cores like
// Flycast that have no software renderer to fall back on. nil for every
// other core, which never sets it. See LibretroCoreIDFlycast.
- (nullable NSString *)hwRenderDiagnostics;

// Copies bytes into the core's save RAM buffer, the standard libretro
// frontend contract for restoring battery saves: call it after the game
// loads, before play begins. Returns NO when there is no buffer or the
// sizes disagree, both meaning the bytes belong to something else.
- (BOOL)loadSaveRAM:(NSData *)data;

@end

NS_ASSUME_NONNULL_END
