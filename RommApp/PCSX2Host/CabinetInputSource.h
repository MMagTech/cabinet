// The input source Cabinet gives PCSX2 in place of SDL.
//
// PCSX2 reaches every controller through an InputSource, and upstream
// has exactly one on this platform: SDL. SDL does not survive Mac
// Catalyst (its GameController backend is built on NSViewController,
// and its CoreAudio backend on AppKit), so it is not in this build at
// all. Something has to hold that slot: InputManager dereferences the
// slot without a null check in a dozen places, so leaving it empty
// would crash rather than degrade.
//
// It is also where Cabinet's own controllers belong. Every other core
// in this app is fed by GameControllerManager, which owns pad
// pairing, dual controllers, haptics and the arcade rules. PS2 has no
// business growing a second controller stack beside it.
//
// This class registers under InputSourceType::SDL deliberately, so
// that PCSX2's own default bindings, which name SDL-0, keep resolving.
//
// NOT WIRED YET: nothing calls SetButtonState or SetAxisState. The
// class exists, holds the slot and parses bindings; the bridge from
// GameControllerManager is the next step and does not exist.

#pragma once

#include "Input/InputSource.h"

class CabinetInputSource final : public InputSource
{
public:
	CabinetInputSource();
	~CabinetInputSource() override;

	bool Initialize(SettingsInterface& si, std::unique_lock<std::mutex>& settings_lock) override;
	void UpdateSettings(SettingsInterface& si, std::unique_lock<std::mutex>& settings_lock) override;
	bool ReloadDevices() override;
	void Shutdown() override;
	bool IsInitialized() override;

	void PollEvents() override;

	std::optional<InputBindingKey> ParseKeyString(const std::string_view device, const std::string_view binding) override;
	TinyString ConvertKeyToString(InputBindingKey key, bool display = false, bool migration = false) override;
	TinyString ConvertKeyToIcon(InputBindingKey key) override;

	std::vector<std::pair<std::string, std::string>> EnumerateDevices() override;
	std::vector<InputBindingKey> EnumerateMotors() override;
	bool GetGenericBindingMapping(const std::string_view device, InputManager::GenericInputBindingMapping* mapping) override;
	InputLayout GetControllerLayout(u32 index) override;

	void UpdateMotorState(InputBindingKey key, float intensity) override;
	void UpdateMotorState(InputBindingKey large_key, InputBindingKey small_key, float large_intensity,
		float small_intensity) override;

	/// Cabinet's side of the wire, for GameControllerManager to call.
	/// Both are safe before Initialize and after Shutdown.
	static void SetButtonState(u32 pad, s32 button, bool pressed);
	static void SetAxisState(u32 pad, s32 axis, float value);

private:
	bool m_initialized = false;
};
