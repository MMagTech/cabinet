import Foundation

/// The natively compiled cores this app ships, one case per core. Kept
/// apart from the webview player's core catalogue on purpose: that list
/// is RomM's, this one is ours.
enum NativeCore {
    case fbneo

    /// The frontend's identifier for the statically linked core.
    var coreID: LibretroCoreID {
        switch self {
        case .fbneo: return .fbneo
        }
    }

    /// The emulator tag uploaded states carry. Tested 2026-08-06 and the
    /// answer is no: the webview's WASM FBNeo (the build frozen inside
    /// EmulatorJS 4.2.3) cannot restore states written by the native
    /// FBNeo build, it fails silently and boots fresh. libretro state
    /// formats are core-build-specific, so each player's states are
    /// tagged distinctly on purpose: a separate tag keeps each player's
    /// launch UI from offering states it cannot actually restore.
    var emulatorTag: String {
        switch self {
        case .fbneo: return "fbneo-native"
        }
    }

    /// The native core that can run this rom, if any. Arcade means FBNeo;
    /// everything else stays on the webview until a core for it exists.
    static func core(for rom: Rom) -> NativeCore? {
        rom.isArcade ? .fbneo : nil
    }
}
