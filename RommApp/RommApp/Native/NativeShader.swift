import Foundation

/// The shader list started as RomM/EmulatorJS's own bundled set per
/// docs/scope-native-core-settings.md, then got culled on device: the two
/// ScaleHQ scalers and crt-geom looked bad enough in this Metal port that
/// Marcus dropped them on sight (2026-08-07). SABR and four CRT variants
/// survived, plus "Sharp" as the unfiltered default. Two handheld-specific
/// shaders (LCD, Game Boy) joined 2026-08-08, gated to the platforms they
/// actually apply to by `NativeShader.available(for:)`, not offered
/// everywhere like the original six. A choice stored under a dropped
/// shader's old raw value simply fails the enum init and falls back to
/// Sharp. `crtGeom` joined 2026-08-11, console/arcade only via the same
/// `available(for:)` gating the handheld pair uses in the other
/// direction; despite the name collision, it is a new single-pass
/// curved-screen effect built from scratch, not the multi-pass
/// crt-geom.slang port dropped on 2026-08-07.
enum NativeShader: String, CaseIterable, Identifiable {
    case sharp
    case sabr
    case crtAperture
    case crtEasymode
    case crtMattias
    case crtBeam
    case crtCaligari
    case crtGeom
    case lcd
    case gameBoy

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
        case .crtGeom: return "CRT (curved)"
        case .lcd: return "LCD"
        case .gameBoy: return "Game Boy"
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
        case .crtGeom: return "shader_crt_geom_fragment"
        case .lcd: return "shader_lcd_fragment"
        case .gameBoy: return "shader_gameboy_fragment"
        }
    }

    /// The CRT shaders simulate a television; none of these platforms was
    /// ever displayed on one, they had their own small LCD screens. Found
    /// 2026-08-08 while adding LCD/Game Boy: no reason to keep offering a
    /// look that never applied to this hardware.
    private static let handheldPlatforms: Set<NativePlatform> = [.gb, .gbc, .gba, .gameGear, .ngpc]

    /// The shaders worth offering for a platform. Handhelds swap the five
    /// CRT variants for whichever real-screen shader actually fits: Game
    /// Boy/Color get the dot-matrix look built for their specific screen,
    /// the other three (GBA, Game Gear, NGPC) get the generic LCD grid,
    /// same shader shared across all of them the way Provenance's own
    /// "LCD" filter is generic rather than per-console. The filter cuts
    /// both ways: consoles drop the two handheld screens the same way
    /// handhelds drop the CRTs, since a PS1 game offering a Game Boy
    /// dot-matrix was the same mismatch in the other direction.
    static func available(for platform: NativePlatform) -> [NativeShader] {
        guard handheldPlatforms.contains(platform) else {
            return allCases.filter { $0 != .lcd && $0 != .gameBoy }
        }
        let handheldSpecific: [NativeShader] = (platform == .gb || platform == .gbc) ? [.gameBoy] : [.lcd]
        return [.sharp, .sabr] + handheldSpecific
    }

    private static func key(for platform: NativePlatform) -> String {
        "com.mmagtech.RommApp.nativeShader.\(platform.storageKey)"
    }

    /// Stored per platform, not per core: Genesis Plus GX alone serves
    /// four platforms, and a shader chosen for Genesis silently carrying
    /// into Sega CD/Master System/Game Gear was a real, if harmless until
    /// now, instance of the same core-vs-platform storage bug core
    /// options were redesigned around. Fixed alongside the handheld work
    /// since it needed touching this file anyway. A value from a
    /// shader this platform no longer offers (e.g. a CRT choice under a
    /// now-handheld-filtered platform) falls back to Sharp rather than
    /// being trusted.
    static func current(for platform: NativePlatform) -> NativeShader {
        guard let stored = UserDefaults.standard.string(forKey: key(for: platform)),
              let shader = NativeShader(rawValue: stored),
              available(for: platform).contains(shader)
        else { return .sharp }
        return shader
    }

    static func setCurrent(_ shader: NativeShader, for platform: NativePlatform) {
        UserDefaults.standard.set(shader.rawValue, forKey: key(for: platform))
    }
}
