import SwiftUI

/// Sizes that differ between a phone in your hand and a TV across the
/// room, in one place rather than scattered `#if os(tvOS)` branches
/// through every shelf and grid.
///
/// tvOS's coordinate space is 1920x1080 points regardless of whether the
/// panel is 1080p or 4K (it renders at 2x for 4K), so an iOS-sized 100pt
/// cover is about 5% of the screen width, which reads as a postage stamp
/// from a sofa. Apple's own 10-foot guidance is fewer, larger targets
/// rather than a denser grid: these values put a shelf cover at roughly
/// 15% of the width, which is about what the Apple TV app itself uses.
enum TenFoot {
    #if os(tvOS)
    static let isTV = true
    static let isMac = false
    #elseif targetEnvironment(macCatalyst)
    static let isTV = false
    static let isMac = true
    #else
    static let isTV = false
    static let isMac = false
    #endif

    /// Shelf cover art on Home. 3:4, the aspect every cover in the app
    /// already uses. The Mac tier is the ten-foot design read at one to
    /// three feet: the TV's own composition, scaled for a desk, so it
    /// sits between the sofa's 260 and the palm's 100.
    static var shelfCoverWidth: CGFloat { isTV ? 260 : (isMac ? 156 : 100) }
    static var shelfCoverHeight: CGFloat { isTV ? 347 : (isMac ? 208 : 133) }
    static var shelfSpacing: CGFloat { isTV ? 40 : (isMac ? 20 : 12) }

    /// The caption under a cover, and the header above a shelf. `.callout`
    /// on tvOS, not `.title3`: the rom grid's own cover captions
    /// (TVRomGridView) already use `.callout` directly, so `.title3` here
    /// meant Home's shelves ran visibly larger than Library's grid for the
    /// same kind of label, not a deliberate size difference.
    static var captionFont: Font { isTV ? .callout : (isMac ? .callout : .caption) }
    static var sectionHeaderFont: Font { isTV ? .title2.bold() : (isMac ? .title3.bold() : .headline) }

    /// The library's own cover grid (RomListView), which is a full screen
    /// of covers rather than a single scrolling row.
    static var gridCoverMinimum: CGFloat { isTV ? 240 : (isMac ? 150 : 110) }
    static var gridSpacing: CGFloat { isTV ? 36 : (isMac ? 20 : 12) }

    /// Horizontal inset for content. tvOS needs a real overscan-safe
    /// margin; iOS just needs the usual gutter, and a desk-distance
    /// window wants something in between.
    static var contentInset: CGFloat { isTV ? 60 : (isMac ? 32 : 20) }
}
