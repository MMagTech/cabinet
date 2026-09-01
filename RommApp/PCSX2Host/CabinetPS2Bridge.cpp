// Implements the flat C face declared in
// RommApp/RommAppMac/PCSX2/CabinetPS2Bridge.h. Compiled into
// libpcsx2_mac.a, because everything it calls is C++ that only exists
// inside that build.

#include "../RommAppMac/PCSX2/CabinetPS2Bridge.h"

#include <cstring>
#include <string>

#include "CabinetPS2Host.h"

#include "pcsx2/SIO/Pad/Pad.h"
#include "pcsx2/VMManager.h"
#include "pcsx2/Host.h"
#include "pcsx2/GS.h"
#include "pcsx2/MTGS.h"

bool CabinetPS2Run(const CabinetPS2Config* config, char* error, size_t error_length)
{
	CabinetPS2::Config cfg;
	cfg.disc_path = config->disc_path ? config->disc_path : "";
	cfg.data_root = config->data_root ? config->data_root : "";
	cfg.resources_dir = config->resources_dir ? config->resources_dir : "";
	cfg.memory_card = config->memory_card ? config->memory_card : "";
	cfg.view = config->view;
	cfg.fast_boot = config->fast_boot;
	cfg.verbose_log = config->verbose_log;
	cfg.unlimited = false;

	std::string message;
	const bool ok = CabinetPS2::Run(cfg, &message);

	if (!ok && error && error_length > 0)
	{
		std::strncpy(error, message.c_str(), error_length - 1);
		error[error_length - 1] = '\0';
	}
	return ok;
}

void CabinetPS2RequestStop(void)
{
	CabinetPS2::RequestStop();
}

bool CabinetPS2IsRunning(void)
{
	return CabinetPS2::IsRunning();
}

CabinetPS2Metrics CabinetPS2GetMetrics(void)
{
	const CabinetPS2::Metrics m = CabinetPS2::GetMetrics();
	CabinetPS2Metrics out;
	out.fps = m.fps;
	out.speed = m.speed;
	out.ee_usage = m.ee_usage;
	out.gs_usage = m.gs_usage;
	return out;
}

void CabinetPS2SetButton(unsigned int pad, unsigned int button, float value)
{
	// Straight to the pad rather than through InputManager. The
	// InputManager route would mean matching PCSX2's binding strings
	// and SDL's button numbering, neither of which exists in this
	// build, to arrive at the same call.
	if (!CabinetPS2::IsRunning())
		return;

	Pad::SetControllerState(pad, button, value);
}

void CabinetPS2SetSurfaceSize(unsigned int width, unsigned int height, float scale)
{
	CabinetPS2::SetSurfaceSize(width, height, scale);
}

void CabinetPS2SetPaused(bool paused)
{
	if (!CabinetPS2::IsRunning())
		return;

	VMManager::SetPaused(paused);
}

bool CabinetPS2SaveStateToSlot(int slot)
{
	if (!CabinetPS2::IsRunning())
		return false;

	bool ok = true;
	Host::RunOnCPUThread([slot, &ok] {
		VMManager::SaveStateToSlot(slot, true, [&ok](const std::string& error) { ok = false; });
	}, true);
	return ok;
}

bool CabinetPS2LoadStateFromSlot(int slot)
{
	if (!CabinetPS2::IsRunning())
		return false;

	bool ok = false;
	Host::RunOnCPUThread([slot, &ok] { ok = VMManager::LoadStateFromSlot(slot); }, true);
	return ok;
}

bool CabinetPS2HasStateInSlot(int slot)
{
	if (!CabinetPS2::IsRunning())
		return false;

	return VMManager::HasSaveStateInSlot(VMManager::GetDiscSerial().c_str(), VMManager::GetDiscCRC(), slot);
}

void CabinetPS2SetGraphics(const CabinetPS2Graphics* graphics)
{
	CabinetPS2::Graphics g;
	g.tv_shader = graphics->tv_shader;
	g.aspect = graphics->aspect ? graphics->aspect : "";
	g.blending = graphics->blending;
	g.upscale = graphics->upscale;
	g.renderer = graphics->renderer;
	g.deinterlace = graphics->deinterlace;
	CabinetPS2::SetGraphics(g);
}

void CabinetPS2Screenshot(const char* path)
{
	if (!CabinetPS2::IsRunning() || !path)
		return;

	GSQueueSnapshot(std::string(path), 0);
}

void CabinetPS2ResizeDisplay(unsigned int width, unsigned int height, float scale)
{
	if (!CabinetPS2::IsRunning() || !MTGS::IsOpen())
		return;

	CabinetPS2::SetSurfaceSize(width, height, scale);
	MTGS::ResizeDisplayWindow(width, height, scale);
}
