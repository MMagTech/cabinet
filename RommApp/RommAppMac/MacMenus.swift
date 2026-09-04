#if targetEnvironment(macCatalyst)
import UIKit

extension Notification.Name {
    /// Posted by the app menu's Settings item; the shell (MainTabView's
    /// Mac branch) listens and presents SettingsView as a sheet.
    static let cabinetShowSettings = Notification.Name("cabinetShowSettings")
    /// The app menu's About item. Credits and licenses live behind it,
    /// as they do in every Mac app, rather than as Settings rows.
    static let cabinetShowAbout = Notification.Name("cabinetShowAbout")
    /// Help's Diagnostics item, the same DebugView the phone reaches
    /// through Settings.
    static let cabinetShowDiagnostics = Notification.Name("cabinetShowDiagnostics")
    /// File's Download All… item, for the platform the sidebar shows.
    static let cabinetDownloadAllSelected = Notification.Name("cabinetDownloadAllSelected")
}

/// The Mac menu bar's Cabinet-specific entries, placed where a Mac hand
/// expects them: Settings under the app menu at Cmd+comma, About with
/// the credits and licenses behind it, display choices under View as
/// checkmarked submenus, diagnostics under Help. Audited 2026-09-02
/// against the macOS menu bar conventions; five Settings rows moved out
/// here, and the phone's Settings keeps them. The Format menu is
/// removed: nothing here edits styled text. Called from
/// AppDelegate.buildMenu, which has to live in the class itself, Swift
/// does not allow overriding an inherited method from an extension.
enum MacMenus {
    static func apply(_ builder: UIMenuBuilder) {
        guard builder.system == .main else { return }
        builder.remove(menu: .format)

        // About, ours: the system panel cannot carry the licenses. Once
        // replaced, the system's .about identifier is gone, so Settings
        // below anchors to this one; anchoring to .about inserted
        // nothing, silently, and the app menu lost Settings for an hour.
        let about = UIMenu.Identifier("com.mmagtech.cabinet.about")
        builder.replace(menu: .about, with: UIMenu(
            identifier: about,
            options: .displayInline,
            children: [UICommand(title: "About Cabinet", action: #selector(AppDelegate.cabinetOpenAbout))]))

        let settings = UIKeyCommand(
            title: "Settings…",
            action: #selector(AppDelegate.cabinetOpenSettings),
            input: ",",
            modifierFlags: .command
        )
        builder.insertSibling(
            UIMenu(identifier: UIMenu.Identifier("com.mmagtech.cabinet.settings"),
                   options: .displayInline,
                   children: [settings]),
            afterMenu: about
        )

        // View: how the picture and the library are shown. Checkmarks
        // read the stored value at build time; the actions store and
        // ask for a rebuild, so the mark follows the choice.
        let glow = UserDefaults.standard.string(forKey: BiasGlowLevel.storageKey) ?? BiasGlowLevel.subtle.rawValue
        let glowMenu = UIMenu(title: "Letterbox Glow", children: BiasGlowLevel.allCases.map { level in
            UICommand(title: level.label, action: #selector(AppDelegate.cabinetSetGlow(_:)),
                      propertyList: level.rawValue, state: level.rawValue == glow ? .on : .off)
        })
        let labels = UserDefaults.standard.string(forKey: PlatformLabelSource.key) ?? PlatformLabelSource.platformName.rawValue
        let labelMenu = UIMenu(title: "Show Platforms By", children: PlatformLabelSource.allCases.map { source in
            UICommand(title: source.label, action: #selector(AppDelegate.cabinetSetPlatformLabels(_:)),
                      propertyList: source.rawValue, state: source.rawValue == labels ? .on : .off)
        })
        builder.insertChild(
            UIMenu(identifier: UIMenu.Identifier("com.mmagtech.cabinet.view"),
                   options: .displayInline, children: [glowMenu, labelMenu]),
            atEndOfMenu: .view)

        // File: Download All… for the platform the sidebar shows. A
        // whole-collection download in Apple's apps is a command on
        // the collection's own page and in the menu bar, not a
        // right-click; the context menu this began as drew itself in a
        // glass panel inside the tile on Catalyst and was dropped.
        builder.insertChild(
            UIMenu(identifier: UIMenu.Identifier("com.mmagtech.cabinet.file"),
                   options: .displayInline,
                   children: [UICommand(title: "Download All…", action: #selector(AppDelegate.cabinetDownloadAllSelected))]),
            atStartOfMenu: .file)

        // Help: the material for reporting a problem.
        builder.insertChild(
            UIMenu(identifier: UIMenu.Identifier("com.mmagtech.cabinet.help"),
                   options: .displayInline,
                   children: [UICommand(title: "Diagnostics", action: #selector(AppDelegate.cabinetOpenDiagnostics))]),
            atEndOfMenu: .help)
    }
}

extension AppDelegate {
    @objc func cabinetOpenSettings() {
        NotificationCenter.default.post(name: .cabinetShowSettings, object: nil)
    }

    @objc func cabinetDownloadAllSelected() {
        NotificationCenter.default.post(name: .cabinetDownloadAllSelected, object: nil)
    }

    @objc func cabinetOpenAbout() {
        NotificationCenter.default.post(name: .cabinetShowAbout, object: nil)
    }

    @objc func cabinetOpenDiagnostics() {
        NotificationCenter.default.post(name: .cabinetShowDiagnostics, object: nil)
    }

    @objc func cabinetSetGlow(_ sender: UICommand) {
        guard let raw = sender.propertyList as? String else { return }
        UserDefaults.standard.set(raw, forKey: BiasGlowLevel.storageKey)
        UIMenuSystem.main.setNeedsRebuild()
    }

    @objc func cabinetSetPlatformLabels(_ sender: UICommand) {
        guard let raw = sender.propertyList as? String else { return }
        UserDefaults.standard.set(raw, forKey: PlatformLabelSource.key)
        UIMenuSystem.main.setNeedsRebuild()
    }
}
#endif
