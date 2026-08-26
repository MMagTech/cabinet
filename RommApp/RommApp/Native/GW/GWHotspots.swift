// iOS-only, like the core it serves; the television never links gw
// (docs/building.md) and tvOS has no touches to map anyway.
#if !os(tvOS)
import UIKit

/// Where each Game & Watch simulator draws its buttons, so a tap on the
/// artwork presses the real thing.
///
/// Marcus, 2026-08-25: "I don't want a controller, I want to click the
/// buttons on the screen as if I were really playing the game back in
/// the day." The simulators ignore the libretro pointer (proven with
/// scripted taps in the bench), so taps must become JOYPAD presses, and
/// that needs to know where every drawn button sits, per game.
///
/// Nobody hand-mapped 59 games. Every sim draws its button PRESSED when
/// the mapped input is held, so tools/lab/gw/extract_hotspots.py runs
/// each game headlessly, presses each input, diffs the frames against an
/// unpressed run with the game's own idle animation masked out, and the
/// pixels that changed are the button. The games mapped themselves; this
/// file only reads the result. Hard-coded data by design, not editor
/// content: the editor edits layouts, and this is a fact about artwork.
struct GWHotspots: Decodable {
    let width: Int
    let height: Int
    /// The artwork's own orientation: wider than tall plays landscape.
    /// The player locks to this, per Marcus's call that a game may own
    /// its orientation if that is what the tap surface needs.
    let orientation: String
    let buttons: [String: [Int]]
    /// The framework's hand-menu entries, in cycle order: a tap on one
    /// synthesizes select pressed `seq` times then start, which is how
    /// the sims themselves press GAME A. Read out of each game's own
    /// decoded source, rects included.
    let menu: [MenuEntry]?
    /// Menu-less games (Egg's generation) keep direct shoulder keys for
    /// their service buttons; a tap holds the id like any other button.
    let direct: [DirectEntry]?

    struct MenuEntry: Decodable {
        let label: String
        let seq: Int
        let rect: [Int]
    }
    struct DirectEntry: Decodable {
        let label: String
        let id: Int
        let rect: [Int]
    }

    var isLandscape: Bool { orientation == "landscape" }

    /// RetroPad ids for the extractor's button names.
    static let pad: [String: Int] = [
        "b": 0, "y": 1, "select": 2, "start": 3, "up": 4, "down": 5,
        "left": 6, "right": 7, "a": 8, "x": 9, "l": 10, "r": 11,
    ]

    /// The map, keyed by the rom's file name, which is how the extractor
    /// keyed it and the one identifier both sides always agree on.
    static func spec(for fsName: String) -> GWHotspots? {
        table[fsName]
    }

    private static let table: [String: GWHotspots] = {
        guard let url = Bundle.main.url(forResource: "gw-hotspots", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode([String: GWHotspots].self, from: data)
        else { return [:] }
        return parsed
    }()

    /// What a tap at an artwork pixel means. Hit areas are the drawn
    /// button grown by a thumb's slop, 14 artwork pixels.
    enum Hit {
        case hold(Int)          // press while the finger is down
        case sequence(Int)      // select x seq then start, fire once
    }

    private static func inside(_ r: [Int], _ x: Int, _ y: Int) -> Bool {
        let pad = 14
        return r.count == 4 && x >= r[0] - pad && x <= r[0] + r[2] + pad
            && y >= r[1] - pad && y <= r[1] + r[3] + pad
    }

    func hit(atArtworkX x: Int, y: Int) -> Hit? {
        for (name, r) in buttons where Self.inside(r, x, y) {
            if let id = Self.pad[name] { return .hold(id) }
        }
        for e in direct ?? [] where Self.inside(e.rect, x, y) {
            return .hold(e.id)
        }
        for e in menu ?? [] where Self.inside(e.rect, x, y) {
            return .sequence(e.seq)
        }
        return nil
    }
}

/// The tap surface over the artwork: full-screen, invisible, multitouch.
/// Each finger resolves to the drawn button under it and holds that
/// button until it lifts, exactly the mechanics TouchControlPad uses for
/// its own buttons, but the targets live in the picture.
final class GWTapSurface: UIView {
    var spec: GWHotspots?
    var send: (Int, Bool) -> Void = { _, _ in }
    /// The picture's aspect-fitted frame inside this view; recomputed
    /// per touch because rotation and zoom both move it. Zoom changes
    /// the frame's aspect away from the artwork's, and while it does the
    /// hotspots are stale, so taps are dropped rather than mislanded.
    var displayAspect: () -> Double = { 0 }

    private var held: [UITouch: Int] = [:]
    private var sequencing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    private func pictureFrame() -> CGRect? {
        guard let spec else { return nil }
        let art = Double(spec.width) / Double(spec.height)
        let shown = displayAspect()
        // Zoomed: the core is presenting a crop, not the panel. The
        // drawn buttons are off screen, so nothing is tappable.
        if shown > 0, abs(shown - art) > 0.02 { return nil }
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return nil }
        if Double(w) / Double(h) > art {
            let pw = CGFloat(art) * h
            return CGRect(x: (w - pw) / 2, y: 0, width: pw, height: h)
        }
        let ph = w / CGFloat(art)
        return CGRect(x: 0, y: (h - ph) / 2, width: ph, height: ph > 0 ? ph : 0)
            .with(height: ph)
    }

    private func hitAt(_ point: CGPoint) -> GWHotspots.Hit? {
        guard let spec, let pic = pictureFrame(), pic.contains(point) else { return nil }
        let ax = Int((point.x - pic.minX) / pic.width * CGFloat(spec.width))
        let ay = Int((point.y - pic.minY) / pic.height * CGFloat(spec.height))
        return spec.hit(atArtworkX: ax, y: ay)
    }

    private func buttonAt(_ point: CGPoint) -> Int? {
        if case .hold(let id)? = hitAt(point) { return id }
        return nil
    }

    /// Presses a hand-menu entry the way the framework's own keys do:
    /// select opens the menu on entry one, each further select advances
    /// it, start presses the pointed entry and its release confirms.
    /// Paced at 90ms a step, comfortably past the sims' 60Hz poll, and
    /// one sequence at a time: a second tap mid-dance would desync the
    /// hand from the count.
    private func runSequence(_ seq: Int) {
        guard !sequencing else { return }
        sequencing = true
        var steps: [(Int, Bool)] = []
        for _ in 0..<seq { steps.append((2, true)); steps.append((2, false)) }
        steps.append((3, true)); steps.append((3, false))
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09 * Double(i)) { [weak self] in
                self?.send(step.0, step.1)
                if i == steps.count - 1 { self?.sequencing = false }
            }
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            switch hitAt(t.location(in: self)) {
            case .hold(let id)?:
                held[t] = id
                send(id, true)
            case .sequence(let seq)?:
                runSequence(seq)
            case nil:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A finger sliding off a real button releases it; sliding onto
        // one presses it. Same continuity the pad's d-pad honours.
        for t in touches {
            let now = buttonAt(t.location(in: self))
            if let was = held[t], was != now { send(was, false); held[t] = nil }
            if let now, held[t] == nil { held[t] = now; send(now, true) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { if let id = held.removeValue(forKey: t) { send(id, false) } }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

private extension CGRect {
    func with(height h: CGFloat) -> CGRect { CGRect(x: minX, y: minY, width: width, height: h) }
}

import SwiftUI

struct GWTapView: UIViewRepresentable {
    let spec: GWHotspots
    let send: (Int, Bool) -> Void
    let displayAspect: () -> Double

    func makeUIView(context: Context) -> GWTapSurface {
        let v = GWTapSurface()
        v.spec = spec
        v.send = send
        v.displayAspect = displayAspect
        return v
    }
    func updateUIView(_ v: GWTapSurface, context: Context) {
        v.spec = spec
        v.displayAspect = displayAspect
    }
}

#endif
