#include "CabinetInputSource.h"

#include "Input/InputManager.h"

#include "common/Console.h"

// Bindings are parsed and printed through InputSource's own generic
// controller helpers rather than SDL's naming tables, which is what
// keeps "SDL-0/Cross" style bindings resolving with SDL absent.

CabinetInputSource::CabinetInputSource() = default;
CabinetInputSource::~CabinetInputSource() = default;

bool CabinetInputSource::Initialize(SettingsInterface& si, std::unique_lock<std::mutex>& settings_lock)
{
	m_initialized = true;
	return true;
}

void CabinetInputSource::UpdateSettings(SettingsInterface& si, std::unique_lock<std::mutex>& settings_lock)
{
}

bool CabinetInputSource::ReloadDevices()
{
	return false;
}

void CabinetInputSource::Shutdown()
{
	m_initialized = false;
}

bool CabinetInputSource::IsInitialized()
{
	return m_initialized;
}

void CabinetInputSource::PollEvents()
{
	// Cabinet pushes controller state as it arrives rather than being
	// polled for it, so there is nothing to do on the emulation thread.
}

std::optional<InputBindingKey> CabinetInputSource::ParseKeyString(
	const std::string_view device, const std::string_view binding)
{
	if (!device.starts_with("SDL-"))
		return std::nullopt;

	return ParseGenericControllerKey(InputSourceType::SDL, device, binding);
}

TinyString CabinetInputSource::ConvertKeyToString(InputBindingKey key, bool display, bool migration)
{
	TinyString ret;
	ret.assign(ConvertGenericControllerKeyToString(key));
	return ret;
}

TinyString CabinetInputSource::ConvertKeyToIcon(InputBindingKey key)
{
	return TinyString();
}

std::vector<std::pair<std::string, std::string>> CabinetInputSource::EnumerateDevices()
{
	// Reports nothing until the GameControllerManager bridge exists.
	// Claiming a pad that cannot deliver a button press would make the
	// binding UI look wired when it is not.
	return {};
}

std::vector<InputBindingKey> CabinetInputSource::EnumerateMotors()
{
	return {};
}

bool CabinetInputSource::GetGenericBindingMapping(
	const std::string_view device, InputManager::GenericInputBindingMapping* mapping)
{
	return false;
}

InputLayout CabinetInputSource::GetControllerLayout(u32 index)
{
	return InputLayout::Unknown;
}

void CabinetInputSource::UpdateMotorState(InputBindingKey key, float intensity)
{
	// Rumble reaches the pad through Cabinet's own haptics path.
}

void CabinetInputSource::UpdateMotorState(
	InputBindingKey large_key, InputBindingKey small_key, float large_intensity, float small_intensity)
{
}

void CabinetInputSource::SetButtonState(u32 pad, s32 button, bool pressed)
{
	InputManager::InvokeEvents(
		MakeGenericControllerButtonKey(InputSourceType::SDL, pad, button), pressed ? 1.0f : 0.0f);
}

void CabinetInputSource::SetAxisState(u32 pad, s32 axis, float value)
{
	InputManager::InvokeEvents(MakeGenericControllerAxisKey(InputSourceType::SDL, pad, axis), value);
}
