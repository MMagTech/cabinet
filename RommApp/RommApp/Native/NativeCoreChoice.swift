import Foundation

/// Which native core runs a game, on the platforms where more than one
/// can: today that is arcade alone, FinalBurn Neo or MAME 2003-Plus.
///
/// Deliberately shaped like the webview's `LaunchChoices`: a choice made
/// for this exact game wins, then the platform habit, then the platform
/// default. One deliberate divergence from the webview's order: no board
/// hint in the resolution itself. The webview consults `CoreHints` before
/// the platform habit because its default arcade core genuinely cannot
/// start most modern sets; here the default is FBNeo, the proven
/// incumbent every existing arcade game already runs on, and silently
/// rerouting a working game to a newer core would be a behavior change
/// nobody asked for. Hints drive the "Recommended" caption in the picker
/// instead, so the person is told, not overridden.
enum NativeCoreChoice {
    private static func romKey(_ romId: Int) -> String { "native.core.rom.\(romId)" }
    private static func platformKey(_ platform: NativePlatform) -> String {
        "native.core.nativePlatform.\(platform)"
    }

    /// The core a launch should use. For single-core platforms this is
    /// the platform's core, always, no defaults read: those platforms
    /// must stay byte-identical to the app before this existed.
    static func resolved(for rom: Rom, platform: NativePlatform) -> NativeCore {
        let cores = platform.cores
        guard cores.count > 1 else { return platform.core }
        if let stored = UserDefaults.standard.string(forKey: romKey(rom.id)),
           let core = cores.first(where: { $0.storageKey == stored }) {
            return core
        }
        if let stored = UserDefaults.standard.string(forKey: platformKey(platform)),
           let core = cores.first(where: { $0.storageKey == stored }) {
            return core
        }
        return platform.core
    }

    /// Remembered the way the webview remembers: for this game, and as
    /// the platform's new habit. Nil clears the per-game choice.
    static func remember(_ core: NativeCore?, rom: Rom, platform: NativePlatform) {
        guard platform.cores.count > 1 else { return }
        let defaults = UserDefaults.standard
        if let core {
            defaults.set(core.storageKey, forKey: romKey(rom.id))
            defaults.set(core.storageKey, forKey: platformKey(platform))
        } else {
            defaults.removeObject(forKey: romKey(rom.id))
        }
    }

    /// True when the board data says this specific game needs `core`
    /// rather than merely running on it. Drives the picker's caption.
    static func isRecommended(_ core: NativeCore, rom: Rom, platform: NativePlatform) -> Bool {
        let available = platform.cores.compactMap(\.hintSlug)
        guard available.count > 1, let slug = core.hintSlug else { return false }
        return CoreHints.core(forShortname: rom.fsNameNoExt, available: available) == slug
    }
}
