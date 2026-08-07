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

/// The hand-picked option subsets per core, read from each core's real
/// `RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2` source rather than guessed.
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

    static func options(for core: NativeCore) -> [NativeCoreOption] {
        switch core {
        case .fbneo: return fbneo
        case .beetleSaturn: return beetleSaturn
        }
    }
}

/// Per-core option values, stored in UserDefaults under a key namespaced
/// by core and libretro key. Values fall back to the option's own default
/// when unset, matching how the core itself treats a missing key.
enum NativeCoreOptionsStore {
    private static func key(core: NativeCore, option: String) -> String {
        "com.mmagtech.RommApp.nativeCoreOption.\(core.storageKey).\(option)"
    }

    static func value(_ option: NativeCoreOption, for core: NativeCore) -> String {
        let stored = UserDefaults.standard.string(forKey: key(core: core, option: option.key))
        // A stored value the option no longer lists is discarded, not
        // trusted: an early build saved values FBNeo doesn't accept, and
        // anything stale from that build must fall back to the default
        // rather than keep reaching the core forever.
        guard let stored, option.choices.contains(where: { $0.value == stored }) else {
            return option.defaultValue
        }
        return stored
    }

    static func setValue(_ value: String, for option: NativeCoreOption, core: NativeCore) {
        UserDefaults.standard.set(value, forKey: key(core: core, option: option.key))
    }

    /// The options dictionary for a core, ready for
    /// `LibretroFrontend.setCoreOptions:`. Deliberately only the keys
    /// someone actually changed in Settings, not every option at its
    /// default: sending a value the core recognizes still changes how
    /// some drivers behave versus never calling `SET_CORE_OPTIONS`/
    /// `GET_VARIABLE` for that key at all, since `LibretroFrontend` still
    /// doesn't answer `SET_CORE_OPTIONS_V2` (a real, already-known gap).
    /// Games nobody has touched a core option for get exactly the empty
    /// dictionary this app always sent before this feature existed.
    static func dictionary(for core: NativeCore) -> [String: String] {
        var result: [String: String] = [:]
        for option in NativeCoreOptions.options(for: core) {
            let storageKey = key(core: core, option: option.key)
            guard let stored = UserDefaults.standard.string(forKey: storageKey),
                  option.choices.contains(where: { $0.value == stored })
            else { continue }
            result[option.key] = stored
        }
        return result
    }
}
