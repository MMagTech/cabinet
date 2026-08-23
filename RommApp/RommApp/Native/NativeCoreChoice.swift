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

    /// The habit key, scoped to the rom's own folder on the server rather
    /// than to the platform.
    ///
    /// Arcade is why. It is one `NativePlatform` covering boards that have
    /// nothing in common, so a habit spanning all of it is actively
    /// harmful: picking MAME 2003-Plus for one game made it the default
    /// for every arcade game with no choice of its own, including the
    /// FinalBurn Neo ones that MAME 0.78 cannot run. One deliberate pick
    /// silently rerouted a whole library onto a core that would refuse it.
    ///
    /// A folder is a much better unit, because it is how people actually
    /// separate romsets: an "FBNEO" folder and a "MAME2003" folder each
    /// keep their own habit and cannot contaminate each other. Someone who
    /// keeps everything in one folder gets exactly the previous behaviour,
    /// no worse, just no better.
    ///
    /// Falls back to the platform when a rom carries no folder, so this
    /// can never produce a key that collides across platforms.
    private static func habitKey(_ rom: Rom, _ platform: NativePlatform) -> String {
        let folder = rom.platformFsSlug.isEmpty ? "\(platform)" : rom.platformFsSlug
        return "native.core.folder.\(folder)"
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
        if let stored = UserDefaults.standard.string(forKey: habitKey(rom, platform)),
           let core = cores.first(where: { $0.storageKey == stored }) {
            return core
        }
        return platform.core
    }

    /// Remembered for this game, and as the habit for the folder it came
    /// from. Nil clears the per-game choice. See `habitKey` for why the
    /// habit is folder-scoped rather than platform-scoped.
    static func remember(_ core: NativeCore?, rom: Rom, platform: NativePlatform) {
        guard platform.cores.count > 1 else { return }
        let defaults = UserDefaults.standard
        if let core {
            defaults.set(core.storageKey, forKey: romKey(rom.id))
            defaults.set(core.storageKey, forKey: habitKey(rom, platform))
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
