import SwiftUI

/// The Mac's pointer-and-glass idiom, the desk translation of the TV's
/// focus grammar. Shared file so every screen can wear these; both
/// helpers compile to nothing everywhere but Mac Catalyst.

extension View {
    /// The pointer's version of the TV's focus lift: covers and cards
    /// grow gently under the cursor, the same 0.18s ease the TV's
    /// CoverFocusStyle uses, with a shadow standing in for the focus
    /// halo a TV paints.
    @ViewBuilder
    func macHoverLift() -> some View {
        #if targetEnvironment(macCatalyst)
        modifier(MacHoverLift())
        #else
        self
        #endif
    }

    /// A List that stops painting its opaque grouped background on the
    /// Mac, so the ambient shell shows through behind glass rows. Pair
    /// with tvRow() on the sections where the row plates matter.
    @ViewBuilder
    func macTransparentList() -> some View {
        #if targetEnvironment(macCatalyst)
        self.scrollContentBackground(.hidden)
        #else
        self
        #endif
    }

    /// The TV settings row treatment on the Mac: glass behind list
    /// rows instead of the iOS grouped-list slab. A no-op on iOS and
    /// tvOS, where each platform's own list chrome is already right.
    @ViewBuilder
    func tvRow() -> some View {
        #if targetEnvironment(macCatalyst)
        self.listRowBackground(
            Rectangle().fill(.ultraThinMaterial)
        )
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct MacHoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.05 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.35 : 0), radius: 14, y: 8)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}
#endif
