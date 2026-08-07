import Foundation

/// The shader list started as RomM/EmulatorJS's own bundled set per
/// docs/scope-native-core-settings.md, then got culled on device: the two
/// ScaleHQ scalers and crt-geom looked bad enough in this Metal port that
/// Marcus dropped them on sight (2026-08-07). SABR and four CRT variants
/// survived, plus "Sharp" as the unfiltered default. One list for every
/// native core, no per-shader filtering yet. A choice stored under a
/// dropped shader's old raw value simply fails the enum init and falls
/// back to Sharp.
enum NativeShader: String, CaseIterable, Identifiable {
    case sharp
    case sabr
    case crtAperture
    case crtEasymode
    case crtMattias
    case crtBeam
    case crtCaligari

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sharp: return "None"
        case .sabr: return "SABR"
        case .crtAperture: return "CRT (aperture)"
        case .crtEasymode: return "CRT (easymode)"
        case .crtMattias: return "CRT (mattias)"
        case .crtBeam: return "CRT (beam)"
        case .crtCaligari: return "CRT (caligari)"
        }
    }

    /// The Metal fragment function this shader draws with. `.sharp` reuses
    /// the frontend's original passthrough function rather than a
    /// `shader_`-prefixed one of its own.
    var fragmentFunctionName: String {
        switch self {
        case .sharp: return "libretro_fragment"
        case .sabr: return "shader_sabr_fragment"
        case .crtAperture: return "shader_crt_aperture_fragment"
        case .crtEasymode: return "shader_crt_easymode_fragment"
        case .crtMattias: return "shader_crt_mattias_fragment"
        case .crtBeam: return "shader_crt_beam_fragment"
        case .crtCaligari: return "shader_crt_caligari_fragment"
        }
    }

    private static func key(for core: NativeCore) -> String {
        "com.mmagtech.RommApp.nativeShader.\(core.storageKey)"
    }

    /// Stored per core, not per game, matching how core options are
    /// inherently core-scoped already.
    static func current(for core: NativeCore) -> NativeShader {
        UserDefaults.standard.string(forKey: key(for: core)).flatMap(NativeShader.init) ?? .sharp
    }

    static func setCurrent(_ shader: NativeShader, for core: NativeCore) {
        UserDefaults.standard.set(shader.rawValue, forKey: key(for: core))
    }
}
