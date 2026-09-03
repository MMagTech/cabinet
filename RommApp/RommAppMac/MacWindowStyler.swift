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
    /// The Settings window's scene, once it reports in. Everything
    /// below that walks connectedScenes is the SHELL's chrome, hiding
    /// title bars and holding a 980-point minimum, and would strip the
    /// pane toolbar off a Settings window and pin it to the shell's
    /// size. So the shell loops skip it, by session identifier.
    private static var settingsSceneIDs: Set<String> = []

    static func isShell(_ scene: UIWindowScene) -> Bool {
        !settingsSceneIDs.contains(scene.session.persistentIdentifier)
    }

    /// Called by the Settings window's own view as soon as it has a
    /// scene. Fixed to the pane's size, per Apple's guidance, with
    /// minimize and zoom off the window: Cmd+comma brings it back, so
    /// there is nothing to keep in the Dock and nothing to resize.
    static func adoptSettingsScene(_ scene: UIWindowScene, title: String) {
        settingsSceneIDs.insert(scene.session.persistentIdentifier)
        scene.title = title
        scene.titlebar?.titleVisibility = .visible
        scene.sizeRestrictions?.minimumSize = CGSize(width: 640, height: 520)
        scene.sizeRestrictions?.maximumSize = CGSize(width: 640, height: 520)
        scene.sizeRestrictions?.allowsFullScreen = false
        for window in scene.windows { window.overrideUserInterfaceStyle = .unspecified }
        if let appKit = appKitWindow(titled: title) {
            let miniaturizable: UInt = 1 << 2
            let resizable: UInt = 1 << 3
            if let mask = (appKit.value(forKey: "styleMask") as? NSNumber)?.uintValue {
                let wanted = mask & ~miniaturizable & ~resizable
                if wanted != mask { appKit.setValue(NSNumber(value: wanted), forKey: "styleMask") }
            }
        }
    }

    /// Idempotent, safe to call from any view's `onAppear`, which is the
    /// simplest moment guaranteed to be after the scene exists under the
    /// SwiftUI lifecycle.
    static func styleAll() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, isShell(windowScene) else { continue }
            if let titlebar = windowScene.titlebar {
                titlebar.titleVisibility = .hidden
                titlebar.toolbar = nil
            }
            // Pinned on the window itself, not only in SwiftUI's
            // environment. This shell is built on one ambient backdrop,
            // cover art blurred and darkened, and that canvas stays dark
            // whatever the system appearance says, so light chrome over
            // it is unreadable: white buttons on a white bar above a
            // dark window. MainTabView already sets the SwiftUI
            // colorScheme, but Catalyst does not reliably carry the
            // environment into a presentation, which is how a game's
            // launch screen came up light over a dark shell. UIKit
            // hands this down to every presentation in the window, and
            // it is the same trap the Settings sheet hit.
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = .dark
            }
            // Below this the shelves and the launch screen start
            // crushing into their compact variants, which is the
            // stretched-phone look this whole file exists to avoid.
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 980, height: 640)
        }
        // The tab container mounts a beat after the scene reports in,
        // and its planes come back after backgrounding, so clear on a
        // short delay rather than once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            clearDefaultPlanes()
            holdChromeless()
        }
        holdChromeless()
    }

    /// Take the titlebar strip out of the window for good.
    ///
    /// Catalyst gives this window a titlebar because it contains a split
    /// view, and hangs an AppKit `NSToolbar` on it carrying the sidebar
    /// toggle and whatever the current screen publishes. Windowed that
    /// strip pushes the content down and shows as a band across the top;
    /// fullscreen, or with a game up, AppKit draws the same thing over
    /// the picture. It cannot be removed by clearing it, because
    /// Catalyst re-attaches a replacement within half a second.
    ///
    /// So instead of emptying it, this stops it occupying anything:
    ///
    /// - `fullSizeContentView` in the style mask lets the content view
    ///   run the whole height of the window, under the titlebar rather
    ///   than below it, which is what makes the ambient backdrop reach
    ///   the top edge.
    /// - `titlebarAppearsTransparent` stops the titlebar painting its
    ///   own background over that content.
    /// - the toolbar comes off, so there is nothing drawn in the strip.
    ///
    /// The traffic lights stay, floating over the content, which is what
    /// Music and TV do and is why they have no band either.
    ///
    /// Everything goes through the runtime because Catalyst cannot import
    /// AppKit. The style mask and the transparency flag are set with KVC,
    /// which this window subclass does support for those two; the toolbar
    /// is set through `perform`, because KVC on the toolbar-related keys
    /// is what crashed the app when it was tried.
    private static let fullSizeContentViewBit: UInt = 1 << 15

    /// Held, not polled.
    ///
    /// Catalyst rebuilds this window's titlebar whenever the window
    /// changes shape: entering or leaving fullscreen, resizing, and
    /// presenting a game over the shell. Each rebuild restores the
    /// toolbar and can drop the style bits, and the probe measured the
    /// toolbar returning within half a second of the change.
    ///
    /// This used to run on a half-second timer for the life of the app.
    /// It cannot: merely reading the titlebar's properties every tick
    /// disturbed any open context menu, which was re-presented on top
    /// of itself as a second, larger menu (2026-09-02, found frame by
    /// frame after an evening spent blaming the menu; a timer that
    /// fired and did nothing was clean, one that only read was not).
    /// So it listens for the shape changes themselves, AppKit's own
    /// notifications by name since Catalyst cannot import them, and
    /// applies in a short burst after each to catch the re-attach.
    private static var chromeObservers: [NSObjectProtocol] = []
    private static func perform0(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    static func holdChromeless() {
        applyChromelessBurst()
        guard chromeObservers.isEmpty else { return }
        // Shape changes of the SHELL's window only. Not key-window
        // changes: a context menu is a window of its own, it becomes
        // key as it opens, and reacting to that ran the styler while
        // the menu was up, which re-presented it.
        let names = [
            "NSWindowDidResizeNotification",
            "NSWindowDidEnterFullScreenNotification",
            "NSWindowDidExitFullScreenNotification",
            "NSWindowDidChangeScreenNotification",
        ].map { Notification.Name($0) }
        for name in names {
            chromeObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSObject, window === appKitWindow() else { return }
                applyChromelessBurst()
            })
        }
        chromeObservers.append(NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
            applyChromelessBurst()
        })
    }

    /// Now, and again at the intervals the re-attach was measured at.
    private static func applyChromelessBurst() {
        makeChromeless()
        for delay in [0.3, 0.7, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { makeChromeless() }
        }
    }

    static func makeChromeless() {
        guard let window = appKitWindow() else { return }

        if let mask = (window.value(forKey: "styleMask") as? NSNumber)?.uintValue,
           mask & fullSizeContentViewBit == 0 {
            window.setValue(NSNumber(value: mask | fullSizeContentViewBit), forKey: "styleMask")
        }
        // Checked first, like the style mask above it: this ran on the
        // half-second timer as an unconditional write, and every write
        // makes Catalyst rebuild the title bar, which re-presented any
        // open context menu on top of itself.
        if window.responds(to: NSSelectorFromString("setTitlebarAppearsTransparent:")),
           (window.value(forKey: "titlebarAppearsTransparent") as? NSNumber)?.boolValue != true {
            window.setValue(NSNumber(value: true), forKey: "titlebarAppearsTransparent")
        }
        // The window's AppKit toolbar is deliberately left alone. It is
        // what draws the sidebar toggle and the settings button, and
        // UITitlebar.autoHidesToolbarInFullScreen is what takes it out
        // of the way when it would otherwise cover a game.

        // Fullscreen is the case where the titlebar has no business
        // existing: AppKit still paints its background across the top of
        // the content, which is the 33 point band over a running game.
        // Making the titlebar transparent is ignored on Catalyst's
        // window subclass, and the UIKit views underneath are not what
        // draws it, so the view that does is hidden directly.
        //
        // Only while fullscreen. Windowed, this same view carries the
        // traffic lights, and windowed has no band to begin with.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, isShell(windowScene),
                  let titlebar = windowScene.titlebar else { continue }
            // Checked before written, every one of them. This runs on
            // the half-second timer, and an unconditional write here
            // makes Catalyst rebuild the title bar and re-lay out the
            // window each tick, which re-presented any open context
            // menu on top of itself: a second, larger menu settling
            // over the first. Found frame by frame, 2026-09-02, after
            // an evening spent blaming the menu.
            if titlebar.titleVisibility != .hidden { titlebar.titleVisibility = .hidden }
            if titlebar.separatorStyle != .none { titlebar.separatorStyle = .none }
            // Held alongside the rest: Catalyst rebuilds the titlebar on
            // every window shape change, and this is the property that
            // governs fullscreen. Always on, Marcus's call 2026-09-02:
            // in full screen the toolbar, sidebar toggle and back button
            // included, shows when the mouse goes to the top and not
            // otherwise. Keeping it visible in the shell was tried and
            // rejected the same day.
            if !titlebar.autoHidesToolbarInFullScreen { titlebar.autoHidesToolbarInFullScreen = true }
        }
    }

    private static var idleTimer: Timer?
    private static var gameModeActive = false

    /// How long the pointer sits still before it gets out of the way.
    private static let cursorIdleDelay: TimeInterval = 3

    /// What the window does while a game is running: the pointer hides
    /// itself once it stops moving, and comes straight back the moment
    /// it does move, so the pause menu stays usable.
    ///
    /// AppKit's `setHiddenUntilMouseMoves:` is exactly this behaviour
    /// and is reachable from Catalyst only through the runtime, since
    /// AppKit cannot be imported into this target. It unhides on its own
    /// at the next movement, so the only thing to run is the idle clock:
    /// `noteCursorMoved` restarts it, and when it fires the pointer goes
    /// away again.
    ///
    /// Hiding outright was tried first and was wrong: the pointer stayed
    /// gone for the whole session, including over the pause menu, where
    /// it is the only way to press anything without a pad.
    static func setGameMode(_ active: Bool) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, isShell(windowScene) else { continue }
            windowScene.titlebar?.titleVisibility = .hidden
            windowScene.titlebar?.toolbar = nil
            windowScene.titlebar?.separatorStyle = active ? .none : .automatic
        }
        gameModeActive = active
        idleTimer?.invalidate()
        idleTimer = nil
        setFullScreen(active)
        if active {
            noteCursorMoved()
        } else {
            setChromeHidden(false)
            revealCursor()
        }
    }

    private static var enteredFullScreenForGame = false

    /// The window takes itself fullscreen when a game starts, and comes
    /// back out when it ends.
    ///
    /// Fullscreen belongs to AppKit, which Catalyst cannot import, so
    /// the window is reached through the runtime: NSApplication's first
    /// window, its styleMask read by key, and `toggleFullScreen:` sent
    /// only when the state actually needs changing.
    ///
    /// It only undoes what it did. Someone who was already fullscreen
    /// before starting a game stays fullscreen when they quit it, rather
    /// than being dropped into a window they never asked to leave.
    private static func setFullScreen(_ wanted: Bool) {
        guard let window = appKitWindow() else { return }
        let mask = (window.value(forKey: "styleMask") as? NSNumber)?.uintValue ?? 0
        let isFullScreen = (mask & (1 << 14)) != 0
        if wanted {
            guard !isFullScreen else { return }
            window.perform(NSSelectorFromString("toggleFullScreen:"), with: nil)
            enteredFullScreenForGame = true
        } else {
            guard enteredFullScreenForGame, isFullScreen else {
                enteredFullScreenForGame = false
                return
            }
            window.perform(NSSelectorFromString("toggleFullScreen:"), with: nil)
            enteredFullScreenForGame = false
        }
    }

    private static func appKitWindow() -> NSObject? {
        guard let appClass = NSClassFromString("NSApplication") as AnyObject as? NSObjectProtocol else { return nil }
        let sharedSelector = NSSelectorFromString("sharedApplication")
        guard appClass.responds(to: sharedSelector),
              let app = appClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject
        else { return nil }
        guard let windows = app.value(forKey: "windows") as? [NSObject] else { return nil }
        // The game window is the one carrying the shell's scene. The
        // Settings window, when open, is skipped by its title, which
        // adoptSettingsScene keeps on the pane's name.
        let shell = windows.filter { !settingsTitles.contains(($0.value(forKey: "title") as? String) ?? "") }
        return shell.first { ($0.value(forKey: "isVisible") as? NSNumber)?.boolValue == true }
            ?? shell.first
    }

    private static let settingsTitles: Set<String> = ["Controllers", "Library", "Server", "Cores"]

    private static func appKitWindow(titled title: String) -> NSObject? {
        guard let appClass = NSClassFromString("NSApplication") as AnyObject as? NSObjectProtocol else { return nil }
        let sharedSelector = NSSelectorFromString("sharedApplication")
        guard appClass.responds(to: sharedSelector),
              let app = appClass.perform(sharedSelector)?.takeUnretainedValue() as? NSObject,
              let windows = app.value(forKey: "windows") as? [NSObject] else { return nil }
        return windows.first { ($0.value(forKey: "title") as? String) == title }
    }

    /// Called from the player whenever the pointer moves.
    static func noteCursorMoved() {
        guard gameModeActive else { return }
        setChromeHidden(false)
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: cursorIdleDelay, repeats: false) { _ in
            hideCursorUntilMoved()
        }
        // Common mode so a menu tracking the pointer does not freeze the
        // clock and leave the pointer up for good.
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private static var dimmedBars: [UIView] = []

    /// The bar over a running game, hidden and revealed on the same
    /// clock as the pointer.
    ///
    /// Catalyst keeps the presenting screen's navigation bar drawn
    /// behind a full screen cover, which is why the sidebar toggle, the
    /// favourite star and the close button sat on top of the picture.
    /// Hiding it from the player's own view does not work, because the
    /// bar does not belong to the player.
    ///
    /// Alpha rather than isHidden: a navigation controller owns its
    /// bar's hidden flag and will set it back, and alpha leaves the
    /// layout alone so nothing shifts when it returns. Alpha 0 also
    /// still takes touches on iOS 26, which is what this project already
    /// learned the hard way, and here that is wanted: the bar keeps
    /// working the instant it is visible again.
    /// The titlebar toolbars taken away while the game is uninterrupted,
    /// kept so the exact same objects can be put back.
    private static var stashedToolbars: [UIWindowScene: NSToolbar] = [:]

    private static func setChromeHidden(_ hidden: Bool) {
        // The bar over the game is the window's TITLEBAR toolbar, not a
        // UIKit navigation bar: with a sidebar in the window, Catalyst
        // hoists the sidebar toggle and the screen's own buttons up
        // there. Fading navigation bars therefore did nothing to it,
        // which is why it stayed put. Taking the toolbar off the
        // titlebar and putting the same object back is what actually
        // moves it.
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, isShell(windowScene),
                  let titlebar = windowScene.titlebar else { continue }
            if hidden {
                if let toolbar = titlebar.toolbar {
                    stashedToolbars[windowScene] = toolbar
                    titlebar.toolbar = nil
                }
            } else if let toolbar = stashedToolbars.removeValue(forKey: windowScene) {
                titlebar.toolbar = toolbar
            }
        }
        if hidden {
            var found: [UIView] = []
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene, isShell(windowScene) else { continue }
                for window in windowScene.windows {
                    collectBars(window, into: &found)
                }
            }
            dimmedBars = found
            for bar in found { bar.alpha = 0 }
        } else {
            for bar in dimmedBars { bar.alpha = 1 }
            dimmedBars = []
        }
    }

    private static func collectBars(_ view: UIView, into out: inout [UIView]) {
        if view is UINavigationBar {
            out.append(view)
            return
        }
        for sub in view.subviews { collectBars(sub, into: &out) }
    }

    private static func hideCursorUntilMoved() {
        setChromeHidden(true)
        guard let cursor = NSClassFromString("NSCursor") as AnyObject as? NSObjectProtocol else { return }
        let selector = NSSelectorFromString("setHiddenUntilMouseMoves:")
        if cursor.responds(to: selector) {
            _ = cursor.perform(selector, with: true as NSNumber)
        }
    }

    private static func revealCursor() {
        guard let cursor = NSClassFromString("NSCursor") as AnyObject as? NSObjectProtocol else { return }
        let selector = NSSelectorFromString("setHiddenUntilMouseMoves:")
        if cursor.responds(to: selector) {
            _ = cursor.perform(selector, with: false as NSNumber)
        }
    }

    /// UIKit gives the tab container an opaque `systemBackground` plane,
    /// which in the Mac shell sits exactly between the ambient backdrop
    /// and the content, erasing the backdrop. Clearing every view whose
    /// color IS that default, and only those, keeps materials, cards and
    /// covers untouched: they all set their own colors.
    private static func clearDefaultPlanes() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, isShell(windowScene) else { continue }
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
