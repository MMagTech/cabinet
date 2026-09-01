import Foundation

/// Platforms whose native input is a keyboard, not a gamepad.
///
/// A C64, Amiga or DOS machine is not a shape a touch overlay can honestly
/// take: a handful of face buttons cannot stand in for a keyboard's worth of
/// commands and shortcuts, and pretending otherwise produces a control
/// scheme that looks like it works and does not. Every other platform this
/// app knows about, console, handheld or arcade, has a real fixed pad this
/// app can draw. These do not, so this app does not try to play them yet.
///
/// This is a settled decision, not a gap waiting to be filled: an on screen
/// keyboard is a real feature with its own design, and building a bad one
/// tonight would be worse than building none. See the scope doc's Next
/// section. A physical Bluetooth keyboard should already work regardless of
/// this list, since nothing in this app intercepts hardware keyboard events
/// before they reach the webview, though that has not been confirmed on a
/// real keyboard yet.
///
/// Keyed by the same canonical slug everything else in the player resolves
/// through, `Rom.canonicalPlatformSlug`, never the raw IGDB slug: the whole
/// reason that resolution exists is that a rom's own platform_slug cannot be
/// trusted to already be this value.
enum ComputerPlatforms {
    private static let slugs: Set<String> = [
        "acpc", "c-plus-4", "c128", "c64", "commmodore-128",
        "commodore-64c", "cpet", "dos", "vic-20", "zxs",
    ]

    static func contains(_ canonicalSlug: String) -> Bool {
        slugs.contains(canonicalSlug)
    }
}

/// Whether this app can actually put a game on screen: a real gamepad
/// platform with at least one EmulatorJS core or a native core, everything
/// else, keyboard machines and zero-core platforms like Flash, is
/// unsupported and offered a download instead of a dead Play button.
/// Dreamcast used to be the canonical zero-core example here; it stopped
/// being one 2026-08-10 once a native core existed for it with no webview
/// core to match, which this check didn't originally account for.
///
/// The single source of truth for that split, shared by the library's
/// Supported/Unsupported sections and the launch screen's own Play guard,
/// so the two can never disagree about which games this covers.
enum PlatformSupport {
    /// RomM's ARCADE_SYSTEMS, the metadata slugs whose games run on the
    /// arcade cores. One copy, shared with `Rom.isArcade`, so the library
    /// sections and the rom-level checks cannot drift apart.
    static let arcadeSlugs: Set<String> = ["arcade", "neogeoaes", "neogeomvs", "neo-geo-cd"]

    static func isSupported(canonicalSlug: String, isArcade: Bool = false) -> Bool {
        // Arcade is supported by its native cores no matter what the
        // folder is called. The check below used to assume every arcade
        // folder resolves through PLATFORMS_VERSIONS to a cores.json key,
        // which is only true for folders someone has mapped in RomM's
        // config.yml: a fresh "MAME2003" folder resolved to a slug
        // nothing knew and a fully playable platform read as Unsupported.
        // RomM's own metadata slug already says it is arcade; believe it.
        if isArcade { return true }
        guard !ComputerPlatforms.contains(canonicalSlug) else { return false }
        #if targetEnvironment(macCatalyst)
        // The Mac plays native cores only, the same shape as the TV
        // app: the webview player is dropped from this target for now
        // (Marcus's call, 2026-08-30, revisitable), so a platform whose
        // only cores are EmulatorJS's is not playable here and belongs
        // in Unsupported rather than behind a broken Play button.
        // PS2 before the NativePlatform lookup, because it has no case
        // there and never will: PCSX2 is not a libretro core. It is
        // still playable on this target, so the lookup failing must not
        // be read as unsupported.
        if PS2Launcher.isPS2(canonicalSlug: canonicalSlug) { return true }
        // GameCube for the same reason, and it is this one source both
        // the library section and the Play button read: patching only
        // GameLaunchView's local copy leaves the game filed under
        // Unsupported with a working Play path nobody can reach. That
        // exact mistake cost a session on PS2.
        if GCLauncher.isGameCube(canonicalSlug: canonicalSlug) { return true }
        guard let platform = NativePlatform.platform(bySlug: canonicalSlug, isArcade: false) else {
            return false
        }
        return !macPendingPlatforms.contains(platform)
        #else
        // Dreamcast is Mac only, and this is the same rule PS2 and
        // GameCube were held to from the start rather than a new one.
        //
        // Flycast needs a recompiler. iOS and tvOS cannot have one, so
        // the version that shipped here ran at half the SH4's clock with
        // an audio governor built to hold it together. That was an
        // exception to the JIT boundary, made before there was a
        // platform that could run the system properly, and the Mac
        // removes the reason for it. A system that is only playable in a
        // compromised form does not belong on a platform; PS2 and
        // GameCube were never offered here for exactly that reason.
        //
        // THE CORE IS STILL COMPILED IN, deliberately. This is a gate,
        // not a removal, because the thing that would bring Dreamcast
        // back is upstream work rather than ours: iFly's interpreter is
        // license-clean and is the candidate that could reach full speed
        // without a recompiler. If that lands, this guard comes out and
        // nothing else has to be rebuilt.
        if canonicalSlug == "dc" { return false }
        if !CoreCatalog.cores(for: canonicalSlug).isEmpty { return true }
        return NativeCore.core(bySlug: canonicalSlug, isArcade: false) != nil
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Platforms whose Mac core is still a link placeholder
    /// (tools/build-mac-core-stub.sh). Listing one here keeps the
    /// library honest, filing it under Unsupported rather than offering
    /// a Play button that fails at load.
    ///
    /// Empty since 2026-08-30: Dreamcast and N64 left the day
    /// ANGLE-for-Mac landed, and PSP left once its ffmpeg was built for
    /// the Catalyst target (tools/build-ppsspp-ffmpeg-mac.sh), which was
    /// the whole of what kept it a stub.
    static let macPendingPlatforms: Set<NativePlatform> = []
    #endif
}
