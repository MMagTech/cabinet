// A headless PS2 boot, for answering one question before any UI exists:
// do the ARM64 recompilers actually run inside a Mac Catalyst process?
//
// PCSX2 compiling for Catalyst says nothing about that. Flycast
// compiled for this target too, and then crashed on every launch
// because its JIT memory went down the iOS path macOS refuses. The
// recompilers are the whole reason PS2 is possible on this machine, so
// they get proven before anything is built on top of them.
//
// This links the same library and the same host layer the app will,
// which is the other half of its value: a static library never tells
// you a host function is missing, and a linked executable does.
//
// Built by tools/build-pcsx2-mac.sh, needs the JIT entitlement:
//
//   codesign -f -s - --entitlements <ent> cabinet-ps2-smoke
//   ./cabinet-ps2-smoke <disc> <data-root> <resources> [seconds]

#include <CoreFoundation/CoreFoundation.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>

#include "CabinetPS2Host.h"

int main(int argc, char* argv[])
{
	if (argc < 4)
	{
		std::fprintf(stderr, "usage: %s <disc> <data-root> <resources> [seconds]\n", argv[0]);
		return 2;
	}

	CabinetPS2::Config config;
	config.disc_path = argv[1];
	config.data_root = argv[2];
	config.resources_dir = argv[3];
	config.view = nullptr;
	config.fast_boot = true;
	config.verbose_log = true;

	const int seconds = (argc > 4) ? std::atoi(argv[4]) : 30;

	// Uncapped by default, because a capped run reports 100% speed
	// whether there is four times the headroom or none at all. Pass
	// "capped" to pace it to 60Hz instead, which makes EE load the
	// headroom figure and is directly comparable to the spike numbers.
	config.unlimited = !(argc > 5 && std::string(argv[5]) == "capped");

	std::string error;
	bool ok = false;
	float peak_ee = 0.0f;
	float peak_gs = 0.0f;

	std::thread vm([&] {
		ok = CabinetPS2::Run(config, &error);
		CFRunLoopStop(CFRunLoopGetMain());
	});

	std::thread sampler([&] {
		for (int i = 0; i < seconds * 2; i++)
		{
			std::this_thread::sleep_for(std::chrono::milliseconds(500));
			if (!CabinetPS2::IsRunning())
				continue;

			const CabinetPS2::Metrics m = CabinetPS2::GetMetrics();
			peak_ee = std::max(peak_ee, m.ee_usage);
			peak_gs = std::max(peak_gs, m.gs_usage);
			std::printf("SMOKE t=%5.1fs fps=%6.2f speed=%6.1f%% ee=%5.1f%% gs=%5.1f%%\n",
				(i + 1) * 0.5f, m.fps, m.speed, m.ee_usage, m.gs_usage);
			std::fflush(stdout);
		}
		CabinetPS2::RequestStop();
	});

	// PCSX2 hops to the main queue while it sets Metal up, so the main
	// thread has to be running a run loop rather than sitting in a
	// sleep. Without this it deadlocks inside GS init, before printing
	// anything. The app does not have this problem: UIApplication is
	// already running one.
	CFRunLoopRun();

	sampler.join();
	vm.join();

	if (!ok)
	{
		std::fprintf(stderr, "SMOKE FAILED: %s\n", error.c_str());
		return 1;
	}

	std::printf("SMOKE done, peak ee=%.1f%% gs=%.1f%%\n", peak_ee, peak_gs);
	return 0;
}
