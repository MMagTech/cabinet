import Foundation

/// What the launch screen decided, and how that reaches RomM.
///
/// RomM's player page reads its configuration from localStorage on load, with
/// keys scoped by game id or platform slug. Writing those before the page
/// initialises is the entire handoff: no clicking its buttons, no reaching
/// into its Vue components, no parsing its DOM.
///
/// The failure mode is deliberately gentle. If a future RomM renames a key,
/// the write lands somewhere unread, its page uses its own defaults, and the
/// person sees the configuration screen they saw before this existed. That is
/// why the injected script verifies the values took before skipping that
/// screen: a wrong core is worse than an extra tap.
struct LaunchChoices {
    let core: String?
    let firmwareId: Int?
    let saveId: Int?
    let stateId: Int?
    /// When true, the native screen stands aside entirely and RomM's own page
    /// is shown as it always was. The escape hatch, in Settings.
    let useRommScreen: Bool

    static let none = LaunchChoices(
        core: nil, firmwareId: nil, saveId: nil, stateId: nil, useRommScreen: true
    )

    /// The core to start on: what was used last, otherwise one that stands a
    /// chance of running the game.
    ///
    /// Never simply the first in the list. RomM lists mame2003 first for
    /// arcade, an emulator frozen at MAME 0.78 in 2003 that cannot start most
    /// of a modern collection, so defaulting to it meant confidently
    /// launching the one core this screen itself warns about.
    static func defaultCore(rom: Rom, from available: [String]) -> String? {
        // A choice made for this exact game always wins: it is the most
        // specific thing anyone has said about it.
        if let remembered = UserDefaults.standard.string(forKey: "romm.core.rom.\(rom.id)"),
           available.contains(remembered) { return remembered }

        // Then what the board needs, which outranks the platform habit.
        // Remembering "fbneo" from last night's Neo Geo game must not drag
        // a CPS2 game onto a core that cannot keep it alive, and arcade is
        // one platform covering boards with nothing in common.
        if rom.isArcade,
           let hinted = CoreHints.core(forShortname: rom.fsNameNoExt, available: available) {
            return hinted
        }

        if let remembered = UserDefaults.standard.string(forKey: "romm.core.platform.\(rom.platformSlug)"),
           available.contains(remembered) { return remembered }

        // FinalBurn Neo covers Neo Geo, CPS and most arcade boards, and is
        // why hand picking it fixed every arcade game tonight.
        if available.contains("fbneo") { return "fbneo" }
        return available.first { CoreCatalog.note($0) == nil } ?? available.first
    }

    /// True when this core is the one the game's board wants, so the
    /// launch screen can say why it was chosen.
    static func isRecommended(core: String?, rom: Rom, available: [String]) -> Bool {
        guard rom.isArcade, let core else { return false }
        return CoreHints.core(forShortname: rom.fsNameNoExt, available: available) == core
    }

    static func remember(core: String?, for rom: Rom) {
        guard let core else { return }
        UserDefaults.standard.set(core, forKey: "romm.core.rom.\(rom.id)")
        UserDefaults.standard.set(core, forKey: "romm.core.platform.\(rom.platformSlug)")
    }

    /// JavaScript that seeds RomM's storage, confirms it took, and reports
    /// back so native code knows whether skipping its screen is safe.
    func injection(for rom: Rom) -> String {
        guard !useRommScreen else { return "" }

        func entry(_ key: String, _ value: String?) -> String {
            guard let value else { return "" }
            return "put(\(jsString(key)), \(jsString(value)));\n"
        }

        var writes = ""
        writes += entry("player:\(rom.id):core", core)
        writes += entry("player:\(rom.platformSlug):core", core)
        writes += entry("player:\(rom.platformSlug):bios_id", firmwareId.map(String.init))
        writes += entry("player:\(rom.platformSlug):save_id", saveId.map(String.init))
        writes += entry("player:\(rom.platformSlug):state_id", stateId.map(String.init))

        // Clearing matters as much as writing: a save left selected from a
        // previous session would silently resume a game someone chose to
        // start fresh.
        var clears = ""
        if saveId == nil { clears += "drop(\(jsString("player:\(rom.platformSlug):save_id")));\n" }
        if stateId == nil { clears += "drop(\(jsString("player:\(rom.platformSlug):state_id")));\n" }
        // A BIOS left over from a previous game on the same platform would
        // otherwise be applied to one that must not have it.
        if firmwareId == nil { clears += "drop(\(jsString("player:\(rom.platformSlug):bios_id")));\n" }

        return """
        (function () {
          var ok = true;
          function put(k, v) {
            try { localStorage.setItem(k, v); if (localStorage.getItem(k) !== v) ok = false; }
            catch (e) { ok = false; }
          }
          function drop(k) { try { localStorage.removeItem(k); } catch (e) {} }
        \(writes)\(clears)
          window.__rommLaunchSeeded = ok;
        })();
        """
    }

    private func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }
}
