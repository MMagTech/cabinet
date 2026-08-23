import Foundation

/// Every core option MAME 2003-Plus exposes, answered.
///
/// This exists because of a failure mode that cost this project eight
/// separate evenings, one option at a time. A libretro core reads its
/// settings by asking the frontend for each variable in turn. When the
/// frontend does not answer, the core does NOT fall back to the default
/// printed in its own option table: the whole case is skipped and the
/// C global keeps whatever it was initialised to, which is zero. Zero
/// means silence for a sample rate, black for brightness, off for every
/// toggle whose useful state is on. So an unanswered option is not
/// "the default", it is the worst value in the list, and it fails
/// quietly.
///
/// Found that way, one at a time: dials, audio, brightness, gamma,
/// crosshairs, and the NVRAM bootstraps that make configured boards
/// boot at all. Answering all of them at once ends the pattern, and
/// leaves a table someone can audit against the core rather than a
/// scattering of lines each remembering its own bug.
///
/// The values below are transcribed from the core's own
/// `src/mame2003/core_options.c`, the definition table itself, not from
/// documentation and not from memory. Every key here was also confirmed
/// present in the linked binary. Where Cabinet deliberately differs
/// from the core's default, it is in `deviations` with its reason, so
/// the two lists never have to be told apart by inspection.
enum MAME2003PlusOptions {
    /// The core's own defaults, verbatim from its definition table.
    /// Anything Cabinet has no opinion about belongs here and only
    /// here: the point is that the core behaves as its authors
    /// intended, not that Cabinet has a view on frameskip.
    private static let coreDefaults: [String: String] = [
        "mame2003-plus_art_overlay_opacity": "default",
        "mame2003-plus_art_resolution": "1",
        "mame2003-plus_autosave_hiscore": "default",
        "mame2003-plus_brightness": "1.0",
        "mame2003-plus_cheat_input_ports": "disabled",
        "mame2003-plus_cpu_clock_scale": "default",
        "mame2003-plus_crosshair_appearance": "simple",
        "mame2003-plus_crosshair_enabled": "enabled",
        "mame2003-plus_dial_swap_xy": "disabled",
        "mame2003-plus_dialsharexy": "disabled",
        "mame2003-plus_digital_joy_centering": "enabled",
        "mame2003-plus_display_artwork": "enabled",
        "mame2003-plus_display_setup": "disabled",
        "mame2003-plus_four_way_emulation": "disabled",
        "mame2003-plus_frameskip": "disabled",
        "mame2003-plus_gamma": "1.0",
        "mame2003-plus_input_interface": "simultaneous",
        "mame2003-plus_input_toggle": "enabled",
        "mame2003-plus_neogeo_bios": "default",
        "mame2003-plus_nvram_bootstraps": "enabled",
        "mame2003-plus_override_ad_stick": "disabled",
        "mame2003-plus_sample_rate": "48000",
        "mame2003-plus_stv_bios": "default",
        "mame2003-plus_tate_mode": "disabled",
        "mame2003-plus_use_alt_sound": "disabled",
        "mame2003-plus_use_samples": "enabled",
        "mame2003-plus_vector_antialias": "enabled",
        "mame2003-plus_vector_beam_width": "2",
        "mame2003-plus_vector_flicker": "20",
        "mame2003-plus_vector_intensity": "1.5",
        "mame2003-plus_vector_resolution": "1024x768",
        "mame2003-plus_vector_translucency": "enabled",
        "mame2003-plus_xy_device": "mouse",
    ]

    /// Where Cabinet knowingly differs, and why. Five entries, each one
    /// a decision rather than an oversight.
    private static func deviations(gunCabinet: Bool) -> [String: String] {
        var out: [String: String] = [:]

        // Core default: enabled, for both. They decide whether MAME
        // writes its files into a subfolder of the directory it is
        // given. Cabinet already hands each core its own per-game
        // directory, so the subfolder buys nothing, and turning it on
        // now would move every arcade NVRAM and config one level
        // deeper: existing high scores would simply stop being found,
        // silently, which is the shape of data loss this project
        // refuses to ship. Disabled matches where the files on real
        // devices already are.
        out["mame2003-plus_core_save_subfolder"] = "disabled"
        // Same reasoning on the way in: Cabinet stages BIOS and sample
        // files into the directory it passes, so MAME must look there
        // rather than one level down.
        out["mame2003-plus_core_sys_subfolder"] = "disabled"

        // Core default: disabled, meaning both screens show. That is
        // genuinely how RetroArch behaves out of the box, so this is
        // Cabinet's own choice rather than a bug being corrected: a
        // copyright notice and a known-issues list are MAME talking to
        // an operator, and the person here has already chosen a game
        // from a library and pressed Play. Worse, the modal is
        // dismissed by MAME's own UI_SELECT, which no cabinet control
        // panel here is guaranteed to offer, so a game could sit
        // behind it unreachable.
        out["mame2003-plus_skip_disclaimer"] = "enabled"
        out["mame2003-plus_skip_warnings"] = "enabled"

        // Core default: enabled. This one is a real repair. With
        // remapping on, MAME owns input assignments and writes them
        // into cfg/ra_<game>.cfg when the game exits, then reapplies
        // them at every later launch. A single bad assignment saved
        // that way left Bowl-O-Rama permanently unplayable on two
        // devices at once, taking no input at all, and the only cure
        // was deleting the file from outside the app. Cabinet owns
        // input completely, through its own layouts and bindings, so
        // MAME's copy of that job can only ever disagree with it or
        // corrupt itself.
        out["mame2003-plus_mame_remapping"] = "disabled"

        // The lightgun cabinets, the one place Cabinet answers a
        // question about the game rather than about the emulator.
        if gunCabinet {
            out["mame2003-plus_xy_device"] = "lightgun"
        }

        return out
    }

    /// Everything to send, defaults with Cabinet's deviations layered
    /// over them.
    static func all(gunCabinet: Bool) -> [String: String] {
        coreDefaults.merging(deviations(gunCabinet: gunCabinet)) { _, mine in mine }
    }
}
