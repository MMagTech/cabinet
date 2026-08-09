import SwiftUI

/// The editing surface: everything drawn here sits *over* the real
/// `TouchControlPad`, and nothing here draws a control. The pad renders the
/// controls exactly as the player does; this layer only adds selection,
/// handles, guides and warnings on top. Keeping that split is what stops the
/// editor from drifting into a mockup.
struct EditCanvas: View {
    @Binding var items: [EditableItem]
    @Binding var selection: Set<UUID>
    /// The pad's pixel size: the bottom strip in portrait, the screen in
    /// landscape, matching what the player hands its own pad.
    let size: CGSize
    var showsExtended: Bool
    var showsWarnings: Bool
    /// Fired once a gesture ends, not per frame, so the working copy on disk
    /// tracks finished edits rather than every intermediate frame of a drag.
    var onCommit: () -> Void = {}

    /// Positions land on multiples of this. Fine enough never to feel
    /// constrained (half a percent of the strip is about two points), coarse
    /// enough that exported files read as 0.62 rather than 0.6183726, and it
    /// divides every value the existing layouts already use so loading a file
    /// and saving it back moves nothing.
    static let step = 0.005

    @State private var drag: DragState = .idle
    @State private var guides: [Guide] = []

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in handleChange(value) }
                .onEnded { value in handleEnd(value) }
        )
    }

    // MARK: Drag handling

    private enum DragState {
        case idle
        /// Moving one or more items together. Origins are snapshotted at the
        /// start so the whole gesture is computed from where things were,
        /// not accumulated frame by frame, which drifts.
        case moving(origins: [UUID: EditableItem])
        case resizing(id: UUID, corner: Corner, origin: EditableItem)
        case marquee(start: CGPoint, current: CGPoint)
        /// A press that has not yet moved far enough to be anything.
        case pending(hitID: UUID?, start: CGPoint)
    }

    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing
    }

    struct Guide: Identifiable {
        let id = UUID()
        let vertical: Bool
        /// Normalised position along the axis it cuts.
        let at: Double
    }

    private func handleChange(_ value: DragGesture.Value) {
        switch drag {
        case .idle:
            begin(at: value.startLocation)
            // Re-enter with the same event so the first movement is not lost.
            // Terminates: `begin` never leaves the state idle.
            handleChange(value)
        case .pending(let hitID, let start):
            let moved = hypot(value.translation.width, value.translation.height)
            guard moved > 4 else { return }
            if let hitID {
                promoteToMove(hitID: hitID)
                handleChange(value)
            } else {
                drag = .marquee(start: start, current: value.location)
            }
        case .moving(let origins):
            applyMove(origins: origins, translation: value.translation)
        case .resizing(let id, let corner, let origin):
            applyResize(id: id, corner: corner, origin: origin, translation: value.translation)
        case .marquee(let start, _):
            drag = .marquee(start: start, current: value.location)
        }
    }

    private func handleEnd(_ value: DragGesture.Value) {
        let moved = hypot(value.translation.width, value.translation.height)
        switch drag {
        case .pending(let hitID, _):
            if moved <= 4 { toggle(hitID) }
        case .marquee(let start, _):
            // A box drawn around a cluster is the fastest way to grab a group
            // like the PS1 diamond, and the reason a drag on empty space is
            // not treated as a mistake.
            let rect = normalizedRect(from: start, to: value.location)
            selection = Set(items.filter { $0.frame.intersects(rect) }.map(\.id))
        case .idle, .moving, .resizing:
            break
        }
        drag = .idle
        guides = []
        onCommit()
    }

    /// A tap toggles membership, which is what makes multiple selection work
    /// without a modifier key there is no room for on a touch screen. A tap
    /// on nothing clears.
    private func toggle(_ id: UUID?) {
        guard let id else {
            selection.removeAll()
            return
        }
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func begin(at point: CGPoint) {
        // Resize handles win over everything: they sit on top of the item
        // they belong to, and a corner grab must never be read as a move.
        if selection.count == 1, let id = selection.first,
           let item = items.first(where: { $0.id == id }),
           let corner = handleHit(item: item, at: point) {
            drag = .resizing(id: id, corner: corner, origin: item)
            return
        }
        drag = .pending(hitID: hitTest(point)?.id, start: point)
    }

    private func promoteToMove(hitID: UUID) {
        if !selection.contains(hitID) {
            selection = [hitID]
        }
        let origins = Dictionary(
            uniqueKeysWithValues: items.filter { selection.contains($0.id) }.map { ($0.id, $0) }
        )
        drag = .moving(origins: origins)
    }

    /// The item under a point. Drawn frames are what a finger is aiming at,
    /// but small pills are hard to land on, so the frame gets a few points of
    /// slack. Later items win, matching the draw order a finger sees.
    private func hitTest(_ point: CGPoint) -> EditableItem? {
        items.reversed().first { item in
            item.frame.resolved(in: size).insetBy(dx: -8, dy: -8).contains(point)
        }
    }

    private func handleHit(item: EditableItem, at point: CGPoint) -> Corner? {
        let rect = item.frame.resolved(in: size)
        for corner in Corner.allCases {
            let centre = handleCentre(rect: rect, corner: corner)
            if hypot(point.x - centre.x, point.y - centre.y) < 22 { return corner }
        }
        return nil
    }

    private func handleCentre(rect: CGRect, corner: Corner) -> CGPoint {
        switch corner {
        case .topLeading: return CGPoint(x: rect.minX, y: rect.minY)
        case .topTrailing: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeading: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomTrailing: return CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // MARK: Moving

    /// Moves the whole selection by one delta, so a group like an A/B pair or
    /// the PS1 diamond keeps its internal shape exactly. The selection's
    /// bounding box is what snaps; members ride along on the same offset.
    private func applyMove(origins: [UUID: EditableItem], translation: CGSize) {
        guard let box = boundingBox(of: origins.values.map(\.frame)) else { return }
        let rawDX = Double(translation.width) / Double(size.width)
        let rawDY = Double(translation.height) / Double(size.height)

        var dx = Self.snap(box.x + rawDX) - box.x
        var dy = Self.snap(box.y + rawDY) - box.y

        let moved = EditRect(x: box.x + dx, y: box.y + dy, w: box.w, h: box.h)
        let found = alignment(for: moved, excluding: Set(origins.keys))
        if let ax = found.x { dx += ax }
        if let ay = found.y { dy += ay }
        guides = found.guides

        // Keep the drawn frames on screen. Extended frames are allowed to run
        // off the edge, which is how the landscape layouts already reach the
        // bezel.
        let final = EditRect(x: box.x + dx, y: box.y + dy, w: box.w, h: box.h)
        if final.x < 0 { dx -= final.x }
        if final.y < 0 { dy -= final.y }
        if final.maxX > 1 { dx -= final.maxX - 1 }
        if final.maxY > 1 { dy -= final.maxY - 1 }

        for index in items.indices {
            guard let origin = origins[items[index].id] else { continue }
            items[index].frame = origin.frame.offset(dx: dx, dy: dy)
            items[index].extended = origin.extended.offset(dx: dx, dy: dy)
        }
    }

    /// Edge and centre alignment against everything not being dragged, plus
    /// the pad's own centre lines. This is what stops two buttons sitting a
    /// hair off the same row, which is what reads as sloppy in a finished
    /// layout more than any single position does.
    private func alignment(
        for box: EditRect, excluding ignored: Set<UUID>
    ) -> (x: Double?, y: Double?, guides: [Guide]) {
        let thresholdX = 7 / Double(size.width)
        let thresholdY = 7 / Double(size.height)

        var targetsX: [Double] = [0.5]
        var targetsY: [Double] = [0.5]
        for item in items where !ignored.contains(item.id) {
            targetsX += [item.frame.x, item.frame.midX, item.frame.maxX]
            targetsY += [item.frame.y, item.frame.midY, item.frame.maxY]
        }

        var bestX: (delta: Double, at: Double)?
        for edge in [box.x, box.midX, box.maxX] {
            for target in targetsX where abs(target - edge) < thresholdX {
                let delta = target - edge
                if bestX == nil || abs(delta) < abs(bestX!.delta) { bestX = (delta, target) }
            }
        }
        var bestY: (delta: Double, at: Double)?
        for edge in [box.y, box.midY, box.maxY] {
            for target in targetsY where abs(target - edge) < thresholdY {
                let delta = target - edge
                if bestY == nil || abs(delta) < abs(bestY!.delta) { bestY = (delta, target) }
            }
        }

        var lines: [Guide] = []
        if let bestX { lines.append(Guide(vertical: true, at: bestX.at)) }
        if let bestY { lines.append(Guide(vertical: false, at: bestY.at)) }
        return (bestX?.delta, bestY?.delta, lines)
    }

    // MARK: Resizing

    private func applyResize(id: UUID, corner: Corner, origin: EditableItem, translation: CGSize) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let dx = Double(translation.width) / Double(size.width)
        let dy = Double(translation.height) / Double(size.height)
        let minimum = Self.step * 4

        var frame = origin.frame
        switch corner {
        case .topLeading:
            let x = min(Self.snap(origin.frame.x + dx), origin.frame.maxX - minimum)
            let y = min(Self.snap(origin.frame.y + dy), origin.frame.maxY - minimum)
            frame = EditRect(x: x, y: y, w: origin.frame.maxX - x, h: origin.frame.maxY - y)
        case .topTrailing:
            let maxX = max(Self.snap(origin.frame.maxX + dx), origin.frame.x + minimum)
            let y = min(Self.snap(origin.frame.y + dy), origin.frame.maxY - minimum)
            frame = EditRect(x: origin.frame.x, y: y, w: maxX - origin.frame.x, h: origin.frame.maxY - y)
        case .bottomLeading:
            let x = min(Self.snap(origin.frame.x + dx), origin.frame.maxX - minimum)
            let maxY = max(Self.snap(origin.frame.maxY + dy), origin.frame.y + minimum)
            frame = EditRect(x: x, y: origin.frame.y, w: origin.frame.maxX - x, h: maxY - origin.frame.y)
        case .bottomTrailing:
            let maxX = max(Self.snap(origin.frame.maxX + dx), origin.frame.x + minimum)
            let maxY = max(Self.snap(origin.frame.maxY + dy), origin.frame.y + minimum)
            frame = EditRect(x: origin.frame.x, y: origin.frame.y, w: maxX - origin.frame.x, h: maxY - origin.frame.y)
        }

        items[index].frame = frame
        items[index].applyPadding(origin.padding)
    }

    // MARK: Geometry helpers

    static func snap(_ value: Double) -> Double {
        (value / step).rounded() * step
    }

    private func boundingBox(of rects: [EditRect]) -> EditRect? {
        guard let first = rects.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.maxX, maxY = first.maxY
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x); minY = min(minY, rect.y)
            maxX = max(maxX, rect.maxX); maxY = max(maxY, rect.maxY)
        }
        return EditRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> EditRect {
        let minX = Double(min(a.x, b.x)) / Double(size.width)
        let maxX = Double(max(a.x, b.x)) / Double(size.width)
        let minY = Double(min(a.y, b.y)) / Double(size.height)
        let maxY = Double(max(a.y, b.y)) / Double(size.height)
        return EditRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext) {
        if showsWarnings {
            for warning in ControlWarning.find(in: items) {
                let rect = warning.region.resolved(in: size)
                context.fill(Path(rect), with: .color(warning.severity.colour.opacity(0.30)))
                context.stroke(
                    Path(rect), with: .color(warning.severity.colour.opacity(0.9)), lineWidth: 1
                )
            }
        }

        for item in items {
            let frame = item.frame.resolved(in: size)
            let selected = selection.contains(item.id)

            if showsExtended {
                context.stroke(
                    Path(item.extended.resolved(in: size)),
                    with: .color(.white.opacity(selected ? 0.7 : 0.25)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
            }

            context.stroke(
                Path(frame),
                with: .color(selected ? .cyan : .white.opacity(0.35)),
                lineWidth: selected ? 2 : 1
            )

            if selected && selection.count == 1 {
                for corner in Corner.allCases {
                    let centre = handleCentre(rect: frame, corner: corner)
                    let box = CGRect(x: centre.x - 7, y: centre.y - 7, width: 14, height: 14)
                    context.fill(Path(ellipseIn: box), with: .color(.cyan))
                    context.stroke(Path(ellipseIn: box), with: .color(.black.opacity(0.6)), lineWidth: 1)
                }
            }
        }

        for guide in guides {
            var path = Path()
            if guide.vertical {
                let x = guide.at * size.width
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            } else {
                let y = guide.at * size.height
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.pink), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        if case .marquee(let start, let current) = drag {
            let rect = CGRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y)
            )
            context.fill(Path(rect), with: .color(.cyan.opacity(0.12)))
            context.stroke(
                Path(rect), with: .color(.cyan.opacity(0.8)),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        }
    }
}

/// Overlapping hit frames, which the layouts have a real history of.
///
/// Two kinds, and they are not equally bad. A d-pad overlapping a button is a
/// genuine fault: `ControlPadView.inputs(at:)` adds the d-pad's directions
/// *and* the nearest button, so a touch in the shared region fires both at
/// once. Two buttons overlapping is milder, since the nearest centre wins and
/// only one fires, but the boundary between them still lands somewhere the
/// eye cannot see, which is what the Start/Select against Menu complaints
/// have been about.
struct ControlWarning {
    enum Severity {
        case conflict
        case soft

        var colour: Color {
            switch self {
            case .conflict: return .red
            case .soft: return .orange
            }
        }
    }

    let region: EditRect
    let severity: Severity

    static func find(in items: [EditableItem]) -> [ControlWarning] {
        var found: [ControlWarning] = []
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i], b = items[j]
                guard a.extended.intersects(b.extended) else { continue }
                guard let region = intersection(a.extended, b.extended) else { continue }
                let directional: Set<ControlLayout.Item.Kind> = [.dpad, .stick]
                let mixed = directional.contains(a.kind) != directional.contains(b.kind)
                let bothDirectional = directional.contains(a.kind) && directional.contains(b.kind)
                found.append(
                    ControlWarning(region: region, severity: mixed || bothDirectional ? .conflict : .soft)
                )
            }
        }
        return found
    }

    private static func intersection(_ a: EditRect, _ b: EditRect) -> EditRect? {
        let x = max(a.x, b.x), y = max(a.y, b.y)
        let maxX = min(a.maxX, b.maxX), maxY = min(a.maxY, b.maxY)
        guard maxX > x, maxY > y else { return nil }
        return EditRect(x: x, y: y, w: maxX - x, h: maxY - y)
    }
}
