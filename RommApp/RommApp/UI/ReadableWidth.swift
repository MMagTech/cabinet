import SwiftUI

extension View {
    /// Caps how wide content grows, then centres it.
    ///
    /// A list row stretched across a landscape phone puts its label and its
    /// value most of a screen apart, which reads as broken rather than
    /// spacious, and the same stretch turns a form field into a runway. Every
    /// list and form in the app runs through this so a rotation changes how
    /// much fits on screen, not how legible it is.
    func readableWidth(_ limit: CGFloat = 620) -> some View {
        frame(maxWidth: limit)
            .frame(maxWidth: .infinity)
    }
}
