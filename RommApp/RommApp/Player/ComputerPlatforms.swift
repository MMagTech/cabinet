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
