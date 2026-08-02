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

    /// The core someone last used for this game, then for this platform,
    /// reading the same keys RomM writes so the two stay in agreement.
    static func storedCore(rom: Rom) -> String? {
        UserDefaults.standard.string(forKey: "romm.core.rom.\(rom.id)")
            ?? UserDefaults.standard.string(forKey: "romm.core.platform.\(rom.platformSlug)")
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
