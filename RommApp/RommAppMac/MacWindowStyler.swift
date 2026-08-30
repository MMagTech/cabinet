#if targetEnvironment(macCatalyst)
import UIKit
import os

/// The window-chrome half of making Cabinet read as a Mac app: iOS
/// hands Catalyst a window whose titlebar shows the app name over the
/// content, which is exactly the stretched-iPad look. Media apps on the
/// Mac, Music and TV being the models, hide the title text and let the
/// sidebar plus content own the window.
///
/// Compiled only into the Mac target; iOS and tvOS never see this file.
enum MacWindow {
    /// Idempotent, safe to call from any view's `onAppear`, which is the
    /// simplest moment guaranteed to be after the scene exists under the
    /// SwiftUI lifecycle.
    static func styleAll() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
            }
            // Below this the shelves and the launch screen start
            // crushing into their compact variants, which is the
            // stretched-phone look this whole file exists to avoid.
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 980, height: 640)
        }
        // The tab container mounts a beat after the scene reports in,
        // and its planes come back after backgrounding, so clear on a
        // short delay rather than once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { clearDefaultPlanes() }
    }

    /// UIKit gives the tab container an opaque `systemBackground` plane,
    /// which in the Mac shell sits exactly between the ambient backdrop
    /// and the content, erasing the backdrop. Clearing every view whose
    /// color IS that default, and only those, keeps materials, cards and
    /// covers untouched: they all set their own colors.
    private static func clearDefaultPlanes() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                clearDefaultPlanes(in: window.rootViewController?.view, traits: window.traitCollection)
            }
        }
    }

    private static func clearDefaultPlanes(in view: UIView?, traits: UITraitCollection) {
        guard let view else { return }
        let plane = UIColor.systemBackground.resolvedColor(with: traits)
        if let bg = view.backgroundColor, bg.resolvedColor(with: traits) == plane {
            view.backgroundColor = .clear
        }
        for sub in view.subviews {
            clearDefaultPlanes(in: sub, traits: traits)
        }
    }
}
#endif
