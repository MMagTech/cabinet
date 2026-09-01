// The GameCube player's C surface, for Swift.
//
// Swift cannot see CabinetDolphinHost.h: that header is C++ and lives
// outside every target, because its implementation is compiled into
// libdolphin_mac.a by tools/build-dolphin-mac.sh rather than by Xcode.
// This is the flat C face of the same thing, declared here where the
// Mac target's bridging header can reach it.
//
// Mac only. There is no iOS or tvOS GameCube and there will not be one:
// Dolphin needs a recompiler, and only macOS grants one. See
// docs/scope-v0.1.md's JIT boundary.

#ifndef CABINET_DOLPHIN_BRIDGE_H
#define CABINET_DOLPHIN_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Dolphin's own PadButton values, from InputCommon/GCPadStatus.h,
/// copied verbatim so Swift can name them without seeing that header.
/// Source-exact on purpose: a re-derived bit here would be a silent
/// wrong button.
enum
{
	CABINET_GC_DPAD_LEFT = 0x0001,
	CABINET_GC_DPAD_RIGHT = 0x0002,
	CABINET_GC_DPAD_DOWN = 0x0004,
	CABINET_GC_DPAD_UP = 0x0008,
	CABINET_GC_TRIGGER_Z = 0x0010,
	CABINET_GC_TRIGGER_R = 0x0020,
	CABINET_GC_TRIGGER_L = 0x0040,
	CABINET_GC_BUTTON_A = 0x0100,
	CABINET_GC_BUTTON_B = 0x0200,
	CABINET_GC_BUTTON_X = 0x0400,
	CABINET_GC_BUTTON_Y = 0x0800,
	CABINET_GC_BUTTON_START = 0x1000,
};

typedef struct
{
	/// The disc image: ISO, GCM, RVZ, CISO, and the rest of what
	/// Dolphin's DiscIO can open.
	const char* game_path;

	/// Dolphin's read-only Sys folder, bundled with the app. Boot fails
	/// without it rather than degrading.
	const char* sys_dir;

	/// This game's own writable root: saves, memory cards, config and
	/// the shader cache. One per game, so nothing bleeds between titles.
	const char* user_dir;

	/// This game's memory card, a full path. Dolphin creates the file
	/// if it is not there. Empty leaves Dolphin's shared card.
	const char* memory_card;

	bool verbose_log;
} CabinetDolphinConfig;

/// One GameCube controller port, in the console's own units. The
/// conversion from whatever pad someone is actually holding happens
/// once, in Cabinet, the way it does for every other core.
typedef struct
{
	/// Or-ed CABINET_GC_* bits.
	uint16_t buttons;
	/// 0 to 255, centre 128.
	uint8_t stick_x;
	uint8_t stick_y;
	uint8_t substick_x;
	uint8_t substick_y;
	uint8_t trigger_left;
	uint8_t trigger_right;
	bool connected;
} CabinetDolphinPad;

/// Boots the game and runs until CabinetDolphinRequestStop. BLOCKS for
/// the life of the game, so it needs its own thread. On failure returns
/// false and writes a message into error.
bool CabinetDolphinRun(const CabinetDolphinConfig* config, char* error, size_t error_length);

/// The CAMetalLayer Dolphin presents into. Set before Run; null boots
/// headless.
void CabinetDolphinSetSurfaceLayer(void* layer);

/// The drawable size in pixels. Safe before Run and while running.
void CabinetDolphinSetSurfaceSize(int width, int height, float scale);

/// Pushes one port's state, 0 to 3. Safe from any thread. Until the
/// first call Dolphin stays on its own controller stack, which reads as
/// a dead pad.
void CabinetDolphinSetPad(int port, const CabinetDolphinPad* pad);

void CabinetDolphinSetPaused(bool paused);

/// Safe from any thread, including while Run is still starting up.
void CabinetDolphinRequestStop(void);

bool CabinetDolphinIsRunning(void);

/// Dolphin's own live numbers, all zero when nothing is running.
/// vps is presented frames per second, as distinct from fps, which is
/// frames the emulated GPU produced. A surface with no pixels keeps fps
/// healthy and takes vps to nothing.
typedef struct
{
	float fps;
	float vps;
	float speed;
} CabinetDolphinMetrics;

CabinetDolphinMetrics CabinetDolphinGetMetrics(void);

/// Writes a PNG of the current presented frame into the running game's
/// ScreenShots folder, through Dolphin's own screenshot path. Separates
/// "not drawing" from "not visible", which a screen capture cannot.
void CabinetDolphinScreenshot(const char* name);

/// Save states, slots 1 through 10, Dolphin's own numbering. Safe from
/// any thread and NOT instant: Dolphin schedules them onto the CPU
/// thread, so a state asked for immediately before a shutdown may never
/// be written.
/// The picture settings the pause panel offers, applied together.
///
/// No shaders on purpose. Dolphin ships 48 post-processing shaders and
/// they are effects rather than a television: sepia, invert,
/// nightvision, FXAA, and no scanline or CRT among them. These three
/// are what actually make a GameCube game look better on a 5K display.
typedef struct
{
	/// 0 auto (match the window), 1 the console's own, up to 12.
	int internal_resolution;
	/// MSAA samples. 1 is off, then 2, 4, 8.
	unsigned int msaa;
	/// Supersampling instead of multisampling, same count. Expensive.
	bool ssaa;
	/// -1 default, 0 forces 1x, then 1, 2, 3, 4 for 2x, 4x, 8x, 16x.
	int anisotropy;
} CabinetDolphinGraphics;

/// Safe before Run, in which case these are the settings the game
/// starts with, and safe while running.
void CabinetDolphinSetGraphics(const CabinetDolphinGraphics* graphics);

void CabinetDolphinSaveState(int slot);
void CabinetDolphinLoadState(int slot);

#ifdef __cplusplus
}
#endif

#endif  // CABINET_DOLPHIN_BRIDGE_H
