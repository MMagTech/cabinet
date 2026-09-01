// Cabinet's host layer for Dolphin.
//
// Dolphin is not a libretro core. It is a whole emulator that expects a
// frontend to exist around it: it calls out through the Host_ functions
// for focus, window size, titles and lifecycle messages, and upstream
// has exactly two implementations of that, the Qt desktop app and the
// nogui tool. Neither can run inside a Catalyst app, so this is the
// third, the same arrangement PCSX2 already has in RommApp/PCSX2Host.
//
// This file is deliberately small. Dolphin's host surface is nineteen
// functions against PCSX2's fifty-four, and most of them are questions
// about a desktop window that Cabinet answers with a constant, because
// the render surface is always the whole of a view that is always
// focused for as long as a game is running.
//
// THREADING. Dolphin runs the emulation on its own thread, started
// inside BootCore. Run() below stays on the caller's thread and does
// nothing but pump Dolphin's host job queue until the game ends, so it
// must be given a thread of its own and never the main one.
//
// Compiled by tools/build-dolphin-mac.sh into libdolphin_mac.a, never
// by Xcode, which is why it lives outside every synchronised folder.

#include "CabinetDolphinHost.h"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <thread>

#include "Common/CommonTypes.h"
#include "Common/FileUtil.h"
#include "Common/Logging/LogManager.h"
#include "Common/MsgHandler.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/GraphicsSettings.h"
#include "VideoCommon/VideoConfig.h"
#include "Core/Config/MainSettings.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/Host.h"
#include "Core/HW/EXI/EXI_Device.h"
#include "Core/State.h"
#include "Core/System.h"
#include "InputCommon/GCPadStatus.h"
#include "UICommon/UICommon.h"
#include "VideoCommon/PerformanceMetrics.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoConfig.h"

namespace
{
std::atomic<bool> s_running{false};
std::atomic<bool> s_stop_requested{false};

// The surface Dolphin presents into, and its pixel size. Written by the
// view before Run and on every resize; read by the video backend.
std::mutex s_surface_lock;
void* s_surface_layer = nullptr;
int s_surface_width = 0;
int s_surface_height = 0;
float s_surface_scale = 1.0f;

// Cabinet's pad state, four ports. Written from Swift on the main
// thread, read from Dolphin's emulation thread every frame, so the
// whole struct is copied under a lock rather than torn field by field:
// a half-updated stick is a visible glitch, and this is cheap.
// Where this game's save states go, set at boot from the user
// directory. Empty until then, which is what makes the state calls
// no-ops before a game exists.
std::string s_state_dir;

std::mutex s_graphics_lock;
CabinetDolphin::Graphics s_graphics;

// Pushed into Dolphin's config rather than held here. Called before the
// boot so a game starts with the settings, and again whenever the panel
// changes one: the video backend reads these from config on its own
// thread, which is why nothing here touches the renderer directly.
// Dolphin's config layers do not exist until UICommon::Init, and
// SetBaseOrCurrent into a config that is not up is a crash, not a
// no-op. The panel legitimately calls SetGraphics before a game boots,
// to seed the settings it will start with, so this is the guard that
// makes that safe: the values are always stored, and Run applies them
// itself once the config exists.
std::atomic<bool> s_config_ready{false};

void ApplyGraphics()
{
  if (!s_config_ready.load())
    return;
  CabinetDolphin::Graphics graphics;
  {
    std::lock_guard lock(s_graphics_lock);
    graphics = s_graphics;
  }
  ::Config::SetBaseOrCurrent(::Config::GFX_EFB_SCALE, graphics.internal_resolution);
  ::Config::SetBaseOrCurrent(::Config::GFX_MSAA, graphics.msaa);
  ::Config::SetBaseOrCurrent(::Config::GFX_SSAA, graphics.ssaa);
  ::Config::SetBaseOrCurrent(::Config::GFX_ENHANCE_MAX_ANISOTROPY,
                             static_cast<AnisotropicFilteringMode>(graphics.anisotropy));

  // Read back rather than trusting the write. Dolphin does not persist
  // this config anywhere Cabinet can inspect afterwards, so without this
  // line "the setting was applied" would rest on nothing but the call
  // having been made, which is the shape of claim that has been wrong
  // three times on this project already.
  fprintf(stderr, "[GC] cabinet: picture applied, resolution=%d msaa=%u ssaa=%d anisotropy=%d\n",
          ::Config::Get(::Config::GFX_EFB_SCALE), ::Config::Get(::Config::GFX_MSAA),
          ::Config::Get(::Config::GFX_SSAA) ? 1 : 0,
          static_cast<int>(::Config::Get(::Config::GFX_ENHANCE_MAX_ANISOTROPY)));
}

std::mutex s_pad_lock;
CabinetDolphin::PadState s_pads[4];
bool s_pads_active = false;
}  // namespace

namespace CabinetDolphin
{

void SetSurfaceLayer(void* layer)
{
  std::lock_guard lock(s_surface_lock);
  s_surface_layer = layer;
}

void SetSurfaceSize(int width, int height, float scale)
{
  {
    std::lock_guard lock(s_surface_lock);
    s_surface_width = width;
    s_surface_height = height;
    s_surface_scale = scale;
  }
  // Once a game is running the resize has to go through the video
  // backend's own path, on its own thread. Before that, the numbers
  // above are simply what it will start with.
  if (s_running.load() && g_presenter)
    g_presenter->ResizeSurface();
}

void SetPadState(int port, const PadState& state)
{
  if (port < 0 || port >= 4)
    return;
  std::lock_guard lock(s_pad_lock);
  s_pads[port] = state;
  s_pads_active = true;
}

void SetPaused(bool paused)
{
  if (!s_running.load())
    return;
  auto& system = Core::System::GetInstance();
  Core::SetState(system, paused ? Core::State::Paused : Core::State::Running);
}

bool IsRunning()
{
  return s_running.load();
}

// State::Save and State::Load take a SLOT and resolve it against
// Dolphin's own StateSaves directory. Cabinet uses SaveAs and LoadAs
// with a path of its own instead, for the same reason it hands Dolphin
// an explicit memory card path: the file belongs beside the rest of
// this game's data, under a name Cabinet chose, rather than in a shared
// numbered slot whose location is Dolphin's business.
std::string StatePath(int slot)
{
  return s_state_dir.empty() ? std::string()
                             : s_state_dir + "/cabinet-" + std::to_string(slot) + ".sav";
}

void SaveState(int slot)
{
  if (!s_running.load() || s_state_dir.empty())
    return;
  const std::string path = StatePath(slot);
  fprintf(stderr, "[GC] cabinet: saving state to %s\n", path.c_str());
  State::SaveAs(Core::System::GetInstance(), path);
}

void LoadState(int slot)
{
  if (!s_running.load() || s_state_dir.empty())
    return;
  const std::string path = StatePath(slot);
  if (!File::Exists(path))
  {
    fprintf(stderr, "[GC] cabinet: no state at %s\n", path.c_str());
    return;
  }
  fprintf(stderr, "[GC] cabinet: loading state from %s\n", path.c_str());
  State::LoadAs(Core::System::GetInstance(), path);
}

void SetGraphics(const Graphics& graphics)
{
  {
    std::lock_guard lock(s_graphics_lock);
    s_graphics = graphics;
  }
  ApplyGraphics();
}

void SaveScreenshot(const std::string& name)
{
  if (!s_running.load())
    return;
  Core::SaveScreenShot(name);
}

Metrics GetMetrics()
{
  Metrics out{};
  if (!s_running.load())
    return out;
  auto& metrics = Core::System::GetInstance().GetPerfMetrics();
  out.fps = static_cast<float>(metrics.GetFPS());
  out.vps = static_cast<float>(metrics.GetVPS());
  out.speed = static_cast<float>(metrics.GetSpeed() * 100.0);
  return out;
}

void RequestStop()
{
  s_stop_requested.store(true);
}

bool Run(const Config& config, std::string* error)
{
  if (s_running.exchange(true))
  {
    if (error)
      *error = "a game is already running";
    return false;
  }
  s_stop_requested.store(false);

  struct Guard
  {
    ~Guard() { s_running.store(false); }
  } guard;

  // Dolphin keeps two roots apart and both must be set before Init.
  // Sys is read-only and ships in the bundle: GameCube IPL fonts, the
  // shared game settings, the shader presets. User is where saves,
  // memory cards, config and the shader cache are written, and Cabinet
  // gives every game its own so nothing bleeds between titles.
  File::SetSysDirectory(config.sys_dir);
  UICommon::SetUserDirectory(config.user_dir);
  UICommon::Init();
  s_config_ready.store(true);

  s_state_dir = config.user_dir + "/CabinetStates";
  File::CreateFullPath(s_state_dir + "/");

  if (config.verbose_log)
  {
    // Worth having rather than guessing from behaviour. It is the only
    // way to answer questions like whether the JIT actually took, and
    // that question has been answered wrongly from behaviour before.
    // Every log type, not a chosen few. The first version of this
    // enabled BOOT, CORE and VIDEO, which is exactly the set that says
    // nothing when a save state silently fails to write, and it turned
    // a one line answer into a hunt. A verbose flag that is selective
    // is a flag that hides the thing you turned it on for.
    auto* log = Common::Log::LogManager::GetInstance();
    log->SetConfigLogLevel(Common::Log::LogLevel::LINFO);
    for (int type = 0; type < static_cast<int>(Common::Log::LogType::NUMBER_OF_LOGS); ++type)
      log->SetEnable(static_cast<Common::Log::LogType>(type), true);
  }

  // Metal by name. Dolphin picks its backend from config and would
  // otherwise take whatever its default is on this platform, which after
  // ENABLE_VULKAN=OFF and the OpenGL context being excluded is not a
  // question worth leaving open.
  // Fully qualified, every one of them: this function takes a
  // CabinetDolphin::Config, which shadows Dolphin's own ::Config
  // namespace for the whole body.
  ::Config::SetBaseOrCurrent(::Config::MAIN_GFX_BACKEND, std::string("Metal"));
  ::Config::SetBaseOrCurrent(::Config::MAIN_DSP_HLE, true);
  ::Config::SetBaseOrCurrent(::Config::MAIN_CPU_THREAD, true);
  ::Config::SetBaseOrCurrent(::Config::MAIN_AUDIO_VOLUME, 100);
  // Named, not left to the default. GetDefaultSoundBackend answers
  // Cubeb when cubeb is valid, and this build has cubeb compiled out,
  // so the default falls through to "No Audio Output" and the config
  // literally selects silence. Cabinet's own stream answers for every
  // name except that one, so any other string reaches it; BACKEND_CUBEB
  // is used because it is the name this platform's config would already
  // hold from any earlier session.
  ::Config::SetBaseOrCurrent(::Config::MAIN_AUDIO_BACKEND, std::string(BACKEND_CUBEB));

  // Before the boot, so the game starts with whatever the panel last
  // held rather than Dolphin's defaults for the first few seconds.
  ApplyGraphics();

  // One memory card per game, in slot A, with slot B empty. Setting the
  // path alone is not enough: the slot has to be told it holds a card
  // at all, or Dolphin leaves the port empty and the game reports no
  // memory card with the file sitting right there. Dolphin creates the
  // file on first write.
  if (!config.memory_card.empty())
  {
    ::Config::SetBaseOrCurrent(::Config::MAIN_MEMCARD_A_PATH, config.memory_card);
    ::Config::SetBaseOrCurrent(::Config::MAIN_SLOT_A,
                               ExpansionInterface::EXIDeviceType::MemoryCard);
    ::Config::SetBaseOrCurrent(::Config::MAIN_SLOT_B, ExpansionInterface::EXIDeviceType::Dummy);
  }

  // Which PowerPC engine Dolphin actually chose, said out loud once per
  // boot. Dolphin defaults to its ARM64 recompiler here and there is no
  // reason to think otherwise, but "no reason to think otherwise" is
  // precisely how this project came to state for weeks that the Mac's
  // cores had their recompilers when three of them did not. Read what
  // it prints.
  const auto cpu_core = ::Config::Get(::Config::MAIN_CPU_CORE);
  fprintf(stderr, "[GC] cabinet: PowerPC engine = %d (0 interpreter, 1 x64 JIT, "
                  "4 ARM64 JIT, 5 cached interpreter)\n",
          static_cast<int>(cpu_core));

  WindowSystemInfo wsi;
  {
    std::lock_guard lock(s_surface_lock);
    // MacOS rather than Headless even though there is no NSWindow here.
    // Dolphin's Metal backend takes render_surface as a CAMetalLayer
    // directly, and its PrepareWindow, the only part that wants a real
    // NSView, is compiled out under Catalyst. So the layer goes in and
    // nothing asks for the window.
    wsi.type = s_surface_layer ? WindowSystemType::MacOS : WindowSystemType::Headless;
    wsi.render_window = s_surface_layer;
    wsi.render_surface = s_surface_layer;
    wsi.render_surface_scale = s_surface_scale;
  }

  UICommon::InitControllers(wsi);

  auto boot = BootParameters::GenerateFromFile(config.game_path);
  if (!boot)
  {
    if (error)
      *error = "could not read " + config.game_path;
    s_config_ready.store(false);
    UICommon::ShutdownControllers();
    UICommon::Shutdown();
    return false;
  }

  auto& system = Core::System::GetInstance();
  if (!BootManager::BootCore(system, std::move(boot), wsi))
  {
    if (error)
      *error = "Dolphin refused to boot " + config.game_path;
    s_config_ready.store(false);
    UICommon::ShutdownControllers();
    UICommon::Shutdown();
    return false;
  }

  // The host loop. Dolphin emulates on its own thread; all this does is
  // service the jobs the core hands back to the host and watch for the
  // end, either because Cabinet asked or because the core stopped by
  // itself. Ten milliseconds is well under any deadline here: nothing in
  // this loop is on the frame path.
  while (!s_stop_requested.load() && Core::IsRunningOrStarting(system))
  {
    Core::HostDispatchJobs(system);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  Core::Stop(system);
  Core::Shutdown(system);
  s_config_ready.store(false);
  UICommon::ShutdownControllers();
  UICommon::Shutdown();
  return true;
}

}  // namespace CabinetDolphin

// The seat patched into Core/HW/GCPad.cpp. Every emulated GameCube
// controller port reads through Pad::GetStatus, so this is the one
// place Cabinet's input has to arrive. Returning false leaves Dolphin
// on its own controller stack, which is what happens before Swift has
// pushed anything.
bool CabinetGetGCPadStatus(int pad_num, GCPadStatus* out)
{
  if (pad_num < 0 || pad_num >= 4 || !out)
    return false;

  CabinetDolphin::PadState state;
  {
    std::lock_guard lock(s_pad_lock);
    if (!s_pads_active)
      return false;
    state = s_pads[pad_num];
  }

  *out = GCPadStatus{};
  out->button = state.buttons;
  out->stickX = state.stick_x;
  out->stickY = state.stick_y;
  out->substickX = state.substick_x;
  out->substickY = state.substick_y;
  out->triggerLeft = state.trigger_left;
  out->triggerRight = state.trigger_right;
  out->isConnected = state.connected;
  // Dolphin expects the origin bit on a real pad's first reports, and
  // some titles poll for it before they will accept any input at all.
  out->button |= PAD_USE_ORIGIN;
  return true;
}

// ---------------------------------------------------------------------
// The Host_ surface. Dolphin calls in here; Cabinet answers.
//
// The window questions all answer the same way and that is correct
// rather than lazy: the render surface is a full-screen view that only
// exists while a game is running, so it always has focus and is always
// fullscreen from the emulator's point of view. Getting these wrong the
// other way costs input: Dolphin suppresses controller state when it
// believes the UI has focus.
// ---------------------------------------------------------------------

std::vector<std::string> Host_GetPreferredLocales()
{
  return {};
}

bool Host_UIBlocksControllerState()
{
  return false;
}

bool Host_RendererHasFocus()
{
  return true;
}

bool Host_RendererHasFullFocus()
{
  return true;
}

bool Host_RendererIsFullscreen()
{
  return true;
}

bool Host_TASInputHasFocus()
{
  return false;
}

void Host_Message(HostMessageID id)
{
  if (id == HostMessageID::WMUserStop)
    CabinetDolphin::RequestStop();
}

void Host_PPCSymbolsChanged()
{
}

void Host_PPCBreakpointsChanged()
{
}

void Host_RequestRenderWindowSize(int width, int height)
{
  // A game asking to resize the window. Cabinet's surface is whatever
  // size the view is, and the view is the whole screen, so this is
  // ignored on purpose rather than by omission.
  (void)width;
  (void)height;
}

void Host_UpdateDisasmDialog()
{
}

void Host_JitCacheInvalidation()
{
}

void Host_JitProfileDataWiped()
{
}

void Host_UpdateTitle(const std::string& title)
{
  (void)title;
}

void Host_YieldToUI()
{
}

void Host_TitleChanged()
{
}

void Host_UpdateDiscordClientID(const std::string& client_id)
{
  (void)client_id;
}

bool Host_UpdateDiscordPresenceRaw(const std::string& details, const std::string& state,
                                   const std::string& large_image_key,
                                   const std::string& large_image_text,
                                   const std::string& small_image_key,
                                   const std::string& small_image_text,
                                   const int64_t start_timestamp, const int64_t end_timestamp,
                                   const int party_size, const int party_max)
{
  (void)details;
  (void)state;
  (void)large_image_key;
  (void)large_image_text;
  (void)small_image_key;
  (void)small_image_text;
  (void)start_timestamp;
  (void)end_timestamp;
  (void)party_size;
  (void)party_max;
  return false;
}

std::unique_ptr<GBAHostInterface> Host_CreateGBAHost(std::weak_ptr<HW::GBA::Core> core)
{
  // USE_MGBA is off, so nothing reaches this. It still has to exist:
  // the declaration is unconditional in Host.h.
  (void)core;
  return nullptr;
}
