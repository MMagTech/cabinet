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
    /// One line under the option saying what it does. Empty when the
    /// choices say it themselves, which is the bar: Virtual Boy's two
    /// settings name a colour and a pair of lenses and now draw both,
    /// so a sentence explaining them is words the screen already spent.
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
                // "OFF" uppercase, matching mGBA's own value list exactly
                // (libretro_core_options.h:185). This read "Off" until
                // 2026-08-17, which mGBA matches against none of its three
                // known strings and so lands on ccType 0, the off path, by
                // accident rather than by agreement. Harmless today and
                // exactly the shape of the FBNeo frameskip casing bug
                // above, so corrected while the values were being checked.
                // A stored "Off" from before now fails the choices check in
                // `value(_:for:)` and falls back to this default, which is
                // the same setting it always meant.
                .init(value: "OFF", label: "Off"),
                .init(value: "GBA", label: "GBA / GBA SP"),
                .init(value: "Auto", label: "Auto"),
            ],
            defaultValue: "OFF"
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
    /// Stella 2014's interframe blending. The 2600's 30Hz sprite flicker
    /// is how many games drew more objects than the TIA had sprites, and
    /// a phosphor TV smeared it into translucency; on an LCD it is just
    /// flicker. Same reasoning as mGBA's blending option above.
    static let atari2600: [NativeCoreOption] = [
        NativeCoreOption(
            key: "stella2014_mix_frames",
            label: "Flicker blending",
            detail: "Blends alternating frames the way a phosphor TV did. Helps games that flicker sprites, like Ms. Pac-Man.",
            choices: [
                .init(value: "disabled", label: "Off"),
                .init(value: "mix", label: "Average"),
                .init(value: "ghost_65", label: "Light ghosting"),
                .init(value: "ghost_75", label: "Medium ghosting"),
                .init(value: "ghost_85", label: "Heavy ghosting"),
            ],
            defaultValue: "disabled"
        ),
    ]

    /// The Virtual Boy's display is the whole point of the machine and
    /// the one thing a phone cannot reproduce: a stereoscopic pair of
    /// red monochrome screens, one per eye, inside a headset.
    ///
    /// Two separate answers to that, which is why there are two rows.
    /// The colour is the flat presentation and defaults to the authentic
    /// black and red. The anaglyph preset is real depth for anyone
    /// holding a pair of coloured glasses, off by default because
    /// without glasses it looks like a mistake. Every preset the core
    /// offers is listed rather than only the common red and blue, since
    /// which pair someone owns is not something this app can guess.
    static let virtualBoy: [NativeCoreOption] = [
        NativeCoreOption(
            key: "vb_anaglyph_preset",
            label: "3D glasses",
            detail: "",
            choices: [
                .init(value: "disabled", label: "Off"),
                .init(value: "red & blue", label: "Red and blue"),
                .init(value: "red & cyan", label: "Red and cyan"),
                .init(value: "red & electric cyan", label: "Red and electric cyan"),
                .init(value: "green & magenta", label: "Green and magenta"),
                .init(value: "yellow & blue", label: "Yellow and blue"),
            ],
            defaultValue: "disabled"
        ),
        NativeCoreOption(
            key: "vb_color_mode",
            label: "Screen colour",
            detail: "",
            choices: [
                .init(value: "black & red", label: "Red (original)"),
                .init(value: "black & white", label: "White"),
                .init(value: "black & blue", label: "Blue"),
                .init(value: "black & cyan", label: "Cyan"),
                .init(value: "black & electric cyan", label: "Electric cyan"),
                .init(value: "black & green", label: "Green"),
                .init(value: "black & magenta", label: "Magenta"),
                .init(value: "black & yellow", label: "Yellow"),
            ],
            defaultValue: "black & red"
        ),
    ]

    /// Not a core option at all: the screen overlay toggle, this app's
    /// own setting wearing the option plumbing so it gets storage and a
    /// Settings row for free. The "cabinet_" prefix marks it; it rides
    /// along in the options dictionary and vecx simply never asks for
    /// it. See VectrexOverlays.swift for what it controls.
    static let vectrex: [NativeCoreOption] = [
        NativeCoreOption(
            key: VectrexOverlays.optionKey,
            label: "Screen overlays",
            detail: "Draws each game's original translucent overlay over the picture, the colored sheet every Vectrex cartridge shipped with. Games whose sheet is not reproduced show the bare screen.",
            choices: [
                .init(value: "enabled", label: "On"),
                .init(value: "disabled", label: "Off"),
            ],
            defaultValue: "enabled"
        ),
    ]

    /// Opera's two real levers, from its own option table. The 3DO ran
    /// many of its games below 20fps on the actual hardware, which is why
    /// the overclock option exists and why it is worth exposing: it is a
    /// playability lever, not an accuracy tweak. Both default to stock;
    /// this platform's frame budget is the tightest of the app's
    /// interpreters and spending it is a per-person choice.
    static let threeDO: [NativeCoreOption] = [
        NativeCoreOption(
            key: "opera_cpu_overclock",
            label: "CPU speed",
            detail: "Runs the 3DO's CPU faster than the real 12.5MHz. Many games ran below 20fps on the actual console; a higher clock genuinely raises their frame rate, at a real cost in emulation load.",
            choices: [
                .init(value: "1.0x (12.50Mhz)", label: "Stock"),
                .init(value: "1.1x (13.75Mhz)", label: "1.1x"),
                .init(value: "1.2x (15.00Mhz)", label: "1.2x"),
                .init(value: "1.5x (18.75Mhz)", label: "1.5x"),
                .init(value: "2.0x (25.00Mhz)", label: "2x"),
            ],
            defaultValue: "1.0x (12.50Mhz)"
        ),
        NativeCoreOption(
            key: "opera_high_resolution",
            label: "HiRes 3D rendering",
            detail: "Renders 3D models at double resolution. No effect on 2D games, and a significant emulation cost.",
            choices: [
                .init(value: "disabled", label: "Off"),
                .init(value: "enabled", label: "On"),
            ],
            defaultValue: "disabled"
        ),
    ]

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

    /// The one Dreamcast option, and unlike everything else in this file
    /// it IS a performance knob, exposed deliberately: the emulated SH4's
    /// speed decides whether heavy scenes slow down, the right value is a
    /// property of the device in hand (an iPhone Air affords twice what
    /// an A15 Apple TV does, measured 2026-08-16), and hardware this app
    /// has never met will keep arriving. The audio governor makes a
    /// too-high pick degrade into slowdown rather than static, which is
    /// what makes this safe to hand to users at all.
    ///
    /// Labels are EFFECTIVE speeds, half the nominal values sent to the
    /// core, because the build charges interpreted instructions double
    /// (CPU_RATIO=2, see tools/build-flycast.sh). A row saying 200MHz
    /// while delivering 100 would be a lie users tune against.
    static let dreamcast: [NativeCoreOption] = [
        NativeCoreOption(
            key: "reicast_sh4clock",
            label: "CPU speed",
            detail: "A real Dreamcast is 200 MHz. Lower runs cooler with fewer audio dropouts; higher needs a recent device.",
            choices: [
                .init(value: "100", label: "50 MHz"),
                .init(value: "150", label: "75 MHz"),
                .init(value: "200", label: "100 MHz"),
                .init(value: "300", label: "150 MHz"),
                .init(value: "400", label: "200 MHz"),
            ],
            defaultValue: dreamcastDefaultClock
        ),
    ]

    /// Both platforms default to an effective 100MHz. The 2026-08-16
    /// "tvOS gets 75" tuning was sized to a core that, it turned out,
    /// never read this option at all (the interpreter ignored Sh4Clock;
    /// wired 2026-08-19), so every device has actually been running
    /// 100MHz effective. Keeping 200 here preserves that behaviour
    /// exactly now that the dial is real; re-tune per platform from
    /// measurements on the wired core, not before.
    static var dreamcastDefaultClock: String {
        #if targetEnvironment(macCatalyst)
        // The real SH4's 200MHz, measured rather than assumed, now that
        // Dreamcast is this platform's alone and has a recompiler.
        //
        // The 100MHz default was a phone compromise the Mac inherited,
        // and its cost is not framerate: Crazy Taxi 2 holds 60 either
        // way. It is the TAIL. Measured 2026-09-01 over 25 seconds of
        // scripted gameplay, emulation cost per frame, mean and p99:
        //
        //   100MHz 640x480    4.700 / 16.243 ms   worst 105.09
        //   200MHz 640x480    3.750 /  4.599 ms   worst  18.31
        //   100MHz 1920x1440  3.452 /  3.608 ms   worst  65.03
        //   200MHz 1920x1440  3.226 /  3.339 ms   worst  60.02
        //
        // A p99 of 16.243 against a 16.67ms frame budget is a game
        // living on the edge of dropping one, which is exactly what
        // jitter feels like. The real clock takes that to 3.3.
        return "400"
        #else
        return "200"
        #endif
    }

    /// Per-platform option sets. A platform absent from this switch has no
    /// options worth exposing, per docs/scope-native-core-settings.md:
    /// only what decides whether a game boots or looks fundamentally
    /// different clears the bar, never preference or performance toggles.
    /// Dreamcast's CPU speed is the one deliberate exception; its comment
    /// argues the case.
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
        case .dreamcast: return dreamcast
        case .atari2600: return atari2600
        case .threeDO: return threeDO
        case .vectrex: return vectrex
        case .virtualBoy: return virtualBoy
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
    /// Debug-only escape hatch so one build can measure both sides of the
    /// 2026-08-17 quality pass. With `-cabinetBenchStockOptions 1` on the
    /// command line, `dictionary(for:)` reverts to what it did before that
    /// pass: only options somebody changed, and none of the restored
    /// defaults. Nothing but `NativeBenchHarness` ever passes it, and it
    /// compiles away entirely in a release build.
    static var benchWantsStockOptions: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "cabinetBenchStockOptions")
        #else
        return false
        #endif
    }

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
    /// `LibretroFrontend.setCoreOptions:`.
    ///
    /// Every exposed option is sent at its resolved value, not only the
    /// ones somebody changed. This used to send only changed keys, on the
    /// reasoning that an untouched game should reach the core exactly as
    /// it did before core settings existed. That reasoning had a hole:
    /// `LibretroFrontend` answers neither `SET_VARIABLES` nor
    /// `SET_CORE_OPTIONS_V2`, so a key nobody answers does not fall back
    /// to the value the option table declares, it falls back to whatever
    /// the core's own C global happens to be initialised to, and those
    /// two are not the same thing. RetroArch never sees the difference
    /// because registering the options is what seeds its answers.
    ///
    /// Measured 2026-08-17 with `tools/bench/libretro_bench`, which
    /// answers exactly what this frontend answers: FBNeo's
    /// `bAllowDepth32` is a static `false` while this app's own Settings
    /// screen showed "enabled", so every arcade game rendered 16-bit;
    /// FCEUmm's `current_palette` is a static `0`, which is the
    /// third-party "asqrealc" palette rather than the core's default NES
    /// one, and 98% of pixels in a Contra frame differed between them.
    /// Sending the resolved value always is what makes the Settings
    /// screen describe the machine that is actually running.
    ///
    /// Nintendo 64 and Dreamcast are explicitly excluded from the change,
    /// not merely unaffected by it. N64 exposes no options at all and
    /// Dreamcast already always-sent its one option below, so both would
    /// build a byte-identical dictionary either way; the guard is here so
    /// that stays true by construction rather than by coincidence, since
    /// both are separate in-flight investigations this pass must not
    /// perturb.
    ///
    /// The pad type is excluded: it is not a core variable, it reaches the
    /// core through `padDevice(for:)` instead.
    /// The N64 CPU core. The Mac carries the JIT entitlement, so it
    /// gets the real recompiler; iOS and tvOS stay on the cached
    /// interpreter, which is as far as a process without that
    /// entitlement can go. `dynamic_recompiler` reaches malloc_exec and
    /// PROT_EXEC pages (r4300_core.c under EMUMODE_DYNAREC), which is
    /// exactly what they cannot do.
    private static var n64CpuCore: String {
        #if targetEnvironment(macCatalyst)
        "dynamic_recompiler"
        #else
        "cached_interpreter"
        #endif
    }

    /// The PSP CPU core, now the same on every platform, and on the Mac
    /// that is a measured choice rather than the accident it used to be.
    ///
    /// This asked for "JIT" on the Mac and did not get it. PPSSPP's
    /// Catalyst build defines PPSSPP_PLATFORM_IOS, so it gated the
    /// recompiler on RETRO_ENVIRONMENT_GET_JIT_CAPABLE, which this
    /// frontend did not answer, and libretro.cpp quietly rewrote the
    /// request to CPUCore::IR_INTERPRETER. The core never said so; that
    /// is why the engine PSP was running sat unresolved for days. It
    /// prints it now (tools/build-ppsspp.sh adds the line), and the
    /// frontend answers the capability call, so this value is finally
    /// the one that takes effect.
    ///
    /// Measured 2026-09-01 on the M4, both engines, from the core's own
    /// reported engine number, mean and p99 emulation cost per frame:
    ///
    ///   Lumines          native JIT 3.051 / 4.993 ms   IR 1.929 / 3.031
    ///   Hammerin' Hero   native JIT 4.501 / 6.312 ms   IR 4.242 / 6.051
    ///
    /// The recompiler is not faster here, and its worst frame is far
    /// worse (248 ms against 94 ms) because compilation stalls land
    /// inside frames. That matches upstream's own position that the IR
    /// interpreter is close to full speed. It also costs an entitlement:
    /// PPSSPP takes executable memory with mmap plus mprotect rather
    /// than MAP_JIT, which hardened runtime kills outright
    /// ("CODESIGNING Invalid Page", SIGKILL inside Core_RunLoopUntil on
    /// the emu thread), so the native JIT only runs at all with
    /// com.apple.security.cs.allow-unsigned-executable-memory added to
    /// CabinetMac.entitlements. Paying a broader entitlement for a
    /// slower engine is the wrong trade, so it is not paid.
    ///
    /// To revisit: add that entitlement and return "JIT" here, or teach
    /// PPSSPP's Common/MemoryUtil.cpp the MAP_JIT path the other three
    /// recompilers in this app already use. Both strings are upstream's
    /// own (libretro.cpp maps them to CPUCore::JIT and
    /// CPUCore::IR_INTERPRETER).
    private static var pspCpuCore: String { "IR JIT" }

    /// PSP's internal resolution. Both values are upstream's own strings
    /// from its option table; "Auto" is never used and that is the trap
    /// this option is famous for here, since it sizes the render to a
    /// display a libretro frontend never reports and every frame comes
    /// out 0x0 and is dropped.
    ///
    /// 480x272 is the PSP's own screen, and it is what every platform
    /// shipped until now. On a phone that is right. On a 5K panel it is
    /// a 480-wide picture stretched across the desk.
    private static var pspInternalResolution: String {
        #if targetEnvironment(macCatalyst)
        "1920x1088"
        #else
        "480x272"
        #endif
    }

    static func dictionary(for platform: NativePlatform) -> [String: String] {
        var result: [String: String] = [:]
        let alwaysSendResolved = platform != .n64 && platform != .dreamcast
            && !benchWantsStockOptions
        for option in NativeCoreOptions.options(for: platform)
        where option.key != NativeCoreOptions.genesisPad.key {
            if alwaysSendResolved {
                result[option.key] = value(option, for: platform)
                continue
            }
            let storageKey = key(platform: platform, option: option.key)
            guard let stored = UserDefaults.standard.string(forKey: storageKey),
                  option.choices.contains(where: { $0.value == stored })
            else { continue }
            result[option.key] = stored
        }
        // Dreamcast's CPU speed is always sent at its resolved value, not
        // only when changed: its per-platform default (75MHz effective on
        // tvOS) differs from the core's own baked-in 200, so an untouched
        // install relying on "send nothing" would silently run the wrong
        // speed on the Apple TV.
        if platform == .dreamcast, let clock = NativeCoreOptions.dreamcast.first {
            result[clock.key] = value(clock, for: platform)
        }
        result.merge(forcedOptions(for: platform)) { _, forced in forced }
        result.merge(restoredDefaults(for: platform)) { _, restored in restored }
        result.merge(qualityUpgrades(for: platform)) { _, upgrade in upgrade }
        #if DEBUG
        // Bench overrides land last so a single -cabinetBenchOption on the
        // command line can A/B one key against everything above it without
        // a rebuild. See NativeBenchHarness.
        result.merge(benchOptionOverrides) { _, override in override }
        #endif
        return result
    }

    #if DEBUG
    /// `-cabinetBenchOption "key=value;key2=value2"`, for measuring one
    /// option against the current defaults on a real device without a
    /// rebuild. Debug only, and empty unless the harness put it there.
    ///
    /// One semicolon-separated string rather than a repeated flag: the
    /// argument domain keeps only the last occurrence of a key, so
    /// repeating the flag would silently measure just the final pair.
    static var benchOptionOverrides: [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: "cabinetBenchOption")
        else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: ";") {
            guard let split = pair.firstIndex(of: "=") else { continue }
            out[String(pair[pair.startIndex..<split])] = String(pair[pair.index(after: split)...])
        }
        return out
    }
    #endif

    /// Options that are never a user choice, always sent, and never listed
    /// in `NativeCoreOptions.options(for:)`: not preferences, hard
    /// requirements this frontend imposes on a core.
    private static func forcedOptions(for platform: NativePlatform) -> [String: String] {
        switch platform {
        case .virtualBoy:
            // The Virtual Boy has TWO d-pads, and the core only reads the
            // right one from the analog stick when this is on. It defaults
            // to disabled, so without this the right pad is dead: its
            // digital ids are RetroPad L3 and R3, 14 and 15, which are
            // outside the range NativePlayerRenderer.setButton accepts,
            // so that route is not available either. Answered here rather
            // than exposed, since a controller with a missing d-pad is
            // not a preference.
            return ["vb_right_analog_to_digital": "enabled"]
        case .gb, .gbc:
            // Rumble carts (Pokemon Pinball and friends) are dead without
            // this. Gambatte sets `rumble_level = 0` before reading the
            // variable and follows it immediately with
            // `if (rumble_level == 0) deactivate_rumble();`, so an
            // unanswered key does not leave the core at its declared
            // default of 10, it explicitly turns rumble off. Same
            // defaults-gap class as N64's zeroed globals and PSP's
            // resolution. Answered with the option's own declared
            // default.
            //
            // This is a STRENGTH, 0 to 10, not an on/off switch. Whether
            // the player actually feels anything is still the one global
            // Rumble toggle in Settings, which the frontend checks in
            // rumbleSetState before any haptic fires; this only makes
            // sure the core still has something to report.
            return ["gambatte_rumble_level": "10"]
        case .psp:
            // cpu_core's declared default is "JIT", which cannot run in
            // this process (no dynamic-code entitlement). The core has
            // its own guard, System_GetPropertyBool(SYSPROP_CAN_JIT)
            // asks the frontend RETRO_ENVIRONMENT_GET_JIT_CAPABLE and
            // falls back to the IR interpreter when unanswered, but
            // that guard is upstream's to keep; the configuration this
            // app benched and ships is stated here rather than
            // inherited. "IR JIT" is the source-exact value that means
            // the IR interpreter (libretro.cpp maps it to
            // CPUCore::IR_INTERPRETER), the middle option between the
            // slow plain interpreter and the impossible dynarec, and
            // the one the Mac lab measured 2026-08-24.
            //
            // internal_resolution is this core's defaults trap, the
            // same class N64's zeroed globals were. g_Config.Load's own
            // default is 0, "Auto (native)", which sizes the render to
            // the DISPLAY, and a libretro frontend never reports a
            // display size, so pixelWidth/pixelHeight stay 0x0: the
            // game runs, audio streams, and every frame is dropped as
            // zero-sized before readback. Found on the Apple TV
            // 2026-08-24, first PPSSPP boot. "480x272" is the option's
            // own declared default (1x), the value RetroArch would have
            // answered.
            //
            // Everything else stays at the core's own defaults:
            // hardware rendering (ppsspp_software_rendering defaults
            // disabled), no frameskip.
            return [
                "ppsspp_cpu_core": pspCpuCore,
                "ppsspp_internal_resolution": pspInternalResolution,
            ]
        case .nds:
            // boot_directly is this core's defaults trap: the option
            // table declares "enabled" but the unanswered C global is
            // DirectBoot = 0, which boots to the DS firmware menu, and
            // with the compiled-in FreeBIOS there is no firmware menu,
            // so nothing boots at all.
            //
            // screen_layout stays Top/Bottom and screen_gap stays 0 so
            // the core always delivers the same stacked 256x384 frame.
            // Presentation is this app's job: the player slices that
            // frame into the two screens and places them per platform,
            // so the core's other layouts must never change the
            // geometry underneath it.
            //
            // touch_mode is Touch on iOS, where the screen's own
            // touches feed RETRO_DEVICE_POINTER directly, and Joystick
            // on tvOS, where the right stick moves the core's own
            // cursor: the only touch a controller-first platform has.
            //
            // threaded_renderer is a hard requirement, not a tuning
            // choice: it moves 3D rasterization off the thread
            // interpreting two ARM CPUs, and the bench measured it
            // nearly halving worst-frame time (p99 8.2ms to 4.5ms on
            // the build machine). console_mode pins DS because DSi
            // mode needs NAND files this app does not stage, and the
            // core's own savestate code refuses DSi mode anyway.
            #if os(tvOS)
            let touchMode = "Joystick"
            #else
            let touchMode = "Touch"
            #endif
            //
            // The five jit keys are Mac-only, matching the one platform
            // whose melonDS is built with JIT_ARCH=aarch64; iOS and tvOS
            // compile no recompiler at all, so the keys are not declared
            // there. All five values are upstream's own declared
            // defaults, restated rather than inherited: the core's
            // libretro layer only assigns Config::JIT_* when the
            // variable is answered, and Config.cpp starts JIT_Enable at
            // false, so an unanswered melonds_jit_enable silently keeps
            // the interpreter no matter what was compiled in.
            var ds = [
                "melonds_console_mode": "DS",
                "melonds_boot_directly": "enabled",
                "melonds_screen_layout": "Top/Bottom",
                "melonds_screen_gap": "0",
                "melonds_touch_mode": touchMode,
                "melonds_threaded_renderer": "enabled",
            ]
            #if targetEnvironment(macCatalyst)
            ds["melonds_jit_enable"] = "enabled"
            ds["melonds_jit_block_size"] = "32"
            ds["melonds_jit_branch_optimisations"] = "enabled"
            ds["melonds_jit_literal_optimisations"] = "enabled"
            ds["melonds_jit_fast_memory"] = "enabled"
            #endif
            return ds
        case .threeDO:
            // opera_bios is the defaults trap at its purest: the option's
            // declared default is NULL, its value must be a BIOS filename,
            // and unanswered it leaves opts->bios NULL, which is "no BIOS
            // ROM found" and no boot at all. NativeLauncher stages any
            // 1MB firmware RomM has for the platform under exactly this
            // name, so the two halves of the contract live in this app
            // and the answer is always a file that exists.
            //
            // nvram_storage is a declared-default-versus-code-fallback
            // mismatch (the table says "per game", the unanswered
            // fallback is shared); forced to shared deliberately. Each
            // game already has its own save directory here, so shared
            // is per-game anyway, and it buys a fixed filename
            // (opera/shared/nvram.0.srm) the save sync can rely on the
            // way Sega CD's 4Mbit_cart.brm already is.
            //
            // active_devices stays at Opera's own default of 1: its
            // option text documents a bug where more than one emulated
            // controller makes some games ignore input entirely.
            // supportsSecondPlayer is false for the platform to match.
            //
            // opera_font is deliberately NOT answered: its value must
            // also be a filename, the Kanji ROM matters only to some
            // Japanese games, and RomM has no such file to stage, so
            // silence (which clears rom2) is the correct answer rather
            // than naming a file that does not exist.
            return [
                "opera_bios": "panafz10.bin",
                "opera_nvram_storage": "shared",
                "opera_nvram_version": "0",
                "opera_active_devices": "1",
            ]
        case .psx:
            // Without an answer for these keys PCSX ReARMed's
            // load_memcards() skips card setup entirely (memcard_type
            // stays NONE, confirmed in the vendored libretro.c), leaving
            // the game with no card at all. Card 1 as "libretro" is what
            // exposes it through RETRO_MEMORY_SAVE_RAM for the memory
            // card sync; card 2 stays explicitly off rather than
            // "shared", which would write a .mcd into the per-launch
            // temp directory the next launch deletes.
            //
            // drc is answered only on the Mac, and only because that is
            // the one platform whose core has a recompiler compiled in:
            // build-core.sh passes DYNAREC=ari64 there and nowhere else,
            // so on iOS and tvOS the key is not even a declared option.
            // The core would pick the recompiler unprompted (it treats
            // an unanswered variable as "enabled"), but leaving the
            // engine to a default is how the Mac ended up on
            // interpreters without anyone noticing.
            var psx = [
                "pcsx_rearmed_memcard1": "libretro",
                "pcsx_rearmed_memcard2": "none",
            ]
            #if targetEnvironment(macCatalyst)
            psx["pcsx_rearmed_drc"] = "enabled"
            #endif
            return psx
        case .dreamcast:
            // Internal resolution, Mac only. Flycast defaults to the
            // console's own 640x480 and Cabinet never set it, so a
            // Dreamcast game has been rendering at 1x and being scaled
            // to a 5K panel. 3x measured FASTER per frame than 1x on
            // this machine, at both clocks, which reads as odd until you
            // remember the cost that matters here is not fill rate.
            // Kept to 3x rather than higher because that is where the
            // measurements stop and a number nobody benched is a guess.
            //
            // Anisotropic filtering is deliberately absent: Flycast
            // already defaults it to 4.
            // Threaded rendering back ON, reversing the override this
            // returned between d49008d and 2026-08-16. That override was
            // added on the theory that running the core synchronously
            // would tie audio production to this frontend's frame
            // cadence, and its own comment said to take it back out if
            // the drops did not fall to zero. Traced on device: they did
            // not. The core ran at 1.0x to 2.9x realtime, averaging
            // 84,090 audio frames a second against 44,100, and the
            // picture rate fell in exact inverse proportion, 60fps
            // wherever the ratio was 1.0 and 30fps wherever it was 2.0.
            //
            // Synchronous is the mode with no brake. Flycast's own
            // WriteSample drops samples on overflow rather than
            // blocking, so audio applies no backpressure, and
            // Emulator::render's non-threaded path runs the SH4 until
            // either the game flips its framebuffer or fifty
            // milliseconds of emulated time have passed
            // (Emulator::vblank, core/emulator.cpp). Fifty milliseconds
            // is 2,205 audio frames at 44.1kHz, which is the "about
            // 2,207 audio frames per retro_run" already recorded in
            // issue #6: that measurement was the timeout firing, not the
            // game running slowly. A frontend pacing one retro_run per
            // frame cannot see a call that silently advanced three.
            //
            // Threaded mode does have a brake, and it is this frontend's
            // own frame cadence: the emulator thread enqueues render
            // messages into a queue bounded at four
            // (Renderer_if.cpp's PvrMessageQueue::enqueue) and blocks
            // when they back up, so it can only run as fast as this app
            // consumes frames.
            //
            // The CPU speed is NOT forced here: it is the visible
            // Dreamcast option (NativeCoreOptions.dreamcast), always sent
            // at its resolved value by dictionary(for:) above, with a
            // per-platform default measured on device.
            var dc = ["reicast_threaded_rendering": "enabled"]
            #if targetEnvironment(macCatalyst)
            dc["reicast_internal_resolution"] = "1920x1440"
            #endif
            return dc
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
            // Forced, not a Settings choice. The RDP plugin is pinned to
            // GLideN64, the only one of the core's three RDP plugins with
            // a GLES3 hardware-render path this frontend supports.
            //
            // cpucore is the cached interpreter, not the pure one. This
            // used to read pure_interpreter, on the belief that anything
            // else needed a JIT entitlement this app does not have. That
            // is true of dynamic_recompiler and false of the cached
            // interpreter: `cached_interp_init_block` allocates its block
            // with a plain malloc (mupen64plus-core's cached_interp.c),
            // while the malloc_exec that maps PROT_EXEC pages is reached
            // only through dynarec_init_block, wired up in r4300_core.c
            // under EMUMODE_DYNAREC. The cached interpreter emits no code
            // at all, it just stops re-decoding every instruction on
            // every execution. Checked in the core's own source
            // 2026-08-17. Upstream reports a few titles that run only on
            // the pure interpreter (libdragon homebrew, mupen64plus-core
            // issue #738), so this is the one option here with a real
            // compatibility risk rather than a pure win.
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
                "mupen64plus-cpucore": n64CpuCore,
                "mupen64plus-rdp-plugin": "gliden64",
                "mupen64plus-MaxTxCacheSize": "8000",
                // Framebuffer emulation is OFF here and ON for the Mac
                // (n64MacFramebufferTrial below), and 2026-08-30 is when
                // that stopped being an open question.
                //
                // The history: turning it on together with both RDRAM
                // copies was tried on 2026-08-17 to explain missing
                // scenery in Hydro Thunder, made that game strictly
                // worse, the boat and water stopped drawing at all, and
                // was reverted without learning which of the three did
                // it. Running the experiment this comment asked for,
                // EnableFBEmulation alone with both copies explicitly
                // Off, FIXED Hydro Thunder's missing walls and ramps on
                // the Mac (Marcus, 2026-08-30). So framebuffer emulation
                // was never the problem; one or both of the copies was,
                // and the August result was the copies' fault.
                //
                // It stays off on iOS and tvOS only because those two
                // have not been tested with it. That is a device pass
                // waiting to happen, not a decision that they should
                // differ.
                //
                // The cause is NOT established, and the obvious theory was
                // checked and rejected: GLideN64 does treat framebuffer 0
                // as its output (DisplayWindowMupen64plus::
                // _getDefaultFramebuffer returns ObjectHandle::null), but
                // GLSM redirects any bind of 0 to the frontend's own FBO
                // (glsm.c's rglBindFramebuffer, against a
                // default_framebuffer captured from get_current_framebuffer
                // in glsm_state_setup), and this app creates gFBO before
                // that setup runs. So "it composites somewhere we never
                // read" does not survive reading the code.
                //
                // The untested candidate is the two buffer copies rather
                // than framebuffer emulation itself: CopyColorToRDRAM and
                // CopyDepthToRDRAM do their own GPU-to-CPU readback through
                // whichever ColorBufferReader implementation GLideN64
                // picks at runtime, and several of those rely on buffer
                // storage or EGL image, neither of which exists on iOS
                // GLES3. All three options were turned on together, so
                // which one broke it is unknown. Anyone retrying this
                // should set EnableFBEmulation alone with both copies
                // explicitly Off, and change one thing at a time.
                // Render at the N64's own resolution. Left unanswered,
                // retro_screen_width/height keep their static 640x480
                // (libretro.c:145) rather than the 320x240 the core's own
                // options table documents as the 4:3 default, so this app
                // has been rendering four times the pixels the core meant
                // to. That is four times the fragment work for GLideN64,
                // four times the bytes through the synchronous glReadPixels
                // measured at 1.8ms rising to 7.2ms in heavy scenes, and
                // four times the Metal upload. Passing 320x240 also trips
                // the core's own guard at libretro.c:1441, which forces
                // EnableNativeResFactor to 1 for low resolutions, which is
                // what makes GLideN64 render natively rather than blit a
                // larger image down.
                //
                // The key is 43screensize rather than 169screensize
                // because `aspect` is likewise unanswered, leaving
                // AspectRatio at its static 0 and screen_size_key at the
                // 4:3 one it is initialized to (libretro.c:917).
                "mupen64plus-43screensize": "320x240",
                // Let the core tell us when a frame is unchanged. With
                // this off, every retro_run produces a frame and every
                // frame pays the full readback; with it on, a duplicate
                // arrives as a null pointer that videoRefresh already
                // handles by counting a dupe and returning before any GL
                // work. The trace currently reports hw_dupes: 0, so this
                // saving is being left entirely on the table.
                "mupen64plus-FrameDuping": "True",
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
            ].merging(n64MacFramebufferTrial) { _, trial in trial }
        default:
            return [:]
        }
    }

    /// Framebuffer emulation, on for the Mac, with both RDRAM copies
    /// explicitly off.
    ///
    /// That note records turning EnableFBEmulation on together with both
    /// RDRAM copies on 2026-08-17, which made Hydro Thunder strictly
    /// worse, and says plainly that anyone retrying it should set
    /// EnableFBEmulation alone with both copies explicitly Off and
    /// change one thing at a time. This is that, and it worked: Hydro
    /// Thunder's walls and ramps came back, and Mario Kart 64 was
    /// unaffected. The copies were what broke that game in August.
    ///
    /// Catalyst only, so the iPhone and the Apple TV keep running the
    /// configuration they were verified on while this is evaluated. If
    /// it holds up, promoting it to every platform is a separate
    /// decision with its own device pass, not a side effect of a Mac
    /// investigation.
    private static var n64MacFramebufferTrial: [String: String] {
        #if targetEnvironment(macCatalyst)
        return [
            "mupen64plus-EnableFBEmulation": "True",
            "mupen64plus-EnableCopyColorToRDRAM": "Off",
            "mupen64plus-EnableCopyDepthToRDRAM": "Off",
        ]
        #else
        return [:]
        #endif
    }

    /// Core defaults this app was silently not applying, restored
    /// 2026-08-17.
    ///
    /// Kept apart from `forcedOptions` on purpose. That function is hard
    /// requirements this frontend imposes on a core, things that are not
    /// anybody's preference and never were. This one is different: every
    /// entry here is a value the core's own option table already calls its
    /// default, which never took effect because `LibretroFrontend` answers
    /// neither `SET_VARIABLES` nor `SET_CORE_OPTIONS_V2`, so the key was
    /// never asked for and the core ran on whatever its C global was
    /// initialised to instead. Under RetroArch none of these would differ.
    ///
    /// Each was found by running the core headless under
    /// `tools/bench/libretro_bench`, which answers exactly what this
    /// frontend answers, once with that silence and once with the
    /// documented defaults filled in, and comparing frame hashes. The
    /// per-platform comments record what actually differed.
    ///
    /// Nintendo 64 and Dreamcast are deliberately absent and must stay
    /// absent: both are separate in-flight investigations, and a default
    /// restored underneath either of them would land in the middle of
    /// someone else's measurements.
    static func restoredDefaults(for platform: NativePlatform) -> [String: String] {
        if benchWantsStockOptions { return [:] }
        switch platform {
        case .nes:
            // Three C globals FCEUmm never initialises to the values its
            // own option table calls the defaults, all found 2026-08-17
            // with tools/bench/libretro_bench and confirmed in the core's
            // source. Same gap-class as N64's zeroed globals: the core
            // declares a default, the frontend never answers the key, and
            // the declared default is not what the global was born with.
            //
            // The palette is the big one. `current_palette` is a static 0
            // (libretro.c:327), and 0 is not the NES palette, it is
            // palettes[0], the third-party "asqrealc" set; the core's own
            // default is the separate PAL_DEFAULT sentinel
            // (PAL_INTERNAL + 1, libretro.c:458), which is the branch that
            // generates the real NES colours. Measured on a Contra frame:
            // 98.3% of pixels differed, black sat at (16,16,16) instead of
            // (0,0,0) and grass rendered olive (88,100,0) instead of green
            // (0,150,0). Every NES game this app has ever run has been
            // showing a washed-out third-party palette.
            //
            // Overscan: the NES draws 240 lines but the top and bottom 8
            // were behind the bezel on real hardware, which is why the
            // core's own default crops them and why RetroArch, Nestopia
            // and Mesen all ship cropped. Unanswered, `overscan_v_top` and
            // `overscan_v_bottom` stay 0 and the full 256x240 buffer is
            // handed over, garbage rows included, and the picture is then
            // aspect-fitted as if those rows were content.
            //
            // Volume: the core inits `sndvolume` to 150 of 256
            // (libretro.c:4038) but documents 7-of-7 as the default, which
            // its own arithmetic turns into 179. Answering it is a 19%
            // level increase, not a tone change.
            return [
                "fceumm_palette": "default",
                "fceumm_overscan_v_top": "8",
                "fceumm_overscan_v_bottom": "8",
                "fceumm_overscan_h_left": "0",
                "fceumm_overscan_h_right": "0",
                "fceumm_sndvolume": "7",
            ]
        case .virtualBoy:
            // The rest of Beetle VB's table at its declared defaults. The
            // CPU emulation choice stays on "fast": "accurate" exists for
            // a handful of timing-sensitive titles and costs speed, and
            // nothing here has been measured to need it.
            return [
                "vb_3dmode": "anaglyph",
                "vb_cpu_emulation": "fast",
                "vb_opposite_directions": "disabled",
                "vb_sidebyside_separation": "0",
            ]
        case .threeDO:
            // The rest of Opera's table at its own declared defaults,
            // read from libretro_core_options.c. Every getval here has a
            // real in-code fallback, but two option-shaped landmines are
            // handled in forcedOptions (bios, nvram_storage) and the two
            // performance/quality levers are exposed Settings, so this
            // list is everything else, answered deliberately. The
            // overclock and hi-res keys are absent because they are the
            // exposed options and this dictionary merges over stored
            // choices.
            return [
                "opera_mem_capacity": "21",
                "opera_random_seed": "random",
                "opera_cd_speed": "unbounded",
                "opera_region": "ntsc",
                "opera_vdlp_pixel_format": "RGB565",
                "opera_vdlp_bypass_clut": "disabled",
                "opera_madam_matrix_engine": "hardware",
                "opera_swi_hle": "disabled",
                "opera_dsp_threaded": "disabled",
                "opera_hide_lightgun_crosshairs": "disabled",
                "opera_kprint": "disabled",
            ]
        case .vectrex:
            // vecx's software renderer sizes its point stamp,
            // `point_size`, only inside the branch that answers
            // `vecx_res_multi`; unanswered, the static stays 0 and every
            // vector endpoint is drawn degenerately. Verified with
            // tools/lab/lab bench on Mine Storm before this core ever
            // reached a device: the unanswered run and the answered run
            // hash differently, and the unanswered frame's boot text is
            // smeared into unreadable blobs. The four scale/shift keys
            // have real in-code fallbacks matching their declared
            // defaults, sent anyway so every variable in the core's table
            // is answered deliberately rather than by accident.
            return [
                "vecx_res_multi": "1",
                "vecx_scale_x": "1",
                "vecx_scale_y": "1",
                "vecx_shift_x": "0",
                "vecx_shift_y": "0",
            ]
        case .atari2600:
            // Checked clean, recorded so nobody re-checks: Stella 2014's
            // check_variables pre-seeds every global with its documented
            // default before reading the key, and the macOS bench hashes
            // byte-identical between an unanswered run and one answering
            // the full table (Pitfall, 600 frames). Sent anyway so every
            // variable is answered deliberately. mix_frames is absent
            // here because it is the platform's one exposed Setting, and
            // this dictionary merges after (and over) stored choices.
            //
            // The paddle keys are answered at their defaults but no
            // paddle control exists yet; v1 is pad-only. Paddle games
            // (Kaboom!, Circus Atari) are a roadmap item, and the arcade
            // spinner overlay is the obvious donor when it happens.
            return [
                "stella2014_color_depth": "16bit",
                "stella2014_palette": "standard",
                "stella2014_low_pass_filter": "disabled",
                "stella2014_low_pass_range": "60",
                "stella2014_paddle_digital_sensitivity": "50",
                "stella2014_paddle_analog_sensitivity": "50",
                "stella2014_paddle_analog_response": "linear",
                "stella2014_paddle_analog_deadzone": "15",
                "stella2014_stelladaptor_analog_sensitivity": "20",
                "stella2014_stelladaptor_analog_center": "0",
            ]
        case .arcade:
            // FBNeo's two audio interpolation levels, both declared
            // "4-point 3rd order" in its own option table and neither ever
            // reaching that value, because the globals are born elsewhere:
            // `INT32 nInterpolation = 1` and `INT32 nFMInterpolation = 0`
            // (burn.cpp:79-80). So sample playback has been running at
            // 2-point and FM synthesis at no interpolation at all, on
            // boards whose whole sound is FM (Neo Geo's YM2610, CPS's
            // YM2151, the CAVE boards' YM2610B).
            //
            // The strings must match FBNeo's own list exactly; its parser
            // falls through to the top level on anything unrecognised
            // (retro_common.cpp:1950, :1962), which would work by accident
            // and stop working the moment somebody tightened it.
            //
            // `fbneo-samplerate` is left alone deliberately even though it
            // has the same shape of mismatch (declared 48000, unanswered
            // 44100). The core's own source carries a comment that Neo Geo
            // CD's CDDA playback has issues at anything but 44100, and this
            // frontend fixes its audio format when playback starts, so that
            // one is a real risk for a marginal gain.
            return [
                "fbneo-sample-interpolation": "4-point 3rd order",
                "fbneo-fm-interpolation": "4-point 3rd order",
            ]
        case .tg16, .tgCD:
            // Beetle PCE Fast renders scanlines 0 through 242 unless told
            // where the picture starts, so this app has been handing the
            // renderer a 256x243 frame whose first three rows are always
            // black. Verified 2026-08-17: rows 3...242 of the current
            // output are byte-identical to the whole of the corrected
            // 240-row output, so the only thing those rows carry is a
            // black band at the top and a 1.25% vertical stretch error in
            // the aspect fit. 3 and 242 are the core's own documented
            // defaults.
            return [
                "pce_fast_initial_scanline": "3",
                "pce_fast_last_scanline": "242",
            ]
        case .ngpc:
            // The Neo Geo Pocket BIOS carries a language flag and Beetle
            // NGP's `setting_ngp_language` global is a static 0, which is
            // Japanese; the core's own documented default is english.
            // Changed both picture and audio in the harness on SNK vs
            // Capcom, which is a bilingual cart booting in the wrong one.
            return ["ngp_language": "english"]
        case .gb, .gbc:
            // A Game Boy Color's screen was far darker and less saturated
            // than a modern display, and Gambatte ships a correction for
            // exactly that, defaulted on for CGB titles. Its `colorCorrection`
            // global is a static 0 (libretro.cpp:2320) and the key was never
            // answered, so every GBC game has been rendering raw, oversaturated
            // values. Inert on true mono Game Boy roms, which is why it is
            // safe to send for both platforms rather than only .gbc.
            return ["gambatte_gbc_color_correction": "GBC only"]
        case .saturn:
            // `bool setting_midsync;` is an uninitialised global
            // (libretro_settings.c:17), so it is false, while the core's
            // own table declares it enabled. It is what feeds
            // `AllowMidSync` (mednafen/ss/ss.c:1502), the flag that lets
            // the emulator break out mid-frame to re-read input instead of
            // sampling it once per frame, which is worth roughly a frame
            // of input latency on a system where that is felt. Measured at
            // 1.01x core time, with byte-identical video and audio, on the
            // heaviest core in this app.
            return ["beetle_saturn_midsync": "enabled"]

        // Saturn's scanline-crop pair is deliberately absent from the
        // midsync entry above, checked and turned down rather than
        // missed. Beetle Saturn has the same unanswered
        // scanline pair Beetle PCE Fast does (initial 8, last 231, which
        // would take Die Hard Arcade from 704x240 to 704x224), but the
        // rows it would remove are not the same kind of rows: PCE's three
        // are pure black in every frame checked, while Saturn's bottom
        // eight carry real drawn pixels, 146 to 154 distinct colours per
        // row. Cropping them is a judgement about what a CRT would have
        // hidden, not a correction of something plainly wrong, so it is
        // Marcus's call and not this pass's.
        case .psx:
            // Gaussian is what the PlayStation's SPU actually did: the
            // hardware interpolates sample playback with a fixed 4-point
            // Gaussian kernel, and "simple" is pcsx_rearmed's cheap
            // approximation of it, kept as its default for handhelds that
            // could not afford the real thing. Measured 2026-08-17 over
            // Crash Bandicoot 2's attract demo: 0.98x the core time of
            // "simple", inside run-to-run noise, for audio that matches
            // the hardware.
            return ["pcsx_rearmed_spu_interpolation": "gaussian"]
        default:
            return [:]
        }
    }

    /// Deliberate choices above what the core itself defaults to, each one
    /// bought with a measured cost rather than added because the option
    /// existed.
    ///
    /// Kept separate from `restoredDefaults` because the two need different
    /// arguments. That one only has to show the core was not in the state
    /// it claimed. This one has to show the upgrade is worth what it costs,
    /// and every entry below carries the number it was judged on, measured
    /// through `tools/bench/libretro_bench` and then confirmed against real
    /// frame budget on an iPhone with `tools/bench/sweep.sh`.
    ///
    /// What is deliberately NOT here: anything that changes what the
    /// hardware did rather than how faithfully it is reproduced. CPU
    /// overclocks, sprite-limit removal, NTSC composite filters, interframe
    /// blending and widescreen hacks were all measured and all left alone.
    /// Cabinet already offers the look-based ones as shaders, which is
    /// where a look belongs.
    ///
    /// Nintendo 64 and Dreamcast are absent and must stay absent.
    static func qualityUpgrades(for platform: NativePlatform) -> [String: String] {
        if benchWantsStockOptions { return [:] }
        switch platform {
        case .vectrex:
            // Vector lines rasterised at 4x, 1320x1640 instead of 330x410,
            // which is what makes them look like lines instead of stair
            // steps on a phone screen. Free where it can be measured
            // headless: the macOS bench holds 0.26ms per frame at both
            // multipliers, because the vector count is what costs and it
            // does not change. The device pays only the larger texture
            // upload, the same class of cost PS1's 2x already ships.
            return ["vecx_res_multi": "4"]
        case .nes:
            // FCEUmm's "Low" runs the APU at the output rate; 1 and 2 run
            // it at the CPU clock and decimate afterwards, which is the
            // accurate way and the reason the option exists. Not a filter
            // and not a preference: `FCEUI_SetSoundQuality` feeds
            // `FSettings.soundq`, which selects the emulation path.
            // Measured 1.27x core time, against a core using 8.9% of an
            // NES frame budget on an iPhone Air, so the whole increase is
            // about three percent of a frame.
            return ["fceumm_sndquality": "Very High"]
        case .psx:
            // Double the PlayStation's own render resolution, 512x240 to
            // 1024x480, through pcsx_rearmed's NEON GPU. Measured over a
            // 260-second run of Crash Bandicoot 2's attract demo (its own
            // recorded gameplay, so it is real 3D and it replays the same
            // way every time): p99 of frame budget goes from 53.3% to
            // 64.4%, audio holds at exactly 44,098 frames a second against
            // 44,100 declared, and the OS stayed at thermal nominal
            // throughout. The median barely moves at all; the whole cost
            // lands in heavy scenes and in this app's own texture upload,
            // which goes from 0.20ms to 0.50ms.
            //
            // **iOS only, deliberately.** The Apple TV 4K 3rd gen is
            // fanless and throttles itself under sustained load on a
            // roughly two-minute rhythm, measured directly during the
            // Dreamcast investigation (a fixed-work calibration loop
            // slowed by 40% with nobody even playing). Spending another
            // eleven points of frame budget there, on a box already known
            // to be about 15% over its heat budget, is exactly the wrong
            // move to make without measuring it, and neither Apple TV was
            // available to this pass. tvOS keeps native resolution until
            // somebody runs the same 260-second trace on the hardware.
            //
            // 32-bit output rides along with it. The PlayStation renders
            // 15-bit internally, so this is not extra precision in the
            // rasteriser, but full-motion video is 24-bit source material
            // and a 16-bit output path crushes it; this is also what moves
            // Cabinet's renderer off its RGB565 unpack pass onto a direct
            // upload. Measured on the same 260-second attract demo, and
            // the two do NOT compound the way the macOS bench implied
            // (it had them at 2.40x combined against 1.68x for resolution
            // alone): 2x alone is 65.0% of budget at p99 on a fresh
            // control run, 2x with 32-bit output is 67.8%. Under three
            // points, audio holding 44,098 frames a second against 44,100,
            // thermal nominal throughout.
            //
            // Measured on the Apple TV 4K 3rd gen too, once that device
            // became available: 51.3% of budget at p99 native against
            // 58.8% with both options, a 7.5 point cost, which is
            // narrower than the iPhone's own 14.5. Audio at exactly
            // realtime, and the 261-second trace shows no drift at all
            // across its own duration, core time holding 6.255ms median
            // in the first window and 6.271ms in the last. The thermal
            // duty-cycling the Dreamcast work measured on that box needs
            // a workload pinning the SH4 interpreter near 100%; PS1 at
            // 40% of budget never gets it warm enough. So this ships on
            // both platforms rather than iOS alone.
            return [
                "pcsx_rearmed_neon_enhancement_enable": "enabled",
                "pcsx_rearmed_rgb32_output": "enabled",
            ]
        case .snes:
            // Mode 7 planes rendered at 4x horizontally and vertically,
            // 1024x448 instead of 256x224, which is sixteen times the
            // pixels for the frames that use it.
            //
            // Measured on device on F-Zero, which is Mode 7 for
            // essentially its whole running time, same 45-second window
            // both ways: p95 of frame budget 20.4% to 33.1%, p99 37.7%,
            // core 2.72ms to 4.24ms, upload 0.34ms to 0.57ms, audio
            // holding 32,032 frames a second against 32,040 declared, and
            // the OS at thermal nominal.
            //
            // That core figure is 1.56x, NOT the 1.02x an earlier macOS
            // bench reported. The bench run had F-Zero sitting in menus
            // for its whole measurement window, so it timed Mode 7 being
            // switched on while Mode 7 was never drawn. Worth remembering:
            // a feature that only costs anything while it is active has to
            // be measured with it active, and the harness will happily
            // report a confident number for a window where nothing
            // happened.
            //
            // A game that only uses Mode 7 for one stage (Contra III)
            // stays at 256x224 for everything else, with a single size
            // transition in 3000 frames rather than per-frame thrash, and
            // the option is inert until Mode 7 is actually drawn.
            //
            // Not gated to iOS, unlike the PS1 and Genesis upgrades: those
            // sit at 64% and 37% of budget on the faster device, this one
            // leaves roughly two thirds of the frame free.
            //
            // Aspect is safe: snes9x reports a fixed 4:3 from
            // get_aspect_ratio regardless of buffer size.
            return ["snes9x_mode7_hires": "4x_hv"]
        case .genesis, .segaCD:
            // Nuked OPN2 is the die-shot-accurate YM2612; MAME's model is
            // the fast approximation, and it is the default purely because
            // of what the accurate one costs. This is the textbook case of
            // an accuracy option switched off for performance on hardware
            // that no longer needs to make that trade.
            //
            // Measured 2.31x to 2.33x the core's time across Gunstar
            // Heroes, and video output was byte-identical in every run,
            // which matters more than it sounds: Genesis games poll the
            // YM2612's status register for timing, so a different chip
            // model could have changed game behaviour and demonstrably
            // does not here.
            //
            // Scoped to the two platforms with the chip. Master System and
            // Game Gear share this core but have no YM2612 at all, and the
            // option measured at 1.01x with identical audio on Game Gear,
            // so sending it there would be noise in the settings rather
            // than a change. 32X is PicoDrive, a different core entirely.
            //
            // This was iOS-only for a while, on an estimate that the
            // fanless A15 Apple TV would land near 55% to 75% of budget
            // and might not afford it. The estimate was wrong and the
            // measurement is better: 43.1% at p99 on Gunstar Heroes and
            // 42.5% on Thunder Force III, against a 25.9% MAME baseline,
            // audio at exactly realtime and thermal nominal. So it ships
            // on both platforms, and Genesis sounds the same in the
            // living room as it does in your hand, which is what CLAUDE.md
            // asks for.
            return ["genesis_plus_gx_ym2612": "nuked (ym2612)"]
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
        // Opera is the third victim: its PBUS_DEVICES array is a zeroed
        // global, zero is RETRO_DEVICE_NONE, and lr_input_update skips
        // any port whose device is NONE, so without this call the core
        // polls no input at all (found on device: Gex launched fine and
        // ignored every control). RetroArch masks it by always
        // negotiating the device for every port.
        if platform == .dreamcast || platform == .n64 || platform == .threeDO { return 1 }
        let option = NativeCoreOptions.genesisPad
        guard NativeCoreOptions.options(for: platform).contains(where: { $0.key == option.key })
        else { return 0 }
        return UInt32(value(option, for: platform)) ?? 0
    }

}
