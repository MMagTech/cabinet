// The PS2 player's C surface, for Swift.
//
// Swift cannot see CabinetPS2Host.h: that header is C++ and lives
// outside every target, because its implementation is compiled into
// libpcsx2_mac.a by tools/build-pcsx2-mac.sh rather than by Xcode.
// This is the flat C face of the same thing, declared here where the
// Mac target's bridging header can reach it and implemented beside
// the rest of the host layer.
//
// Mac only. There is no iOS or tvOS PS2 and there will not be one:
// PCSX2 needs a recompiler, and only macOS grants one.

#ifndef CABINET_PS2_BRIDGE_H
#define CABINET_PS2_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct
{
	const char* disc_path;
	const char* data_root;
	const char* resources_dir;

	/// Bare filename, not a path: PCSX2 resolves it inside its own
	/// memcards folder. Empty leaves PCSX2's shared Mcd001.ps2, which
	/// is the hardware's arrangement and the wrong one here.
	const char* memory_card;

	/// A UIView whose +layerClass is CAMetalLayer. Null draws nothing.
	void* view;

	bool fast_boot;
	bool verbose_log;
} CabinetPS2Config;

typedef struct
{
	float fps;
	float speed;
	float ee_usage;
	float gs_usage;
} CabinetPS2Metrics;

/// Boots the disc and runs until CabinetPS2RequestStop. BLOCKS for the
/// life of the game, so it needs its own thread. On failure returns
/// false and writes a message into error.
bool CabinetPS2Run(const CabinetPS2Config* config, char* error, size_t error_length);

/// Safe from any thread, including while Run is still starting up.
void CabinetPS2RequestStop(void);

bool CabinetPS2IsRunning(void);

/// All zero when nothing is running.
CabinetPS2Metrics CabinetPS2GetMetrics(void);

/// The picture settings the pause panel offers. Applied together,
/// because PCSX2 re-reads its whole graphics config in one step and
/// four separate calls would mean four of those.
typedef struct
{
	/// PCSX2's TVShader index. Source-exact, from GS.cpp's own list:
	/// 0 none, 1 scanline, 2 diagonal, 3 triangular, 4 wave,
	/// 5 Lottes CRT, 6 4xRGSS, 7 NxAGSS.
	int tv_shader;

	/// One of PCSX2's AspectRatioNames, verbatim: "Stretch",
	/// "Auto 4:3/3:2", "4:3", "16:9", "10:7".
	const char* aspect;

	/// AccBlendLevel: 0 minimum through 5 maximum.
	int blending;

	/// Internal resolution, 1.0 being the PS2's own.
	float upscale;

	/// PCSX2's GSRendererType. -1 leaves Cabinet's own choice, which
	/// is Metal with a view and Null without. Exists so a renderer can
	/// be forced while chasing a game that draws nothing.
	int renderer;

	/// GSInterlaceMode, -1 for PCSX2's Automatic.
	int deinterlace;
} CabinetPS2Graphics;

void CabinetPS2SetGraphics(const CabinetPS2Graphics* graphics);

/// Save states, by slot, the way every other core in Cabinet stores
/// them. All three run on PCSX2's own emulation thread rather than the
/// caller's, because that is the only thread allowed to touch VM state.
/// Save and load block until done, so a panel can report the result
/// rather than guess.
bool CabinetPS2SaveStateToSlot(int slot);
bool CabinetPS2LoadStateFromSlot(int slot);
bool CabinetPS2HasStateInSlot(int slot);

/// Writes a PNG of what the GS just rendered.
///
/// A diagnostic, not a feature. It answers the one question a frame
/// counter cannot: whether a black display means the emulator drew
/// nothing, or drew something that failed to reach the screen.
void CabinetPS2Screenshot(const char* path);

/// Pauses and resumes the running game. Ignored when none is.
void CabinetPS2SetPaused(bool paused);

/// The size of the view's drawable, in pixels, and its scale.
///
/// Not optional and not a refinement: PCSX2 sets the Metal layer's
/// drawableSize from this, so leaving it zero produces a perfectly
/// healthy looking 60fps into a surface with no pixels in it. Call it
/// before Run, and again whenever the view resizes.
void CabinetPS2SetSurfaceSize(unsigned int width, unsigned int height, float scale);

/// Controller input, in PCSX2's own DualShock2 numbering. Cabinet maps
/// its RetroPad ids on the Swift side, because that is where the
/// mapping is readable next to the controller code it comes from.
///
/// Ignored while no game is running, so there is no ordering problem
/// between a pad connecting and a disc booting.
void CabinetPS2SetButton(unsigned int pad, unsigned int button, float value);

/// The DualShock2 button indices Cabinet needs. Mirrors
/// PadDualshock2::Inputs, which is not a header Swift can see.
typedef enum
{
	CabinetPS2Up = 0,
	CabinetPS2Right = 1,
	CabinetPS2Down = 2,
	CabinetPS2Left = 3,
	CabinetPS2Triangle = 4,
	CabinetPS2Circle = 5,
	CabinetPS2Cross = 6,
	CabinetPS2Square = 7,
	CabinetPS2Select = 8,
	CabinetPS2Start = 9,
	CabinetPS2L1 = 10,
	CabinetPS2L2 = 11,
	CabinetPS2R1 = 12,
	CabinetPS2R2 = 13,
	CabinetPS2L3 = 14,
	CabinetPS2R3 = 15,
	CabinetPS2Analog = 16,
	CabinetPS2LeftStickUp = 18,
	CabinetPS2LeftStickRight = 19,
	CabinetPS2LeftStickDown = 20,
	CabinetPS2LeftStickLeft = 21,
} CabinetPS2Button;

#ifdef __cplusplus
}
#endif

#endif // CABINET_PS2_BRIDGE_H
