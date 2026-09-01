//  What GameCube's picture settings are, and where they are kept.
//
//  Machine-wide rather than per game, which is the opposite of the two
//  settings PS2 keeps per title. That is not inconsistency: PS2's
//  aspect and renderer are FACTS ABOUT A GAME (whether it is widescreen,
//  whether it needs the software renderer), so they belong to the title.
//  These are facts about the machine and the display in front of it, and
//  a person who wants 3x internal resolution wants it for everything.
//
//  No shaders, by decision 2026-09-01. Dolphin ships 48 post-processing
//  shaders and they are effects rather than a television: sepia, invert,
//  nightvision, posterize, emboss, FXAA. There is no scanline or CRT
//  shader among them, so offering them would not give GameCube the look
//  Cabinet's handhelds have, it would give it filters. If a real
//  television look is ever wanted here it means a Cabinet post-pass, the
//  same conclusion PS2 reached from the other direction after PCSX2's
//  own scanline shaders turned out to be useless at Retina density.
//
//  Mac only. See CabinetDolphinBridge.h.

import Foundation

enum GCGraphics {
    /// Dolphin's InternalResolution. Source-exact: 0 is
    /// EFB_SCALE_AUTO_INTEGRAL, which matches the window, 1 is the
    /// console's own 640x528, and GFX_MAX_EFB_SCALE is 12.
    ///
    /// Offered up to 4x rather than 12. On a 5K display 4x is already
    /// past the panel, and the numbers above it exist for people
    /// recording video, not playing.
    static let resolutions: [(label: String, value: Int)] = [
        ("Native", 1),
        ("2x", 2),
        ("3x", 3),
        ("4x", 4),
        ("Match window", 0),
    ]

    /// Multisampling, then supersampling. Kept as one row because they
    /// are one choice in practice: Dolphin's own UI presents SSAA as a
    /// checkbox beside the MSAA count, and two rows would invite the
    /// combination nobody wants (SSAA on with MSAA off, which does
    /// nothing).
    static let antialiasing: [(label: String, msaa: UInt32, ssaa: Bool)] = [
        ("Off", 1, false),
        ("2x MSAA", 2, false),
        ("4x MSAA", 4, false),
        ("8x MSAA", 8, false),
        ("4x SSAA", 4, true),
    ]

    /// AnisotropicFilteringMode, source-exact from VideoConfig.h:
    /// Default is -1, then Force1x through Force16x are 0 to 4.
    static let anisotropy: [(label: String, value: Int)] = [
        ("Default", -1),
        ("2x", 1),
        ("4x", 2),
        ("8x", 3),
        ("16x", 4),
    ]

    private static let resolutionKey = "gc-internal-resolution"
    private static let antialiasingKey = "gc-antialiasing"
    private static let anisotropyKey = "gc-anisotropy"

    /// Indexes into the tables above rather than raw values, so a row
    /// that is removed later cannot leave a setting pointing at a number
    /// nothing offers. Defaults are the first entry of each.
    static var resolutionIndex: Int {
        get { clamp(UserDefaults.standard.integer(forKey: resolutionKey), resolutions.count) }
        set { UserDefaults.standard.set(newValue, forKey: resolutionKey) }
    }

    static var antialiasingIndex: Int {
        get { clamp(UserDefaults.standard.integer(forKey: antialiasingKey), antialiasing.count) }
        set { UserDefaults.standard.set(newValue, forKey: antialiasingKey) }
    }

    static var anisotropyIndex: Int {
        get { clamp(UserDefaults.standard.integer(forKey: anisotropyKey), anisotropy.count) }
        set { UserDefaults.standard.set(newValue, forKey: anisotropyKey) }
    }

    private static func clamp(_ value: Int, _ count: Int) -> Int {
        value >= 0 && value < count ? value : 0
    }

    /// Pushes all three at once, which is how Dolphin wants them: its
    /// video backend re-reads its whole config in one step, so three
    /// separate calls would mean three of those.
    ///
    /// Safe before a game starts, in which case these are simply the
    /// settings it boots with.
    static func apply() {
        let aa = antialiasing[antialiasingIndex]
        var graphics = CabinetDolphinGraphics(
            internal_resolution: Int32(resolutions[resolutionIndex].value),
            msaa: aa.msaa,
            ssaa: aa.ssaa,
            anisotropy: Int32(anisotropy[anisotropyIndex].value)
        )
        CabinetDolphinSetGraphics(&graphics)
    }
}
