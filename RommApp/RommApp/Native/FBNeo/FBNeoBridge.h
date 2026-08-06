#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, FBNeoPixelFormat) {
    FBNeoPixelFormatRGB1555 = 0,
    FBNeoPixelFormatXRGB8888 = 1,
    FBNeoPixelFormatRGB565 = 2,
};

@interface FBNeoFrame : NSObject
@property (nonatomic, readonly) NSData *pixels;
@property (nonatomic, readonly) uint32_t width;
@property (nonatomic, readonly) uint32_t height;
@property (nonatomic, readonly) uint32_t bytesPerRow;
@property (nonatomic, readonly) FBNeoPixelFormat pixelFormat;
@end

// A minimal, spike-only libretro frontend for FBNeo. One file (well, one
// pair) on purpose, see docs/scope-native-player-spike.md: this proves the
// plumbing for exactly one core and one game, it isn't the shape a second
// native core should inherit.
@interface FBNeoBridge : NSObject

+ (uint32_t)coreAPIVersion;

// romPath: full path to the game's zip (e.g. mslug.zip).
// systemDirectory: a directory containing neogeo.zip; FBNeo looks up the
// BIOS there by convention, the same way RetroArch's system directory works.
// Returns nil on success, or an error description on failure.
+ (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory;

// Runs exactly one emulated frame. Call this from a display-link-driven
// loop; each call may produce a new video frame and some audio samples.
+ (void)runFrame;

// The most recently produced video frame, if any. Copies out of the
// core's own buffer since FBNeo reuses it across calls.
+ (nullable FBNeoFrame *)latestFrame;

// Drains whatever audio has queued since the last call, as interleaved
// 16-bit stereo PCM at the core's native sample rate (see latestAudioRate).
+ (nullable NSData *)drainAudio;
+ (double)audioSampleRate;

// Bit N set means RetroPad button N (matching this codebase's existing
// RetroPad id constants, which already line up with libretro's
// RETRO_DEVICE_ID_JOYPAD_* ordering) is currently held. Call this once per
// frame before -runFrame with whatever the touch pad and/or game controller
// currently report held, merged by the caller. Single player/port only,
// this spike has no player-index concept to plumb through.
+ (void)setButtonMask:(uint32_t)mask;

@end

NS_ASSUME_NONNULL_END
