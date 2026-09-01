// Cabinet's host layer for PCSX2.
//
// PCSX2 is not a libretro core and has no retro_run. It is a whole
// emulator that expects a frontend to exist around it: it calls out
// through the Host namespace for its settings, its window, its
// lifecycle events and its messages, and upstream has exactly two
// implementations of that, the Qt desktop app and the headless
// gsrunner. Neither can run inside Cabinet, so this is the third.
//
// Everything in the Host namespace is answered in CabinetPS2Host.cpp.
// This header is the far smaller surface pointing the other way: what
// Cabinet calls to start a game and watch it run.
//
// THREADING: Run blocks for the entire life of the game and must be
// given its own thread. PCSX2 starts its own GS thread underneath.
// RequestStop is safe from any thread, and is the only way out.

#pragma once

#include <string>

namespace CabinetPS2
{
	struct Config
	{
		/// The disc image. CHD, ISO and the other formats CDVD knows.
		std::string disc_path;

		/// Where BIOS, memory cards, save states and the cache live.
		/// Cabinet lays this out, PCSX2 only reads it.
		std::string data_root;

		/// PCSX2's own resources folder, bundled with the app. It holds
		/// the game database, the GS shaders and the fonts, and startup
		/// fails without it rather than degrading.
		std::string resources_dir;

		/// The memory card file for this game, a bare filename that
		/// PCSX2 resolves inside its memcards folder. Empty keeps
		/// PCSX2's shared card.
		std::string memory_card;

		/// A UIView whose +layerClass is CAMetalLayer. Null renders
		/// nothing at all, which is what the smoke test uses.
		void* view = nullptr;

		/// Skips the BIOS splash. On by default, as every frontend does.
		bool fast_boot = true;

		/// Prints PCSX2's own log. It is the only way to answer
		/// questions like whether the recompilers took, so it is worth
		/// having rather than guessing from behaviour.
		bool verbose_log = false;

		/// Runs as fast as it can rather than pacing to 60Hz. For
		/// measurement only: it is what turns a speed reading into a
		/// headroom reading.
		bool unlimited = false;
	};

	/// Boots the disc and runs until RequestStop. Blocks. Returns false
	/// and fills error if the VM never started.
	bool Run(const Config& config, std::string* error);

	/// The picture settings, applied together. Safe before Run, in
	/// which case they are simply the settings the game starts with.
	struct Graphics
	{
		int tv_shader = 0;
		std::string aspect = "Auto 4:3/3:2";
		int blending = 1;
		float upscale = 1.0f;
	};

	void SetGraphics(const Graphics& graphics);

	/// The drawable size PCSX2 should render and present at. Safe
	/// before Run and while running.
	void SetSurfaceSize(unsigned int width, unsigned int height, float scale);

	/// Asks the running game to stop. Safe from any thread.
	void RequestStop();

	bool IsRunning();

	/// Live performance, all zero when nothing is running. EE and GS
	/// are thread loads as percentages, which is the honest headroom
	/// measure once speed is capped at 100.
	struct Metrics
	{
		float fps;
		float speed;
		float ee_usage;
		float gs_usage;
	};

	Metrics GetMetrics();
} // namespace CabinetPS2
