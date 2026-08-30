#if targetEnvironment(macCatalyst)
import UIKit

extension Notification.Name {
    /// Posted by the app menu's Settings item; the shell (MainTabView's
    /// Mac branch) listens and presents the same SettingsView Home's
    /// gear reaches.
    static let cabinetShowSettings = Notification.Name("cabinetShowSettings")
}

/// The Mac menu bar's Cabinet-specific entries. A Mac hand reaches for
/// Cmd+comma before it goes looking for a gear in the content, so
/// Settings lives in the app menu the way every Mac app's does. The
/// Format menu is removed: nothing here edits styled text. Called from
/// AppDelegate.buildMenu, which has to live in the class itself, Swift
/// does not allow overriding an inherited method from an extension.
enum MacMenus {
    static func apply(_ builder: UIMenuBuilder) {
        guard builder.system == .main else { return }

        builder.remove(menu: .format)

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
            afterMenu: .about
        )
    }
}

extension AppDelegate {
    @objc func cabinetOpenSettings() {
        NotificationCenter.default.post(name: .cabinetShowSettings, object: nil)
    }
}
#endif
