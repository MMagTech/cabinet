// The Host namespace, answered for Cabinet. See CabinetPS2Host.h.
//
// Most of this is deliberately empty. PCSX2 calls out for a great many
// things a desktop frontend owns and Cabinet either owns elsewhere or
// does not have at all: clipboards, URLs, file pickers, game list
// refreshes, achievements, big picture mode. An empty body is the
// honest answer for those, and is what upstream's own headless
// frontend does too.
//
// The parts that are not empty are the ones that matter: settings,
// which are held in memory rather than an ini, the render window,
// which comes from Cabinet's view, and the VM lifecycle.

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <thread>

#include "fmt/format.h"

#include "common/Assertions.h"
#include "common/Console.h"
#include "common/Error.h"
#include "common/FileSystem.h"
#include <span>
#include "common/MemorySettingsInterface.h"
#include "common/Path.h"
#include "common/ProgressCallback.h"
#include "common/WindowInfo.h"

#include "pcsx2/Achievements.h"
#include "pcsx2/GS.h"
#include "pcsx2/Host.h"
#include "pcsx2/ImGui/FullscreenUI.h"
#include "pcsx2/ImGui/ImGuiFullscreen.h"
#include "pcsx2/ImGui/ImGuiManager.h"
#include "pcsx2/Input/InputManager.h"
#include "pcsx2/MTGS.h"
#include "pcsx2/PerformanceMetrics.h"
#include "pcsx2/ps2/BiosTools.h"
#include "pcsx2/VMManager.h"

#include "CabinetPS2Host.h"

namespace
{
	MemorySettingsInterface s_settings;

	// Held for the life of the process because ImGuiManager keeps a
	// span over it rather than copying. Memory mapped, as upstream's
	// own frontend does it.
	std::span<const u8> s_font_data;

	std::mutex s_state_lock;

	// Work handed to the emulation thread. PCSX2 requires anything that
	// touches VM state, save states and disc swaps among them, to run
	// there rather than on whichever thread asked.
	std::mutex s_cpu_queue_lock;
	std::condition_variable s_cpu_queue_done;
	std::deque<std::function<void()>> s_cpu_queue;
	u64 s_cpu_queue_completed = 0;
	u64 s_cpu_queue_submitted = 0;
	std::atomic_bool s_running{false};
	std::atomic_bool s_stop_requested{false};

	// The view Cabinet gave us, and the surface size the renderer asks
	// about. Read on the GS thread, written on the main thread.
	std::atomic<void*> s_view{nullptr};
	/// A CAMetalLayer Cabinet made itself, or null to use the view's
	/// own backing layer. Exists to A/B the two.
	std::atomic<void*> s_layer{nullptr};
	std::atomic<u32> s_surface_width{0};
	std::atomic<u32> s_surface_height{0};
	std::atomic<float> s_surface_scale{1.0f};

	// Held rather than only written into the settings, because
	// ApplyDefaults runs SetDefaultSettings on every boot and that
	// overwrites anything put there beforehand. Kept here, it can be
	// re-applied after the defaults land.
	std::mutex s_graphics_lock;
	CabinetPS2::Graphics s_graphics;

	std::optional<WindowInfo> CabinetWindowInfo()
	{
		void* const view = s_view.load(std::memory_order_acquire);
		WindowInfo wi;
		if (!view)
		{
			// Surfaceless is a real mode in PCSX2, not a failure: the
			// GS runs and draws nothing. It is what lets the smoke test
			// measure the recompilers with no window at all.
			wi.type = WindowInfo::Type::Surfaceless;
			return wi;
		}

		wi.type = WindowInfo::Type::MacOS;
		wi.window_handle = view;
		wi.surface_handle = s_layer.load(std::memory_order_acquire);
		wi.surface_width = s_surface_width.load(std::memory_order_relaxed);
		wi.surface_height = s_surface_height.load(std::memory_order_relaxed);
		wi.surface_scale = s_surface_scale.load(std::memory_order_relaxed);
		return wi;
	}
} // namespace

// Whether PCSX2 draws its own on-screen messages. Always false: they
// are its frontend's voice, and Cabinet has its own.
bool CabinetShowOSDMessages()
{
	return false;
}

// MARK: - Settings

void Host::CommitBaseSettingChanges()
{
	// Held in memory. Cabinet persists what it cares about itself.
}

void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock)
{
}

void Host::CheckForSettingsChanges(const Pcsx2Config& old_config)
{
}

bool Host::RequestResetSettings(bool folders, bool core, bool controllers, bool hotkeys, bool ui)
{
	return false;
}

void Host::SetDefaultUISettings(SettingsInterface& si)
{
}

bool Host::LocaleCircleConfirm()
{
	return false;
}

std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback()
{
	return ProgressCallback::CreateNullProgressCallback();
}

// MARK: - Messages

void Host::ReportInfoAsync(const std::string_view title, const std::string_view message)
{
	if (!title.empty() && !message.empty())
		Console.WriteLnFmt("[PS2] {}: {}", title, message);
	else if (!message.empty())
		Console.WriteLnFmt("[PS2] {}", message);
}

void Host::ReportErrorAsync(const std::string_view title, const std::string_view message)
{
	if (!title.empty() && !message.empty())
		Console.ErrorFmt("[PS2] {}: {}", title, message);
	else if (!message.empty())
		Console.ErrorFmt("[PS2] {}", message);
}

void Host::OpenURL(const std::string_view url)
{
}

bool Host::CopyTextToClipboard(const std::string_view text)
{
	return false;
}

std::string Host::GetTextFromClipboard()
{
	return {};
}

void Host::BeginTextInput()
{
}

void Host::EndTextInput()
{
}

// MARK: - Window

std::optional<WindowInfo> Host::GetTopLevelWindowInfo()
{
	return CabinetWindowInfo();
}

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window)
{
	const std::optional<WindowInfo> wi = CabinetWindowInfo();
	// Logged because a zero here is invisible in every other way: the
	// emulator runs, the frame counter reads 60, and the display stays
	// black. It cost a debugging round the first time.
	Console.WriteLnFmt("[PS2] Render surface: {}x{} at {}x scale.",
		wi->surface_width, wi->surface_height, wi->surface_scale);
	return wi;
}

void Host::ReleaseRenderWindow()
{
}

void Host::BeginPresentFrame()
{
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
}

bool Host::IsFullscreen()
{
	// Cabinet's player is always the whole surface it was given, so
	// there is no windowed state for PCSX2 to toggle out of.
	return true;
}

void Host::SetFullscreen(bool enabled)
{
}

// MARK: - Input

void Host::OnInputDeviceConnected(const std::string_view identifier, const std::string_view device_name)
{
}

void Host::OnInputDeviceDisconnected(const InputBindingKey key, const std::string_view identifier)
{
}

void Host::SetMouseMode(bool relative_mode, bool hide_cursor)
{
}

void Host::SetMouseLock(bool state)
{
}

// MARK: - VM lifecycle

void Host::OnVMStarting()
{
}

void Host::OnVMStarted()
{
}

void Host::OnVMDestroyed()
{
}

void Host::OnVMPaused()
{
}

void Host::OnVMResumed()
{
}

void Host::OnGameChanged(const std::string& title, const std::string& elf_override, const std::string& disc_path,
	const std::string& disc_serial, u32 disc_crc, u32 current_crc)
{
	Console.WriteLnFmt("[PS2] Game: {} ({})", title, disc_serial);
}

void Host::OnPerformanceMetricsUpdated()
{
}

void Host::OnSaveStateLoading(const std::string_view filename)
{
}

void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful)
{
}

void Host::OnSaveStateSaved(const std::string_view filename)
{
}

void Host::OnCaptureStarted(const std::string& filename)
{
}

void Host::OnCaptureStopped()
{
}

void Host::RequestExitApplication(bool allow_confirm)
{
	CabinetPS2::RequestStop();
}

void Host::RequestExitBigPicture()
{
}

void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state)
{
	CabinetPS2::RequestStop();
}

// MARK: - Threading

void Host::RunOnCPUThread(std::function<void()> function, bool block /* = false */)
{
	u64 ticket;
	{
		std::unique_lock lock(s_cpu_queue_lock);
		s_cpu_queue.push_back(std::move(function));
		ticket = ++s_cpu_queue_submitted;
	}

	if (!block)
		return;

	// The caller is not the emulation thread, by construction: if it
	// were, waiting here would deadlock against the drain below.
	std::unique_lock lock(s_cpu_queue_lock);
	s_cpu_queue_done.wait(lock, [ticket] { return s_cpu_queue_completed >= ticket; });
}

void Host::PumpMessagesOnCPUThread()
{
	for (;;)
	{
		std::function<void()> work;
		{
			std::unique_lock lock(s_cpu_queue_lock);
			if (s_cpu_queue.empty())
				return;

			work = std::move(s_cpu_queue.front());
			s_cpu_queue.pop_front();
		}

		// Run it outside the lock, since anything queued here is free
		// to queue more work of its own.
		work();

		{
			std::unique_lock lock(s_cpu_queue_lock);
			s_cpu_queue_completed++;
		}
		s_cpu_queue_done.notify_all();
	}
}

// MARK: - Things Cabinet has no version of

void Host::RefreshGameListAsync(bool invalidate_cache)
{
}

void Host::CancelGameListRefresh()
{
}

void Host::OnAchievementsLoginSuccess(const char* username, u32 points, u32 sc_points, u32 unread_messages)
{
}

void Host::OnAchievementsLoginRequested(Achievements::LoginRequestReason reason)
{
}

void Host::OnAchievementsHardcoreModeChanged(bool enabled)
{
}

void Host::OnAchievementsRefreshed()
{
}

bool Host::InBatchMode()
{
	return false;
}

bool Host::InNoGUIMode()
{
	return false;
}

bool Host::ShouldPreferHostFileSelector()
{
	return false;
}

void Host::OpenHostFileSelectorAsync(std::string_view title, bool select_directory, FileSelectorCallback callback,
	FileSelectorFilters filters, std::string_view initial_directory)
{
	callback(std::string());
}

// MARK: - Localisation

int Host::LocaleSensitiveCompare(std::string_view lhs, std::string_view rhs)
{
	const int res = std::strncmp(lhs.data(), rhs.data(), std::min(lhs.size(), rhs.size()));
	if (res != 0)
		return res;
	if (lhs.size() < rhs.size())
		return -1;
	if (lhs.size() > rhs.size())
		return 1;
	return 0;
}

s32 Host::Internal::GetTranslatedStringImpl(
	const std::string_view context, const std::string_view msg, char* tbuf, size_t tbuf_space)
{
	if (msg.size() > tbuf_space)
		return -1;
	if (msg.empty())
		return 0;

	std::memcpy(tbuf, msg.data(), msg.size());
	return static_cast<s32>(msg.size());
}

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
	// PCSX2's own minimal substitution: %n becomes the count.
	const std::string count_str = fmt::format("{}", count);
	std::string ret(msg);
	for (;;)
	{
		const std::string::size_type pos = ret.find("%n");
		if (pos == std::string::npos)
			break;
		ret.replace(pos, 2, count_str);
	}
	return ret;
}


// MARK: - Input tables the frontend is expected to define

// PCSX2 splits its hotkeys into three tables and expects the frontend
// to supply the third. Cabinet's pause menu is its own, on every core,
// so this one stays empty rather than binding keys nothing will press.
BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()

// A keyboard is never a game controller in Cabinet, on any platform.
// That is a settled decision rather than a gap, so these answer
// honestly instead of mapping anything.
std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view str)
{
	return std::nullopt;
}

std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code)
{
	return std::nullopt;
}

const char* InputManager::ConvertHostKeyboardCodeToIcon(u32 code)
{
	return nullptr;
}

// MARK: - Cabinet's side

namespace CabinetPS2
{
	/// Writes whatever Cabinet last chose into the settings layer.
	/// Called both when a setting changes and after every boot's
	/// defaults, since those would otherwise erase it.
	static void WriteGraphicsSettings()
	{
		std::unique_lock lock(s_graphics_lock);
		s_settings.SetIntValue("EmuCore/GS", "TVShader", s_graphics.tv_shader);
		if (!s_graphics.aspect.empty())
			s_settings.SetStringValue("EmuCore/GS", "AspectRatio", s_graphics.aspect.c_str());
		s_settings.SetIntValue("EmuCore/GS", "accurate_blending_unit", s_graphics.blending);
		s_settings.SetFloatValue("EmuCore/GS", "upscale_multiplier", s_graphics.upscale);

	}

	static void ApplyDefaults(const Config& config)
	{
		Host::Internal::SetBaseSettingsLayer(&s_settings);
		VMManager::SetDefaultSettings(s_settings, true, true, true, true, true);

		// The recompilers are the entire reason PS2 is possible on this
		// machine, and PCSX2's defaults do not turn all of them on. An
		// absent "Recompiler is not enabled" in the boot log is what
		// confirms these took; never assume it from this code.
		s_settings.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
		s_settings.SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);
		s_settings.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
		s_settings.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);

		// Metal, or nothing at all when Cabinet gave us no view.
		{
			std::unique_lock lock(s_graphics_lock);
			const int forced = s_graphics.renderer;
			s_settings.SetIntValue("EmuCore/GS", "Renderer",
				forced >= 0 ? forced
							: (config.view ? static_cast<int>(GSRendererType::Metal)
										   : static_cast<int>(GSRendererType::Null)));
		}

		// Cubeb by name only. Neither of PCSX2's own backends exists
		// in this build, so both names resolve to Cabinet's
		// AVAudioEngine stream; naming the one PCSX2 defaults to keeps
		// the setting readable if it is ever written out.
		s_settings.SetStringValue("SPU2/Output", "Backend", "Cubeb");

		// Logging has to be asked for through the settings rather than
		// Log::SetConsoleOutputLevel. Both LoadStartupSettings and
		// ApplySettings rebuild the log sinks from these keys, so a
		// direct call gets silently undone, twice, and takes PCSX2's
		// own diagnostics with it.
		s_settings.SetBoolValue("Logging", "EnableSystemConsole", config.verbose_log);
		// On, and deliberately. It costs a file in the PS2 folder and
		// buys the difference between "the screen went black" and a
		// readable account of what the renderer did. A black picture
		// with working audio is invisible to every other diagnostic:
		// the frame counter still reads 60 and the screenshot still
		// shows a picture, because both sit upstream of presentation.
		s_settings.SetBoolValue("Logging", "EnableFileLogging", true);

		// Every on-screen readout off. Cabinet shows what it wants to
		// show; a permanent frame counter belongs in a bench harness,
		// not over a game somebody is playing.
		for (const char* key : {"OsdShowSpeed", "OsdShowFPS", "OsdShowVPS", "OsdShowResolution",
				 "OsdShowGSStats", "OsdShowCPU", "OsdShowGPU", "OsdShowGPUStats", "OsdShowIndicators",
				 "OsdShowFrameTimes", "OsdShowHardwareInfo", "OsdShowVersion", "OsdShowSettings",
				 "OsdShowInputs", "OsdShowVideoCapture", "OsdShowInputRec", "OsdShowTextureReplacements"})
		{
			s_settings.SetBoolValue("EmuCore/GS", key, false);
		}

		// PCSX2 defaults this on: it decides a frame is a duplicate of
		// the last and declines to present it. The detection depends on
		// signals that do not fire reliably here, so it threw away
		// nearly every frame and let one through only when it hit its
		// own skip limit, which is exactly the black picture with an
		// occasional flash. The frames themselves were always perfect.
		//
		// It saves a little GPU work on a machine that has plenty.
		s_settings.SetBoolValue("EmuCore/GS", "SkipDuplicateFrames", false);

		// One card per game, in slot 1. PCSX2's own default is a single
		// shared Mcd001.ps2 for the whole library, which is what a real
		// PS2 had and what RomM cannot file against a rom.
		if (!config.memory_card.empty())
		{
			s_settings.SetBoolValue("MemoryCards", "Slot1_Enable", true);
			s_settings.SetStringValue("MemoryCards", "Slot1_Filename", config.memory_card.c_str());
			// Slot 2 stays off. A second card no game is told about
			// only creates a second thing to sync.
			s_settings.SetBoolValue("MemoryCards", "Slot2_Enable", false);
		}

		WriteGraphicsSettings();

		VMManager::Internal::LoadStartupSettings();
	}

	/// The name, not the path, of the first file in the BIOS folder
	/// PCSX2 recognises. Empty when there is none.
	static std::string FindBios()
	{
		FileSystem::FindResultsArray files;
		FileSystem::FindFiles(EmuFolders::Bios.c_str(), "*",
			FILESYSTEM_FIND_FILES | FILESYSTEM_FIND_RELATIVE_PATHS, &files);

		for (const FILESYSTEM_FIND_DATA& file : files)
		{
			// IsBIOS parses the ROM header, which is the check that
			// matters. IsBIOSAvailable only asks whether a file exists,
			// and happily accepts the .nvm and .mec companions that sit
			// beside a real BIOS image.
			u32 version = 0;
			u32 region = 0;
			std::string description;
			std::string zone;
			const std::string path = Path::Combine(EmuFolders::Bios, file.FileName);
			if (IsBIOS(path.c_str(), version, description, region, zone))
			{
				Console.WriteLnFmt("[PS2] BIOS: {} ({})", file.FileName, description);
				return file.FileName;
			}
		}
		return {};
	}

	bool Run(const Config& config, std::string* error)
	{
		const auto fail = [error](std::string message) {
			if (error)
				*error = std::move(message);
			return false;
		};

		{
			std::unique_lock lock(s_state_lock);
			if (s_running.load())
				return fail("A PS2 game is already running.");
			s_stop_requested.store(false);
		}

		s_view.store(config.view, std::memory_order_release);

		// Order matters and is easy to get backwards. PCSX2's own
		// setters overwrite these three, so Cabinet's paths go in
		// after them and before SetDefaultSettings, which is what
		// derives every other folder from DataRoot.
		EmuFolders::SetAppRoot();
		EmuFolders::SetResourcesDirectory();
		if (!EmuFolders::SetDataDirectory(nullptr))
			return fail("Could not set up the PS2 data directory.");

		EmuFolders::DataRoot = config.data_root;
		if (!config.resources_dir.empty())
		{
			if (!FileSystem::DirectoryExists(config.resources_dir.c_str()))
				return fail("No PCSX2 resources at " + config.resources_dir);
			EmuFolders::Resources = config.resources_dir;
		}

		// ImGui draws PCSX2's on-screen display, and GS refuses to open
		// if it cannot build a font atlas. Nothing in Cabinet's player
		// shows that OSD, but the dependency is not optional: no font,
		// no renderer, no game.
		{
			const std::string font_path =
				EmuFolders::GetOverridableResourcePath("fonts" FS_OSPATH_SEPARATOR_STR "Roboto-Regular.ttf");
			s_font_data = FileSystem::MapBinaryFileForRead(font_path.c_str());
			if (s_font_data.empty())
				return fail("Could not read the PS2 interface font at " + font_path);

			ImGuiManager::FontInfo font{};
			font.data = s_font_data;
			font.exclude_ranges = {};
			font.face_name = nullptr;
			font.is_emoji_font = false;
			ImGuiManager::SetFonts({font});
		}

		const char* hardware_error = nullptr;
		if (!VMManager::PerformEarlyHardwareChecks(&hardware_error))
			return fail(hardware_error ? hardware_error : "This machine cannot run PCSX2.");

		ApplyDefaults(config);

		if (!EmuFolders::EnsureFoldersExist())
			return fail("Could not create the PS2 data folders.");

		// PCSX2 will not boot without being told which BIOS to use, and
		// there is no sensible default: Cabinet gets whatever file RomM
		// holds, whose name it does not control. So pick the first file
		// in the BIOS folder that PCSX2 itself accepts, rather than
		// matching on a name.
		const std::string bios = FindBios();
		if (bios.empty())
			return fail("No usable PS2 BIOS in " + EmuFolders::Bios);

		s_settings.SetStringValue("Filenames", "BIOS", bios.c_str());

		if (!VMManager::Internal::CPUThreadInitialize())
			return fail("PCSX2 failed to initialise its CPU thread.");

		VMManager::ApplySettings();

		// Logged here, after LoadStartupSettings, and not where the
		// settings are written: logging is itself configured by that
		// call, so anything reported earlier is silently dropped. A
		// setting that fails to arrive and one that arrives and does
		// nothing look identical without this.
		{
			std::unique_lock lock(s_graphics_lock);
			Console.WriteLnFmt("[PS2] Graphics: shader {}, aspect {}, blending {}, upscale {}x",
				s_graphics.tv_shader, s_graphics.aspect, s_graphics.blending, s_graphics.upscale);
		}

		VMBootParameters params;
		params.filename = config.disc_path;
		params.fast_boot = config.fast_boot;

		Error boot_error;
		if (VMManager::Initialize(params, &boot_error) != VMBootResult::StartupSuccess)
		{
			VMManager::Internal::CPUThreadShutdown();
			const std::string description = boot_error.GetDescription();
			return fail(description.empty() ? "PCSX2 could not boot the disc." : description);
		}

		if (config.unlimited)
			VMManager::SetLimiterMode(LimiterModeType::Unlimited);

		s_running.store(true);
		VMManager::SetState(VMState::Running);

		// Paused is a state to sit in, NOT a reason to leave the loop.
		// Treating it as one shut the emulator down the instant the
		// pause panel opened: black picture, an audio tail, and a menu
		// drawn over a VM that no longer existed.
		//
		// The queue has to keep draining while paused too, or anything
		// asking for blocking work from another thread, which is what
		// save and load do, waits forever on a thread that has stopped
		// collecting.
		for (;;)
		{
			const VMState state = VMManager::GetState();
			if (s_stop_requested.load() || state == VMState::Stopping || state == VMState::Shutdown)
				break;

			if (state == VMState::Paused)
			{
				Host::PumpMessagesOnCPUThread();
				VMManager::IdlePollUpdate();
				// Long enough not to spin a core doing nothing, short
				// enough that a menu press still feels immediate.
				std::this_thread::sleep_for(std::chrono::milliseconds(8));
				continue;
			}

			Host::PumpMessagesOnCPUThread();
			VMManager::Execute();
		}

		VMManager::Shutdown(false);
		VMManager::Internal::CPUThreadShutdown();
		s_running.store(false);
		s_view.store(nullptr, std::memory_order_release);
		return true;
	}

	void SetGraphics(const Graphics& graphics)
	{
		{
			std::unique_lock lock(s_graphics_lock);
			s_graphics = graphics;
		}
		WriteGraphicsSettings();

		// PCSX2 re-reads its graphics config as a whole, on its own
		// thread. Not blocking: a person changing a setting should see
		// the panel stay responsive, and the picture catches up a frame
		// later.
		if (s_running.load())
			Host::RunOnCPUThread([] { VMManager::ApplySettings(); }, false);
	}

	void SetSurfaceLayer(void* layer)
	{
		s_layer.store(layer, std::memory_order_release);
	}

	void SetSurfaceSize(unsigned int width, unsigned int height, float scale)
	{
		s_surface_width.store(width, std::memory_order_relaxed);
		s_surface_height.store(height, std::memory_order_relaxed);
		s_surface_scale.store(scale, std::memory_order_relaxed);
	}

	void RequestStop()
	{
		s_stop_requested.store(true);
		if (s_running.load())
			VMManager::SetState(VMState::Stopping);
	}

	bool IsRunning()
	{
		return s_running.load();
	}

	Metrics GetMetrics()
	{
		if (!s_running.load())
			return {};

		Metrics m;
		m.fps = PerformanceMetrics::GetFPS();
		m.speed = PerformanceMetrics::GetSpeed();
		m.ee_usage = PerformanceMetrics::GetCPUThreadUsage();
		m.gs_usage = PerformanceMetrics::GetGSThreadUsage();
		return m;
	}
} // namespace CabinetPS2
