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

// The device type a port is told to present, applied right after the game
// loads. Not a core variable: Genesis Plus GX picks 3-button versus
// 6-button through retro_set_controller_port_device, so it cannot ride
// along in the options dictionary. 0 leaves the core's own default alone.
// `port` is 0 or 1; callers only set port 1 on platforms with a real
// second port to plug into.
- (void)setControllerPortDevice:(unsigned)device port:(NSInteger)port;

// romPath: full path to the game file (zip for arcade, chd for CD systems).
// systemDirectory: where the core looks up BIOS files by name, the same
// convention as RetroArch's system directory.
// saveDirectory: where a core that manages its own save files writes them
// (RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY): Sega CD's .brm, Neo Geo
// Pocket's .flash, FBNeo's NVRAM and high scores. Must be a directory
// that outlives the session; RetroArch's is persistent, and pointing
// this at the per-launch temp directory is how those saves used to
// vanish (issue #5 stage 2).
// Returns nil on success, or an error description on failure.
- (nullable NSString *)loadGame:(NSString *)romPath
                systemDirectory:(NSString *)systemDirectory
                  saveDirectory:(NSString *)saveDirectory;

// The old signature, save directory defaulting to the system directory,
// exactly what every call site meant before the two were split.
- (nullable NSString *)loadGame:(NSString *)romPath systemDirectory:(NSString *)systemDirectory;

// The directory passed to the last -loadGame:systemDirectory: call. Some
// cores manage their own save files on disk rather than exposing them
// through RETRO_MEMORY_SAVE_RAM (Flycast's VMU saves are the first case
// here), so a caller that needs to find those files needs this path;
// NativeLauncher itself only ever threads it into loadGame, nothing kept
// it around for later.
- (nullable NSString *)systemDirectory;

// The save directory from the last load, for the player's quit-time scan
// of the files a core flushed there.
- (nullable NSString *)saveDirectory;

// Shuts the core down the way the next loadGame's own teardown would,
// unload plus the full deinit (minus FBNeo, whose BurnLibExit cannot
// survive a second deinit in one process; see loadGame's comment). Call
// at quit, after the last snapshot of core memory has been taken:
// retro_unload_game is the one moment file-writing cores flush their
// saves (Sega CD's bram_save, Neo Geo Pocket's flash_commit, FBNeo's
// NVRAM, all confirmed in the vendored sources), and this frontend used
// to only unload lazily at the NEXT launch, after the save directory
// those flushes wrote into had already been deleted. RetroArch's content
// close does exactly this, in this order (runloop.c: SRAM save, then
// core_unload_game, then deinit). Safe against a still-ticking draw
// loop: runFrame and every snapshot method already guard on the
// game-loaded flag this clears.
- (void)unloadGame;

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
// by the caller. `port` is the local player slot, 0 or 1; each port keeps
// its own state, so player 2 never aliases onto the twin-stick bits
// player 1's mask carries. Out-of-range ports are ignored.
- (void)setButtonMask:(uint32_t)mask port:(NSInteger)port;

// Left analog stick position, -1 to 1 on each axis, y-positive down
// (matching screen y and libretro's own RETRO_DEVICE_ID_ANALOG_Y
// convention, confirmed against TouchControlPad's identical sign
// choice for the touch stick). Call once per frame alongside
// -setButtonMask:. Dreamcast is the first core here to read this;
// the digital-only right stick FBNeo's twin-stick games use lives
// entirely in -setButtonMask:'s own bits instead. Same port rules as
// -setButtonMask:port:.
- (void)setAnalogStickX:(float)x y:(float)y port:(NSInteger)port;

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

// The current reported size of the core's save RAM, without copying it.
// Cheap enough to poll every frame, which is what the re-seat below
// needs: mGBA reports a placeholder 128KB region until it has worked
// out which save type the game actually uses, and re-initializes its
// save buffer at that moment, so the size changing is the signal that
// a restore seated before then has to be applied again.
- (size_t)saveRAMSize;

// A copy of any core memory region (a RETRO_MEMORY_* id), the general
// form of -saveRAM. Exists for RETRO_MEMORY_RTC: Gambatte keeps the
// Game Boy real-time clock in its own region next to the save RAM, and
// capturing only the save RAM silently loses the clock Pokemon Gold
// and Silver depend on. Same nil conditions and threading rule as
// -saveRAM.
- (nullable NSData *)memoryRegion:(unsigned)regionId;

// Debug-only: the hardware-render pipeline's own state, for cores like
// Flycast that have no software renderer to fall back on. nil for every
// other core, which never sets it. See LibretroCoreIDFlycast.
- (nullable NSString *)hwRenderDiagnostics;

// Copies bytes into the core's save RAM buffer, the standard libretro
// frontend contract for restoring battery saves: call it after the game
// loads, before play begins. Copies the smaller of the blob and the
// region rather than demanding an exact match, the same thing RetroArch
// does when it reads an .srm back in, because two cores here genuinely
// report a different size at restore time than at capture time: Genesis
// Plus GX trims its reported size to the bytes actually written once
// the game is running, and mGBA reports the 128KB flash maximum until
// it has autodetected the game's real save type. Returns NO when there
// is no buffer at all.
- (BOOL)loadSaveRAM:(NSData *)data;

// The general form of -loadSaveRAM:, for restoring a non-SAVE_RAM
// region (the Game Boy clock). Same copy-the-smaller-length contract.
- (BOOL)loadMemoryRegion:(NSData *)data region:(unsigned)regionId;

@end

NS_ASSUME_NONNULL_END
