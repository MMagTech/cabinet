//  The surface PCSX2 draws into on the Mac.
//
//  Every other core in Cabinet renders through NativePlayerRenderer,
//  which takes a framebuffer from libretro and draws it with Cabinet's
//  own Metal shaders. PS2 cannot work that way: PCSX2 is not a
//  libretro core, it owns its renderer, its GS thread and its
//  presentation, and it wants a CAMetalLayer to present into.
//
//  So this view hands it one and stays out of the way. That also means
//  none of Cabinet's shaders, bezels or letterbox treatment apply to
//  PS2 yet, which is a real gap rather than an oversight.
//
//  THE CONTRACT, and it is not optional: layerClass must be
//  CAMetalLayer. UIKit makes a view's layer read-only and fixed at
//  creation, so unlike AppKit there is no handing one over afterwards.
//  Both CabinetCocoaTools and GSDeviceMTL take the layer the view
//  already has, and a plain view with a CAMetalLayer added as a
//  sublayer would compile, run, and quietly stop tracking the view's
//  bounds.

import SwiftUI
import UIKit

final class PS2MetalView: UIView, UIPointerInteractionDelegate {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Fires once the view has a real size, never before. PCSX2 reads
    /// the drawable size when it opens its device, and a zero there
    /// gives a surface with no pixels: 60fps, no picture, no error.
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
        // drawableSize, and PCSX2 sets drawableSize itself to match
        // what it renders. Two owners of one property, rewritten on
        // every layout pass and every video mode change, is what made
        // the picture flicker and disappear.
        if !reported {
            metalLayer.contentsScale = scale
        }

        let pixels = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard pixels.width >= 1, pixels.height >= 1 else { return }

        let width = UInt32(pixels.width)
        let height = UInt32(pixels.height)

        guard reported else {
            reported = true
            lastReported = pixels
            CabinetPS2SetSurfaceSize(width, height, Float(scale))
            onSized?(Unmanaged.passUnretained(self).toOpaque())
            return
        }

        // Afterwards a real size change goes through PCSX2's own
        // resize path, on its GS thread, which is the only thing
        // allowed to touch the drawable once a game is running.
        guard pixels != lastReported else { return }
        lastReported = pixels
        CabinetPS2ResizeDisplay(width, height, Float(scale))
    }
}

struct PS2MetalSurface: UIViewRepresentable {
    /// Called once the view exists AND has a non-zero size, with the
    /// pointer PCSX2 needs.
    let onReady: (UnsafeMutableRawPointer) -> Void

    func makeUIView(context: Context) -> PS2MetalView {
        let view = PS2MetalView()
        view.isOpaque = true
        view.backgroundColor = .black
        view.onSized = onReady
        return view
    }

    func updateUIView(_ uiView: PS2MetalView, context: Context) {}
}
