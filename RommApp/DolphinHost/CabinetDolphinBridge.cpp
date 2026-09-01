// The flat C implementation behind
// RommApp/RommAppMac/Dolphin/CabinetDolphinBridge.h.
//
// Nothing here does any work. It exists because Swift cannot see C++,
// and because the boundary is a good place to make the ownership of
// strings and errors explicit rather than leaving it to a comment.
//
// Compiled by tools/build-dolphin-mac.sh, never by Xcode.

#include "../RommAppMac/Dolphin/CabinetDolphinBridge.h"

#include <cstring>
#include <string>

#include "CabinetDolphinHost.h"

namespace
{
std::string ToString(const char* value)
{
	return value ? std::string(value) : std::string();
}
}  // namespace

extern "C" {

bool CabinetDolphinRun(const CabinetDolphinConfig* config, char* error, size_t error_length)
{
	if (!config)
		return false;

	CabinetDolphin::Config host;
	host.game_path = ToString(config->game_path);
	host.sys_dir = ToString(config->sys_dir);
	host.user_dir = ToString(config->user_dir);
	host.memory_card = ToString(config->memory_card);
	host.verbose_log = config->verbose_log;

	std::string message;
	const bool ok = CabinetDolphin::Run(host, &message);
	if (!ok && error && error_length > 0)
	{
		std::strncpy(error, message.c_str(), error_length - 1);
		error[error_length - 1] = '\0';
	}
	return ok;
}

void CabinetDolphinSetSurfaceLayer(void* layer)
{
	CabinetDolphin::SetSurfaceLayer(layer);
}

void CabinetDolphinSetSurfaceSize(int width, int height, float scale)
{
	CabinetDolphin::SetSurfaceSize(width, height, scale);
}

void CabinetDolphinSetPad(int port, const CabinetDolphinPad* pad)
{
	if (!pad)
		return;
	CabinetDolphin::PadState state;
	state.buttons = pad->buttons;
	state.stick_x = pad->stick_x;
	state.stick_y = pad->stick_y;
	state.substick_x = pad->substick_x;
	state.substick_y = pad->substick_y;
	state.trigger_left = pad->trigger_left;
	state.trigger_right = pad->trigger_right;
	state.connected = pad->connected;
	CabinetDolphin::SetPadState(port, state);
}

void CabinetDolphinSetPaused(bool paused)
{
	CabinetDolphin::SetPaused(paused);
}

void CabinetDolphinRequestStop(void)
{
	CabinetDolphin::RequestStop();
}

bool CabinetDolphinIsRunning(void)
{
	return CabinetDolphin::IsRunning();
}

void CabinetDolphinSaveState(int slot)
{
	CabinetDolphin::SaveState(slot);
}

void CabinetDolphinLoadState(int slot)
{
	CabinetDolphin::LoadState(slot);
}

void CabinetDolphinScreenshot(const char* name)
{
	CabinetDolphin::SaveScreenshot(ToString(name));
}

CabinetDolphinMetrics CabinetDolphinGetMetrics(void)
{
	const CabinetDolphin::Metrics metrics = CabinetDolphin::GetMetrics();
	CabinetDolphinMetrics out;
	out.fps = metrics.fps;
	out.vps = metrics.vps;
	out.speed = metrics.speed;
	return out;
}

}  // extern "C"
