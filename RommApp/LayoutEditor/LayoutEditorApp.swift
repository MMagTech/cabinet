import SwiftUI

/// Cabinet's control layout editor.
///
/// A second app target that never ships. It exists because tuning touch
/// controls by hand editing normalised fractions and rebuilding the player
/// to look at the result is a terrible loop, and because judging a layout
/// anywhere other than a real device in a real hand has already proven
/// unreliable.
///
/// The one rule that makes it trustworthy: it draws layouts with the
/// player's own `TouchControlPad`, reading the player's own `ControlLayout`,
/// compiled from the same source files rather than copied. Anything that
/// reimplemented the rendering would drift and start lying, which is exactly
/// how the mockups failed. If the schema changes under it, this target stops
/// compiling instead of quietly showing something false.
@main
struct LayoutEditorApp: App {
    var body: some Scene {
        WindowGroup {
            EditorRootView()
        }
    }
}
