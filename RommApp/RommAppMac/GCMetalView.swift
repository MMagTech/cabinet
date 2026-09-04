//  The surface Dolphin draws into on the Mac.
//
//  Every libretro core in Cabinet renders through NativePlayerRenderer,
//  which takes a framebuffer from the core and draws it with Cabinet's
//  own Metal shaders. GameCube cannot work that way, for the same
//  reason PS2 cannot: Dolphin owns its renderer, its video thread and
//  its presentation, and it wants a CAMetalLayer to present into.
//
//  So this view hands it one and stays out of the way. That also means
//  none of Cabinet's shaders, bezels or letterbox treatment apply to
//  GameCube yet, which is a real gap rather than an oversight, and the
//  same gap PS2 has.
//
//  Dolphin's Metal backend is easier to hand a layer to than PCSX2's.
//  It takes wsi.render_surface as a CAMetalLayer directly, and its
//  PrepareWindow, the only part that wants a real NSView, is compiled
//  out under Catalyst. So there is no window to fake: the layer goes in
//  and nothing asks for anything else.
//
//  THE CONTRACT, and it is not optional: layerClass must be
//  CAMetalLayer. UIKit makes a view's layer read-only and fixed at
//  creation, so unlike AppKit there is no handing one over afterwards.
//  A plain view with a CAMetalLayer added as a sublayer would compile,
//  run, and quietly stop tracking the view's bounds.

import SwiftUI
import UIKit

final class GCMetalView: UIView, UIPointerInteractionDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Fires once the view has a real size, never before. Dolphin reads
    /// the drawable size when it opens its device, and a zero there
    /// gives a surface with no pixels: a running emulator, a healthy
    /// log, and no picture. PS2 lost an evening to exactly that.
    var onSized: ((UnsafeMutableRawPointer) -> Void)?
    private var reported = false
    private var lastReported: CGSize = .zero

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard interactions.isEmpty else { return }
        // Catalyst has no NSCursor to hide, and UIKit has no direct
        // "hide the pointer" call either. A pointer interaction that
        // answers with the hidden style is the supported way, and it
        // scopes the hiding to this view, so the pointer comes back by
        // itself over anything else.
        addInteraction(UIPointerInteraction(delegate: self))
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction, styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        .hidden()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pushSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        pushSize()
    }

    private func pushSize() {
        let scale = window?.screen.scale ?? traitCollection.displayScale

        // contentsScale is set ONCE, before the emulator starts, and
        // never again. Setting it makes CAMetalLayer recompute
        // drawableSize, and Dolphin's presenter sets drawableSize itself
        // to match what it renders. Two owners of one property,
        // rewritten on every layout pass and every video mode change, is
        // what made PS2's picture flicker and disappear.
        if !reported {
            metalLayer.contentsScale = scale
        }

        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixels.width >= 1, pixels.height >= 1 else { return }

        let width = Int32(pixels.width)
        let height = Int32(pixels.height)

        guard reported else {
            reported = true
            lastReported = pixels
            CabinetDolphinSetSurfaceLayer(Unmanaged.passUnretained(metalLayer).toOpaque())
            CabinetDolphinSetSurfaceSize(width, height, Float(scale))
            // A permanent line, for the same reason PS2 has one: a
            // zero-sized surface is invisible in every other signal.
            // The frame counter reads fine, the log reads fine, and the
            // screen is black.
            NSLog("[GC] Render surface: %dx%d @%.1fx", width, height, scale)
            onSized?(Unmanaged.passUnretained(self).toOpaque())
            return
        }

        // Afterwards a real size change goes through Dolphin's own
        // resize path, on its own thread, which is the only thing
        // allowed to touch the drawable once a game is running.
        guard pixels != lastReported else { return }
        lastReported = pixels
        CabinetDolphinSetSurfaceSize(width, height, Float(scale))
    }
}

struct GCMetalSurface: UIViewRepresentable {
    /// Called once the view exists AND has a non-zero size.
    let onReady: (UnsafeMutableRawPointer) -> Void

    func makeUIView(context: Context) -> GCMetalView {
        let view = GCMetalView()
        view.isOpaque = true
        view.backgroundColor = .black
        view.onSized = onReady
        return view
    }

    func updateUIView(_ uiView: GCMetalView, context: Context) {}
}
