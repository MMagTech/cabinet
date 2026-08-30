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

    /// Seeds nothing, for a player opened without a launch screen in front
    /// of it. RomM's page then applies its own defaults, exactly as it did
    /// before any of this existed.
    static let none = LaunchChoices(core: nil, firmwareId: nil, saveId: nil)

    /// The core to start on: what was used last, otherwise one that stands a
    /// chance of running the game.
    ///
    /// Never simply the first in the list. RomM lists mame2003 first for
    /// arcade, an emulator frozen at MAME 0.78 in 2003 that cannot start most
    /// of a modern collection, so defaulting to it meant confidently
    /// launching the one core this screen itself warns about.
    static func defaultCore(rom: Rom, canonicalSlug: String, from available: [String]) -> String? {
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

        // Remembered per canonical platform, not per folder name, so two
        // servers that named the same platform differently do not each
        // start from a blank slate, and so this cannot collide with the
        // stale "romm.core.platform.tg16" style keys a build before the
        // slug fix could have written.
        if let remembered = UserDefaults.standard.string(forKey: "romm.core.canonicalPlatform.\(canonicalSlug)"),
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

    static func remember(core: String?, canonicalSlug: String, for rom: Rom) {
        guard let core else { return }
        UserDefaults.standard.set(core, forKey: "romm.core.rom.\(rom.id)")
        UserDefaults.standard.set(core, forKey: "romm.core.canonicalPlatform.\(canonicalSlug)")
    }

    /// Which player runs the game: the webview (RomM's EmulatorJS page,
    /// the default and the only choice for anything that needs a JIT) or
    /// the natively compiled core. Any platform with a native core offers
    /// a real picker, because its webview core is RomM's ordinary,
    /// working EmulatorJS core and native is an upgrade on top of
    /// something already fine, the same reasoning that always applied to
    /// Arcade, now applied everywhere it holds. Saturn is the one
    /// exception: its webview core (confirmed firsthand, not assumed)
    /// runs slowed down and crashes, so there is no working alternative
    /// worth offering a choice between, and no picker shows for it. See
    /// `defaultBackend`.
    enum PlayerBackend: String {
        case webview
        case native
    }

    /// Per game, not per platform: "arcade" is one platform covering
    /// boards with nothing in common, and one board leaking in the
    /// webview says nothing about another. A stored choice always wins;
    /// with none, a game the webview has repeatedly crashed on defaults
    /// native, since three dead sessions are a stronger signal than any
    /// general preference for the familiar player.
    @MainActor
    static func defaultBackend(rom: Rom, canonicalSlug: String) -> PlayerBackend {
        #if targetEnvironment(macCatalyst)
        // The Mac has one player: native cores. The webview backend is
        // dropped from this target (2026-08-30, revisitable), so no
        // stored choice, crash count or webview-core mapping can route
        // a Mac launch there. This also hides the launch screen's
        // Web/Native picker, whose visibility asks whether this
        // function already answers .native.
        return .native
        #else
        // Static, not evidence based, unlike everything below: there is
        // no picker for Saturn to record a stored choice or a crash
        // count against, since GameLaunchView never shows one. This is
        // the one line to remove if RomM's own Saturn core is ever
        // fixed and a real choice becomes worth offering again.
        //
        // Two kinds of native-only, and only one of them needs naming
        // here.
        //
        // The first is DERIVED, and covers Dreamcast, Vectrex and Game &
        // Watch: RomM's core map has no entry for the platform at all, so
        // no webview player exists to pick. That used to be a list of
        // slugs, which meant every future platform in this shape arrived
        // defaulting to a webview that cannot run it. Game & Watch did
        // exactly that on the day it shipped. Asking the core map is the
        // same question with an answer that maintains itself.
        //
        // The second is JUDGEMENT, and has to stay a list: Saturn and PSP
        // both HAVE a mapped core that does not work, confirmed on real
        // hardware. Remove a slug here if its core is ever fixed and
        // worth offering.
        let brokenWebviewCore: Set<String> = ["saturn", "psp"]
        if brokenWebviewCore.contains(canonicalSlug) { return .native }
        if CoreCatalog.cores(for: canonicalSlug).isEmpty,
           NativeCore.core(for: rom, canonicalSlug: canonicalSlug) != nil { return .native }
        guard NativeCore.core(for: rom, canonicalSlug: canonicalSlug) != nil else { return .webview }
        if let stored = UserDefaults.standard.string(forKey: "romm.backend.rom.\(rom.id)"),
           let backend = PlayerBackend(rawValue: stored) {
            return backend
        }
        // Webview deaths argue for native, but only while native itself
        // holds up: a game that kills both players defaults back to the
        // webview, whose crash costs one process instead of the whole app.
        if Compatibility.shared.crashes(romId: rom.id) >= 3,
           Compatibility.shared.nativeCrashes(romId: rom.id) < 2 {
            return .native
        }
        return .webview
        #endif
    }

    static func remember(backend: PlayerBackend, for rom: Rom) {
        UserDefaults.standard.set(backend.rawValue, forKey: "romm.backend.rom.\(rom.id)")
    }

    /// The BIOS to preselect: whatever was picked last on this platform, if
    /// the server still has it. A platform, not a per-game choice, unlike
    /// core: a machine either needs its BIOS or it does not, and every game
    /// on it needs the same file, so there is no equivalent of a CPS2 board
    /// wanting a different answer than the platform habit.
    static func defaultFirmware(platformId: Int, from available: [Firmware]) -> Firmware? {
        guard let remembered = UserDefaults.standard.object(forKey: "romm.firmware.platform.\(platformId)") as? Int
        else { return nil }
        return available.first { $0.id == remembered }
    }

    static func remember(firmwareId: Int?, platformId: Int) {
        let key = "romm.firmware.platform.\(platformId)"
        guard let firmwareId else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(firmwareId, forKey: key)
    }

    /// JavaScript that seeds RomM's storage, confirms it took, and reports
    /// back so native code knows whether skipping its screen is safe.
    ///
    /// Storage keys stay namespaced by `rom.platformSlug`, the IGDB slug:
    /// that is the exact value RomM's own page uses to build these same
    /// keys (`createPlayerStorage(rom.id, rom.platform_slug)` in its Play
    /// view), so writing anywhere else would seed a key its page never
    /// reads. `canonicalSlug` is not RomM's key; it exists only so this
    /// app can resolve a valid core in the first place.
    func injection(for rom: Rom) -> String {
        func entry(_ key: String, _ value: String?) -> String {
            guard let value else { return "" }
            return "put(\(jsString(key)), \(jsString(value)));\n"
        }

        var writes = ""
        writes += entry("player:\(rom.id):core", core)
        writes += entry("player:\(rom.platformSlug):core", core)
        writes += entry("player:\(rom.platformSlug):bios_id", firmwareId.map(String.init))
        writes += entry("player:\(rom.platformSlug):save_id", saveId.map(String.init))
        // Deliberately no `state_id` seed. That was tried here first: write
        // the id, trust RomM's own page to notice it at boot and load the
        // state itself. Confirmed on device that nothing does; the value
        // lands in storage and nothing ever reads it back. A state now
        // loads through `PlayerView.stateToLoad`, called directly against
        // the emulator's own JavaScript API once the game has booted,
        // rather than hoped for from outside it.

        // Clearing matters as much as writing: a save left selected from a
        // previous session would silently resume a game someone chose to
        // start fresh.
        var clears = ""
        if saveId == nil { clears += "drop(\(jsString("player:\(rom.platformSlug):save_id")));\n" }
        // A BIOS left over from a previous game on the same platform would
        // otherwise be applied to one that must not have it.
        if firmwareId == nil { clears += "drop(\(jsString("player:\(rom.platformSlug):bios_id")));\n" }

        // The rescue. RomM's own boot() picks a core by looking up
        // `rom.platform_slug` directly in its bundled core catalogue, with
        // no folder name normalisation at that call site, unlike the check
        // that decides whether to show a Play button at all. Any platform
        // whose IGDB slug is not itself a catalogue key, TurboGrafx-16's
        // "turbografx16--1" among them, gets an empty supported list from
        // that lookup, and window.EJS_core is left undefined no matter what
        // this app seeds into localStorage: RomM validates a stored core
        // against that same empty list before trusting it. Seeding cannot
        // reach this.
        //
        // A polling patch tried here first and did not hold: EmulatorJS
        // reads EJS_core and starts fetching the core file within a few
        // milliseconds of boot() running, faster than a setInterval's first
        // tick ever arrives, so the correction landed after the damage was
        // already done. An accessor closes that race instead of racing it.
        // This script runs at document start, before any of RomM's own
        // code, so it is guaranteed to define the property first: RomM's
        // later `window.EJS_core = core` becomes a call to this setter, and
        // every read after it, EmulatorJS's own included, is a call to this
        // getter, synchronously, with no window in between where the wrong
        // value could be observed. Whatever RomM did manage to resolve on
        // its own is never touched.
        let rescue = core.map { value in
            """
            (function () {
              var rescueValue = \(jsString(value));
              var actual;
              try {
                Object.defineProperty(window, "EJS_core", {
                  configurable: true,
                  enumerable: true,
                  get: function () {
                    return (actual === undefined || actual === null) ? rescueValue : actual;
                  },
                  set: function (v) { actual = v; }
                });
              } catch (e) {}
            })();
            """
        } ?? ""

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
        \(rescue)
        """
    }

    private func jsString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return literal
    }
}
