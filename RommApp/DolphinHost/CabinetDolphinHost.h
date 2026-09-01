// Cabinet's host layer for Dolphin: the surface pointing back at
// Cabinet, as opposed to the Host_ functions Dolphin calls.
//
// C++ and outside every Xcode target, because its implementation is
// compiled into libdolphin_mac.a by tools/build-dolphin-mac.sh. Swift
// sees the flat C face of the same thing in
// RommApp/RommAppMac/Dolphin/CabinetDolphinBridge.h.
//
// THREADING: Run blocks for the entire life of the game and must be
// given its own thread. Dolphin starts its emulation and video threads
// underneath. RequestStop is safe from any thread and is the only way
// out.

#pragma once

#include <cstdint>
#include <string>

namespace CabinetDolphin
{
struct Config
{
  /// The disc image. ISO, GCM, RVZ, CISO and the rest of what DiscIO
  /// knows how to open.
  std::string game_path;

  /// Dolphin's read-only Sys folder, bundled with the app: GameCube IPL
  /// fonts, shared game settings, shader presets. Boot fails without
  /// it rather than degrading.
  std::string sys_dir;

  /// Where this game's saves, memory cards, config and shader cache
  /// live. Cabinet lays it out per game; Dolphin only reads and writes
  /// inside it.
  std::string user_dir;

  /// This game's memory card, a full path. Dolphin creates the file if
  /// it is not there. Empty leaves Dolphin's shared card, which is the
  /// hardware's arrangement and the wrong one here: RomM stores saves
  /// against a rom, and a shared card belongs to no rom in particular.
  std::string memory_card;

  /// Prints Dolphin's own log. The only way to answer questions like
  /// whether the recompiler took.
  bool verbose_log = false;
};

/// One GameCube controller port, in the console's own units, so the
/// conversion from whatever pad a person is holding happens once, in
/// Cabinet, where every other core's already does.
struct PadState
{
  /// Or-ed PAD_BUTTON_* and PAD_TRIGGER_* bits from Dolphin's
  /// GCPadStatus.h. Cabinet's copy of those values is in
  /// CabinetDolphinBridge.h so Swift can name them.
  uint16_t buttons = 0;
  /// 0 to 255, centre 128.
  uint8_t stick_x = 128;
  uint8_t stick_y = 128;
  uint8_t substick_x = 128;
  uint8_t substick_y = 128;
  uint8_t trigger_left = 0;
  uint8_t trigger_right = 0;
  bool connected = true;
};

/// Boots the game and runs until RequestStop. Blocks. Returns false and
/// fills error if the emulator never started.
bool Run(const Config& config, std::string* error);

/// The CAMetalLayer Dolphin presents into. Set before Run; a null layer
/// boots headless, which is what a smoke test wants.
void SetSurfaceLayer(void* layer);

/// The drawable size in pixels. Safe before Run and while running.
void SetSurfaceSize(int width, int height, float scale);

/// Pushes one port's state. Safe from any thread. Until the first call
/// Dolphin stays on its own controller stack.
void SetPadState(int port, const PadState& state);

void SetPaused(bool paused);
void RequestStop();
bool IsRunning();

/// Live performance, all zero when nothing is running. These are
/// Dolphin's own numbers, from the PerformanceMetrics the on-screen
/// overlay reads, rather than anything Cabinet counts for itself.
///
/// vps is the one that matters most and the one a frame counter alone
/// would hide: fps counts frames the emulated GPU produced, vps counts
/// times the picture was actually presented. A surface with no pixels
/// keeps a healthy fps and drops vps to nothing, which is exactly the
/// black-screen bug PS2 spent an evening on with six signals all
/// reading healthy.
struct Metrics
{
  float fps;
  float vps;
  float speed;
};

Metrics GetMetrics();

/// Writes a PNG of the CURRENT PRESENTED FRAME through Dolphin's own
/// screenshot path, under the user directory's ScreenShots folder.
///
/// This exists because a screen capture cannot answer the question it
/// looks like it answers. A black capture can mean a broken present
/// path, a sleeping display, a window that was never on screen, or a
/// game that is genuinely on a black frame, and those look identical.
/// PS2 lost an evening to exactly that confusion. This reads the frame
/// the emulator produced, so it separates "not drawing" from "not
/// visible".
void SaveScreenshot(const std::string& name);

/// Save states, into the running game's user directory. Slots are
/// Dolphin's own numbering, 1 through 10.
///
/// Both are safe from any thread: Dolphin schedules them onto the CPU
/// thread rather than doing the work where it was asked, so neither
/// blocks and neither is instant. That also means a state written just
/// before the emulator stops may not exist by the time it has stopped.
void SaveState(int slot);
void LoadState(int slot);
}  // namespace CabinetDolphin
