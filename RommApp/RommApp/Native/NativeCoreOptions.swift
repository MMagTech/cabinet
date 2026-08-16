import Foundation

/// One core option exposed on a core's Settings page: a libretro variable
/// key, the choices the core itself defines, and which one it defaults to.
/// The hand-picked subset per core, not a dump of everything the core
/// reports, per docs/scope-native-core-settings.md.
struct NativeCoreOption: Identifiable {
    struct Choice {
        let value: String
        let label: String
    }

    let key: String
    let label: String
    let detail: String
    let choices: [Choice]
    let defaultValue: String

    var id: String { key }
}

/// The hand-picked option subsets per platform, read from each core's real
/// `RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2` source rather than guessed.
/// Keyed by platform rather than by core: Genesis Plus GX serves five
/// platforms, and a pad type chosen for Genesis is meaningless on Game
/// Gear, let alone something to silently inherit.
enum NativeCoreOptions {
    /// Three from FBNeo's 30+ keys (`retro_common.cpp`): the genuinely
    /// relevant ones, excluding Neo-Geo-only, audio, and the
    /// state-compatibility-breaking or narrow/risky options. See
    /// docs/scope-native-core-settings.md for the full exclusion list.
    static let fbneo: [NativeCoreOption] = [
        NativeCoreOption(
            key: "fbneo-cpu-speed-adjust",
            label: "CPU speed",
            detail: "Overclocks the emulated CPU. Higher can help a struggling game, at the cost of authenticity.",
            choices: [
                .init(value: "100%", label: "100%"),
                .init(value: "110%", label: "110%"),
                .init(value: "120%", label: "120%"),
                .init(value: "130%", label: "130%"),
                .init(value: "140%", label: "140%"),
                .init(value: "150%", label: "150%"),
            ],
            defaultValue: "100%"
        ),
        NativeCoreOption(
            key: "fbneo-frameskip-type",
            label: "Frameskip",
            detail: "Drops frames to keep pace when the device can't keep up.",
            // Values are case-sensitive and match FBNeo's own list exactly
            // (retro_common.cpp): "disabled", "Fixed", "Auto", "Manual".
            // The first cut of this file guessed lowercase and broke games.
            choices: [
                .init(value: "disabled", label: "Disabled"),
                .init(value: "Fixed", label: "Fixed"),
                .init(value: "Auto", label: "Auto"),
                .init(value: "Manual", label: "Manual"),
            ],
            defaultValue: "disabled"
        ),
        // Companions to fbneo-frameskip-type: "Fixed" and "Manual" are
        // meaningless choices without these, the core just falls back to
        // its own internal default with no way to change it. Found
        // 2026-08-08: shipped with the picker but not its two levers.
        NativeCoreOption(
            key: "fbneo-fixed-frameskip",
            label: "Fixed frameskip rate",
            detail: "Used when Frameskip is set to Fixed. How many frames out of X+1 to skip rendering.",
            choices: [
                .init(value: "0", label: "No skipping"),
                .init(value: "1", label: "1 out of 2"),
                .init(value: "2", label: "2 out of 3"),
                .init(value: "3", label: "3 out of 4"),
                .init(value: "4", label: "4 out of 5"),
                .init(value: "5", label: "5 out of 6"),
            ],
            defaultValue: "0"
        ),
        NativeCoreOption(
            key: "fbneo-frameskip-manual-threshold",
            label: "Frameskip threshold",
            detail: "Used when Frameskip is set to Manual. Audio buffer occupancy percentage below which frames are skipped; higher reduces crackling by dropping frames more often.",
            choices: [
                .init(value: "15", label: "15%"),
                .init(value: "18", label: "18%"),
                .init(value: "21", label: "21%"),
                .init(value: "24", label: "24%"),
                .init(value: "27", label: "27%"),
                .init(value: "30", label: "30%"),
                .init(value: "33", label: "33%"),
                .init(value: "36", label: "36%"),
                .init(value: "39", label: "39%"),
                .init(value: "42", label: "42%"),
                .init(value: "45", label: "45%"),
                .init(value: "48", label: "48%"),
                .init(value: "51", label: "51%"),
                .init(value: "54", label: "54%"),
                .init(value: "57", label: "57%"),
                .init(value: "60", label: "60%"),
            ],
            defaultValue: "33"
        ),
        NativeCoreOption(
            key: "fbneo-allow-depth-32",
            label: "32-bit color",
            detail: "Renders at higher color depth where the game supports it. Some games need this to render properly.",
            choices: [
                .init(value: "disabled", label: "Disabled"),
                .init(value: "enabled", label: "Enabled"),
            ],
            // FBNeo's own default. The first cut said "disabled", which
            // silently changed the pixel format every game booted with.
            defaultValue: "enabled"
        ),
    ]

    /// Beetle Saturn's real levers, `beetle_saturn_deinterlacer` central:
    /// its FastMAD choice is documented as much higher CPU cost, the kind
    /// of lever the original Saturn scope doc named for a struggling title.
    static let beetleSaturn: [NativeCoreOption] = [
        NativeCoreOption(
            key: "beetle_saturn_deinterlacer",
            label: "Deinterlacer",
            detail: "How interlaced video is handled. FastMAD looks best but costs much more CPU.",
            choices: [
                .init(value: "weave", label: "Weave"),
                .init(value: "bob", label: "Bob"),
                .init(value: "bob_offset", label: "Bob offset"),
                .init(value: "fastmad", label: "FastMAD (higher CPU cost)"),
            ],
            defaultValue: "weave"
        ),
    ]

    /// Gambatte's colorization mode. Not cosmetic for this family: a GBC
    /// game was designed against real LCD color, and the core's default
    /// leaves original Game Boy titles rendering in flat greyscale.
    static let gameBoy: [NativeCoreOption] = [
        NativeCoreOption(
            key: "gambatte_gb_colorization",
            label: "Colorization",
            detail: "Colors original Game Boy games. Auto picks the most appropriate palette per game.",
            choices: [
                .init(value: "disabled", label: "Off"),
                .init(value: "auto", label: "Auto"),
                .init(value: "GBC", label: "Game Boy Color"),
                .init(value: "SGB", label: "Super Game Boy"),
            ],
            defaultValue: "disabled"
        ),
    ]

    /// mGBA's interframe blending. Some GBA games drive transparency by
    /// flickering sprites every other frame and rely on the LCD to blur
    /// them together, so without this those effects render as flicker.
    static let gameBoyAdvance: [NativeCoreOption] = [
        NativeCoreOption(
            key: "mgba_color_correction",
            label: "Screen colours",
            detail: "The GBA and GBA SP's LCD did not reproduce colour the way a raw pixel dump does. Confirmed on device 2026-08-11: turning this on visibly shifted hues wrong compared to the same scene in the web player (blue reading as magenta), not subtly, so it defaults off pending a real fix. Verify against the web player before trusting this setting.",
            // Values are the core's own: "GBA", "GBC", "Auto", or anything
            // else (mapped from "Off" here) for a raw, uncorrected dump.
            // "GBC" is deliberately not offered: this list only ever loads
            // GBA carts, never GBC ones, which is Gambatte's system.
            choices: [
                .init(value: "Off", label: "Off"),
                .init(value: "GBA", label: "GBA / GBA SP"),
                .init(value: "Auto", label: "Auto"),
            ],
            defaultValue: "Off"
        ),
        NativeCoreOption(
            key: "mgba_interframe_blending",
            label: "Interframe blending",
            detail: "Blends consecutive frames. Games that flicker sprites for transparency need this to look right.",
            // Values are the core's own, case-sensitive: "OFF", "mix",
            // "mix_smart", "lcd_ghosting", "lcd_ghosting_fast".
            choices: [
                .init(value: "OFF", label: "Off"),
                .init(value: "mix", label: "Simple"),
                .init(value: "mix_smart", label: "Smart"),
                .init(value: "lcd_ghosting", label: "LCD ghosting"),
            ],
            defaultValue: "OFF"
        ),
    ]

    /// Genesis pad type. Stored like a core option but applied through
    /// `retro_set_controller_port_device`, which is why the values here are
    /// the RetroPad device ids rather than strings the core parses.
    static let genesisPad = NativeCoreOption(
        key: "pad-type",
        label: "Controller",
        detail: "Six-button games need the six-button pad; some three-button games misread it.",
        choices: [
            .init(value: "\(NativePadDevice.threeButton)", label: "3-button"),
            .init(value: "\(NativePadDevice.sixButton)", label: "6-button"),
        ],
        defaultValue: "\(NativePadDevice.threeButton)"
    )

    static let genesis: [NativeCoreOption] = [genesisPad]

    /// Unlike the Genesis pad, this is a genuine libretro core variable
    /// (`RETRO_ENVIRONMENT_GET_VARIABLE`), not a controller-port device
    /// change, confirmed via `strings` on the vendored
    /// `libbeetle_pce_fast_ios.a`: the key and both choice strings,
    /// `"2 Buttons"` and `"6 Buttons"`, are exactly what the core embeds.
    /// No special-casing needed in `dictionary(for:)`, it flows through
    /// the normal path everything else here does.
    static let pceJoypad = NativeCoreOption(
        key: "pce_fast_default_joypad_type_p1",
        label: "Controller",
        detail: "Six-button games need the six-button pad; some two-button games misread it.",
        choices: [
            .init(value: "2 Buttons", label: "2-button"),
            .init(value: "6 Buttons", label: "6-button"),
        ],
        defaultValue: "2 Buttons"
    )

    static let pce: [NativeCoreOption] = [pceJoypad]

    /// Sega CD boots off a region-matched BIOS, so a disc paired with the
    /// wrong region simply does not start. Region detection is the lever
    /// that decides which one the core reaches for.
    static let segaCD: [NativeCoreOption] = [
        NativeCoreOption(
            key: "genesis_plus_gx_region_detect",
            label: "Region",
            detail: "Which region BIOS the disc boots against. A mismatch stops the game from starting at all.",
            choices: [
                .init(value: "auto", label: "Auto"),
                .init(value: "ntsc-u", label: "NTSC-U"),
                .init(value: "pal", label: "PAL"),
                .init(value: "ntsc-j", label: "NTSC-J"),
            ],
            defaultValue: "auto"
        ),
        genesisPad,
    ]

    /// Per-platform option sets. A platform absent from this switch has no
    /// options worth exposing, per docs/scope-native-core-settings.md:
    /// only what decides whether a game boots or looks fundamentally
    /// different clears the bar, never preference or performance toggles.
    static func options(for platform: NativePlatform) -> [NativeCoreOption] {
        switch platform {
        case .arcade: return fbneo
        case .saturn: return beetleSaturn
        // GBC excluded on purpose: Gambatte's own libretro.cpp hard-skips
        // the whole custom-palette branch whenever gb.isCgb() is true
        // (colorization only ever applies to plain monochrome Game Boy
        // ROMs, a real GBC game already has its own built-in colors), so
        // showing this option under Game Boy Color would be a setting
        // that visibly does nothing. Found 2026-08-08.
        case .gb: return gameBoy
        case .gba: return gameBoyAdvance
        case .genesis, .sega32X: return genesis
        case .segaCD: return segaCD
        case .tg16, .tgCD: return pce
        default: return []
        }
    }
}

/// RetroPad device ids for the Genesis pad, `RETRO_DEVICE_SUBCLASS` of
/// `RETRO_DEVICE_JOYPAD` as Genesis Plus GX defines them in its own
/// libretro.c, not guessed.
enum NativePadDevice {
    static let threeButton: UInt32 = (0 + 1) << 8 | 1
    static let sixButton: UInt32 = (1 + 1) << 8 | 1
}

/// Per-platform option values, stored in UserDefaults under a key
/// namespaced by platform and libretro key. Values fall back to the
/// option's own default when unset, matching how the core itself treats a
/// missing key.
enum NativeCoreOptionsStore {
    private static func key(platform: NativePlatform, option: String) -> String {
        "com.mmagtech.RommApp.nativeCoreOption.\(platform.storageKey).\(option)"
    }

    static func value(_ option: NativeCoreOption, for platform: NativePlatform) -> String {
        let stored = UserDefaults.standard.string(forKey: key(platform: platform, option: option.key))
        // A stored value the option no longer lists is discarded, not
        // trusted: an early build saved values FBNeo doesn't accept, and
        // anything stale from that build must fall back to the default
        // rather than keep reaching the core forever.
        guard let stored, option.choices.contains(where: { $0.value == stored }) else {
            return option.defaultValue
        }
        return stored
    }

    static func setValue(_ value: String, for option: NativeCoreOption, platform: NativePlatform) {
        UserDefaults.standard.set(value, forKey: key(platform: platform, option: option.key))
    }

    /// The options dictionary for a platform, ready for
    /// `LibretroFrontend.setCoreOptions:`. Deliberately only the keys
    /// someone actually changed in Settings, not every option at its
    /// default: sending a value the core recognizes still changes how
    /// some drivers behave versus never calling `SET_CORE_OPTIONS`/
    /// `GET_VARIABLE` for that key at all, since `LibretroFrontend` still
    /// doesn't answer `SET_CORE_OPTIONS_V2` (a real, already-known gap).
    /// Games nobody has touched a core option for get exactly the empty
    /// dictionary this app always sent before this feature existed.
    ///
    /// The pad type is excluded: it is not a core variable, it reaches the
    /// core through `padDevice(for:)` instead.
    static func dictionary(for platform: NativePlatform) -> [String: String] {
        var result: [String: String] = [:]
        for option in NativeCoreOptions.options(for: platform)
        where option.key != NativeCoreOptions.genesisPad.key {
            let storageKey = key(platform: platform, option: option.key)
            guard let stored = UserDefaults.standard.string(forKey: storageKey),
                  option.choices.contains(where: { $0.value == stored })
            else { continue }
            result[option.key] = stored
        }
        result.merge(forcedOptions(for: platform)) { _, forced in forced }
        return result
    }

    /// Options that are never a user choice, always sent, and never listed
    /// in `NativeCoreOptions.options(for:)`: not preferences, hard
    /// requirements this frontend imposes on a core.
    private static func forcedOptions(for platform: NativePlatform) -> [String: String] {
        switch platform {
        case .psx:
            // Without an answer for these keys PCSX ReARMed's
            // load_memcards() skips card setup entirely (memcard_type
            // stays NONE, confirmed in the vendored libretro.c), leaving
            // the game with no card at all. Card 1 as "libretro" is what
            // exposes it through RETRO_MEMORY_SAVE_RAM for the memory
            // card sync; card 2 stays explicitly off rather than
            // "shared", which would write a .mcd into the per-launch
            // temp directory the next launch deletes.
            return [
                "pcsx_rearmed_memcard1": "libretro",
                "pcsx_rearmed_memcard2": "none",
            ]
        case .segaCD:
            // The CD console's internal backup RAM defaults to "per
            // bios", one shared .brm per region across every Sega CD
            // game, real hardware's own behavior. Forced per game
            // instead (decided with Marcus 2026-08-16): Cabinet's save
            // sync is per game on RomM's per-rom save model, a shared
            // file would have to live under some arbitrary game, and the
            // tiny 8KB BRAM can no longer fill up across the library.
            //
            // cart_size must be answered explicitly, same gap-class as
            // N64's zeroed globals: unanswered, the core's cart_size
            // global stays 0, a state upstream never runs, and Sonic CD
            // refuses to boot past "RAM cartridge not initialized",
            // found on device 2026-08-16.
            //
            // "4meg" is RetroArch's own default and the only class of
            // value that is safe: "disabled" (0xff) was tried first and
            // crashes the vendored core outright in Mode 2 CD boot,
            // cd_cart_init computes its size mask as (1 << (id + 13)) - 1
            // and 0xff makes that a 268-bit shift, undefined behavior
            // that produced an all-ones mask and a format write 4GB past
            // the buffer (EXC_BAD_ACCESS in bram_load's cart formatting,
            // symbolicated from a real device crash 2026-08-16). Known
            // limitation of having a cart present: a save a player
            // deliberately writes onto the cart persists on this device
            // (the save directory survives) but does not sync to RomM,
            // only the internal backup RAM does.
            return [
                "genesis_plus_gx_system_bram": "per game",
                "genesis_plus_gx_cart_size": "4meg",
            ]
        case .saturn:
            // "libretro" hands the console's internal backup RAM to this
            // frontend through RETRO_MEMORY_SAVE_RAM, which is where the
            // memory card sync reads it. It is already the vendored
            // core's own default; forcing it means a core update flipping
            // that default can never silently strand Saturn saves in a
            // .bkr file nothing on this side reads (which is exactly what
            // every Saturn save did before issue #5 wired this region up:
            // libretro mode stops the core writing its own file, and the
            // frontend was not collecting the region either, so the saves
            // had no destination at all).
            return ["beetle_saturn_save_method": "libretro"]
        case .sega32X:
            // PicoDrive's retro_set_controller_port_device is an empty
            // function (confirmed in its libretro.c); pad type only moves
            // through the picodrive_input1 variable. Without this
            // translation the Controller setting silently did nothing on
            // 32X, for touch and physical controllers alike.
            let sixButton = padDevice(for: .sega32X) == NativePadDevice.sixButton
            return ["picodrive_input1": sixButton ? "6 button pad" : "3 button pad"]
        case .n64:
            // Forced, not a Settings choice: this app's cores run in the
            // main process with no JIT entitlement, so the CPU core must
            // stay the pure interpreter (mupen64plus-cpucore's dynarec
            // choices would crash), and the RDP plugin is pinned to
            // GLideN64, the only one of the core's three RDP plugins with
            // a GLES3 hardware-render path this frontend supports.
            // MaxTxCacheSize must be sent explicitly: GLideN64's texture
            // cache size global defaults to 0 in the core's own source
            // (spikes/cores/mupen64plus/src/libretro/libretro.c), not the
            // 8000 shown in its options table, which only takes effect if
            // a frontend answers this key. Left unset, an empty cache
            // compared against a max of 0 reads as already full and the
            // first texture ever added crashes on an invalid free
            // (GLideN64/src/Textures.cpp's _checkCacheSize/_addTexture),
            // confirmed on real hardware during the go/no-go spike.
            // alt-map is forced to "True" too: without it, the core's
            // default C-button reading digitizes RETRO_DEVICE_INDEX_
            // ANALOG_RIGHT instead of reading plain RetroPad bits
            // (confirmed in emulate_game_controller_via_libretro.c's
            // inputGetKeys_default), a second analog stick this frontend
            // has no support for and n64.json's touch layout does not
            // drive. With it on, C-buttons and A/B/L/R/Z all resolve to
            // ordinary RetroPad ids the way the rest of this app already
            // reads input, matching n64.json's own ids exactly.
            return [
                "mupen64plus-cpucore": "pure_interpreter",
                "mupen64plus-rdp-plugin": "gliden64",
                "mupen64plus-MaxTxCacheSize": "8000",
                "mupen64plus-alt-map": "True",
                "mupen64plus-pak1": "memory",
                // The real bug behind "the stick doesn't move my
                // character": astick_sensitivity is a plain C global in
                // the core, zero-initialized, only ever assigned if this
                // frontend answers GET_VARIABLE for this exact key
                // (libretro.c line ~844). We never had, so it stayed 0,
                // and inputGetKeys_reuse's own math is
                // `radius *= 80.0 / ASTICK_MAX * (astick_sensitivity / 100.0)`,
                // multiplying every stick reading by exactly zero
                // regardless of real deflection. Confirmed against a full
                // real-device trace: touch input and the core's own
                // inputState query both carried correct nonzero values
                // the whole time, so the value never even reached the
                // game to move anything. "100" is the core's own
                // documented default (libretro_core_options.h), same
                // gap-class as the missing pak1 default above.
                "mupen64plus-astick-sensitivity": "100",
                "mupen64plus-astick-deadzone": "15",
            ]
        default:
            return [:]
        }
    }

    /// The RetroPad device port 0 should present, or 0 to leave the core's
    /// own default in place.
    ///
    /// Dreamcast needs an explicit RETRO_DEVICE_JOYPAD (1) here, unlike
    /// every other core, which all default to a real controller already
    /// plugged in on their own. Flycast's own Maple bus default is no
    /// controller at all (MapleMainDevices defaults to MDT_None in
    /// shell/libretro/option.cpp) until something calls
    /// retro_set_controller_port_device, which is standard libretro
    /// behaviour, a well-configured frontend is expected to always
    /// negotiate the device, not something Flycast gets wrong. Found
    /// 2026-08-11 from a BIOS screen whose Start prompt never responded:
    /// touch input and haptics both worked, RetroPad bits reached
    /// inputState correctly, but Flycast had no controller plugged into
    /// the port those bits were meant for.
    static func padDevice(for platform: NativePlatform) -> UInt32 {
        // Same class of bug Dreamcast already hit: leaving this at 0
        // means setControllerPortDevice's caller never calls the core's
        // set_controller_port_device at all (see LibretroFrontend.mm,
        // gPortDevice != 0 guard), so mupen64plus-libretro-nx's own
        // controller[0].control->Present never gets set to 1 by us. The
        // core's default RETRO_DEVICE_JOYPAD/default case both set
        // Present = 1 the same way, so passing it explicitly rather than
        // leaving the port unconfigured is the fix, confirmed against
        // retro_set_controller_port_device in the core's own source.
        if platform == .dreamcast || platform == .n64 { return 1 }
        let option = NativeCoreOptions.genesisPad
        guard NativeCoreOptions.options(for: platform).contains(where: { $0.key == option.key })
        else { return 0 }
        return UInt32(value(option, for: platform)) ?? 0
    }
}
