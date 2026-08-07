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

// The core's claimed libretro API version, without initializing it.
// Debug-screen material: proves the static link is alive.
- (uint32_t)apiVersionForCore:(LibretroCoreID)coreID;

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

// romPath: full path to the game file (zip for arcade, chd for CD systems).
// systemDirectory: where the core looks up BIOS files by name, the same
// convention as RetroArch's system directory.
// Returns nil on success, or an error description on failure.
- (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory;

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

@end

NS_ASSUME_NONNULL_END
