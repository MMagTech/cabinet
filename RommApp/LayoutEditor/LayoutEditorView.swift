import SwiftUI
import UIKit

/// One layout, being edited at the size and in the place the player would
/// actually draw it.
///
/// The geometry here is copied from `NativePlayerView.body` deliberately, and
/// has to stay copied: portrait keeps a canvas above a 330pt control strip
/// and normalises the pad against *the strip, plus its own headroom* when a
/// layout asks for one, landscape overlays the pad on the whole screen and
/// normalises against *the screen*. Get that wrong and every number the
/// editor produces is wrong by the ratio between the two, which is exactly
/// the class of mistake that made editing these files by hand unpleasant in
/// the first place.
struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss

    @State var layout: EditableLayout
    @State private var selection: Set<UUID> = []
    @State private var testing = false
    @State private var showsExtended = true
    @State private var showsWarnings = true
    @State private var showsChrome = true
    @State private var share: ShareItem?
    @State private var note: String?
    @State private var ready = false

    /// `PlayerView.controlStripHeight` and `NativePlayerView.controlStripHeight`
    /// both return this for everything that is not a vertical arcade board,
    /// which is every layout this editor opens.
    private static let stripHeight: CGFloat = 330

    /// Mirrors both players' `padHeight` exactly: zero headroom reproduces
    /// `stripHeight` unchanged, so every layout that has never asked for
    /// headroom edits at the same size it always has.
    /// Which landscape arrangement is being shaped. Rotation picks
    /// portrait from landscape, and always did, but companion is ALSO
    /// landscape, so for the first time two arrangements share an
    /// orientation and rotation cannot separate them. Named by what
    /// they mean rather than by their JSON keys: one shares the screen
    /// with a game, the other does not.
    @State private var editingCompanion = false

    private var padPortraitHeight: CGFloat {
        Self.stripHeight * (1 + (layout.headroom ?? 0))
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let padSize = landscape
                ? geo.size
                : CGSize(width: geo.size.width, height: padPortraitHeight)

            // Portrait's controls live in the bottom strip only, so a
            // top-pinned toolbar never covers anything. Landscape's controls
            // flank the full screen, shoulders and Menu are routinely
            // anchored right at the top edge, and a top toolbar sits
            // directly on top of them. Anchoring the chrome to whichever
            // edge is actually clear per orientation, rather than a fixed
            // spot, is what keeps it from blocking the thing it's meant to
            // help edit.
            ZStack(alignment: landscape ? .bottom : .top) {
                if landscape {
                    ZStack {
                        // A controller-only pad has no game behind it,
                        // and drawing one would invite exactly the
                        // gutter-hugging arrangement this mode exists
                        // to get away from.
                        if !editingCompanion {
                            ScreenBackdrop(layout: layout.name)
                        }
                        pad(size: padSize, landscape: true)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ZStack(alignment: .top) {
                        ScreenBackdrop(layout: layout.name)
                            .frame(height: max(geo.size.height - Self.stripHeight, 0))
                        pad(size: padSize, landscape: false)
                            .frame(height: padPortraitHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if landscape, editingCompanion ? layout.companionItems == nil : layout.landscapeItems == nil {
                    missingLandscapeNotice
                }
                if showsChrome {
                    chrome(landscape: landscape, padSize: padSize)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { ready = WorkingCopy.isReady(layout.name) }
        .sheet(item: $share) { item in
            ActivityView(url: item.url)
        }
    }

    // MARK: The pad, and the layer that edits it

    private func pad(size: CGSize, landscape: Bool) -> some View {
        let binding = itemsBinding(landscape: landscape)
        return ZStack {
            TouchControlPad(
                items: binding.wrappedValue.map(\.rendered),
                send: { _, _ in },
                system: layout.system
            )
            // In test mode the real pad takes the touches, so presses light up
            // and haptics fire exactly as they would in a game. In edit mode
            // the canvas above takes them instead.
            .allowsHitTesting(testing)

            if !testing {
                EditCanvas(
                    items: binding,
                    selection: $selection,
                    size: size,
                    showsExtended: showsExtended,
                    showsWarnings: showsWarnings,
                    onCommit: commit
                )
            }

            // A small always present corner button, so hiding the toolbar to
            // see the pad clean is never a one way door. Kept tiny and out of
            // the way rather than a gesture over the whole pad, which would
            // fight the canvas's own drag for every touch.
            if !showsChrome {
                // A plain ZStack centres by default; without an explicit
                // corner alignment this sat dead in the middle of the pad,
                // on top of whatever control happened to be there, instead
                // of tucked out of the way.
                Button { showsChrome = true } label: {
                    Image(systemName: "eye")
                        .font(.system(size: 13))
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func itemsBinding(landscape: Bool) -> Binding<[EditableItem]> {
        Binding(
            get: {
                guard landscape else { return layout.items }
                return editingCompanion
                    ? (layout.companionItems ?? [])
                    : (layout.landscapeItems ?? [])
            },
            set: { updated in
                if !landscape {
                    layout.items = updated
                } else if editingCompanion {
                    layout.companionItems = updated
                } else {
                    layout.landscapeItems = updated
                }
            }
        )
    }

    // MARK: Chrome

    private func chrome(landscape: Bool, padSize: CGSize) -> some View {
        VStack(spacing: 8) {
            toolbar(landscape: landscape)
            if !selection.isEmpty && !testing {
                inspector(landscape: landscape, padSize: padSize)
            }
            if let note {
                Text(note)
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(landscape ? .bottom : .top, 8)
    }

    private func toolbar(landscape: Bool) -> some View {
        HStack(spacing: 14) {
            Button { close() } label: { Image(systemName: "chevron.left") }

            VStack(alignment: .leading, spacing: 1) {
                Text(layout.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(landscape ? (editingCompanion ? "controller only" : "landscape") : "portrait")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Only landscape has two arrangements to choose between.
            if landscape {
                Picker("", selection: $editingCompanion) {
                    Image(systemName: "tv").tag(false)
                    Image(systemName: "iphone.gen3").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: editingCompanion) { _, _ in selection.removeAll() }
            }

            Spacer(minLength: 4)

            Toggle(isOn: $testing) { Image(systemName: "hand.tap") }
                .toggleStyle(.button)
            Button {
                showsExtended.toggle()
            } label: {
                Image(systemName: showsExtended ? "square.dashed" : "square")
            }
            Button {
                showsWarnings.toggle()
            } label: {
                Image(systemName: showsWarnings ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
            }
            Button { showsChrome = false } label: { Image(systemName: "eye.slash") }

            // The whole "submit" gesture: no network call, no reach into the
            // Mac's filesystem, just a flag on this working copy that says
            // "come get this one." Someone on the Mac side still looks at
            // what changed before it lands anywhere real.
            Button {
                commit()
                ready.toggle()
                WorkingCopy.setReady(layout.name, ready)
                flash(ready ? "Marked ready" : "Unmarked")
            } label: {
                Image(systemName: ready ? "checkmark.seal.fill" : "checkmark.seal")
                    .foregroundStyle(ready ? .green : .primary)
            }

            Menu {
                Button("Share file", systemImage: "square.and.arrow.up") { exportFile() }
                Button("Copy JSON", systemImage: "doc.on.doc") { copyJSON() }
                Button("Snap everything to the grid", systemImage: "grid") { tidy() }
                if layout.landscapeItems == nil {
                    Button("Create landscape set from portrait", systemImage: "rectangle.landscape.rotate") {
                        seedLandscape()
                    }
                }
                Divider()
                Button("Revert to bundled", systemImage: "arrow.uturn.backward", role: .destructive) {
                    revert()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func inspector(landscape: Bool, padSize: CGSize) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(selectionTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let single = singleSelected {
                    Text(readout(single.frame))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                stepperCluster(
                    icon: "arrow.up.and.down.and.arrow.left.and.right",
                    minus: "minus", plus: "plus",
                    onMinus: { resize(points: -4, landscape: landscape, padSize: padSize) },
                    onPlus: { resize(points: 4, landscape: landscape, padSize: padSize) }
                )
                stepperCluster(
                    icon: "square.dashed",
                    minus: "minus", plus: "plus",
                    onMinus: { repad(points: -4, landscape: landscape, padSize: padSize) },
                    onPlus: { repad(points: 4, landscape: landscape, padSize: padSize) }
                )
                Spacer(minLength: 2)
                nudgePad(landscape: landscape)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func stepperCluster(
        icon: String, minus: String, plus: String,
        onMinus: @escaping () -> Void, onPlus: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
            Button(action: onMinus) { Image(systemName: minus) }
            Button(action: onPlus) { Image(systemName: plus) }
        }
        .font(.system(size: 13))
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func nudgePad(landscape: Bool) -> some View {
        HStack(spacing: 4) {
            Button { nudge(-1, 0, landscape) } label: { Image(systemName: "arrow.left") }
            VStack(spacing: 4) {
                Button { nudge(0, -1, landscape) } label: { Image(systemName: "arrow.up") }
                Button { nudge(0, 1, landscape) } label: { Image(systemName: "arrow.down") }
            }
            Button { nudge(1, 0, landscape) } label: { Image(systemName: "arrow.right") }
        }
        .font(.system(size: 12))
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private var missingLandscapeNotice: some View {
        VStack(spacing: 10) {
            Text(editingCompanion ? "No controller-only set" : "No landscape set")
                .font(.headline)
            Text(editingCompanion
                 ? "A phone driving a TV falls back to the landscape items, which were drawn to sit around a game that is not there."
                 : "The player falls back to the portrait items here, which works but looks wrong.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button(editingCompanion ? "Create one at panel scale" : "Create one from portrait") {
                if editingCompanion { seedCompanion() } else { seedLandscape() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Centred on its own rather than padded down from the top: the
        // chrome it used to clear now anchors to the bottom in landscape,
        // and a fixed offset tuned for the old position would just as
        // easily land on top of the new one.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Editing actions

    private var singleSelected: EditableItem? {
        guard selection.count == 1 else { return nil }
        return (layout.items + (layout.landscapeItems ?? []) + (layout.companionItems ?? []))
            .first { selection.contains($0.id) }
    }

    private var selectionTitle: String {
        if let single = singleSelected { return single.displayName }
        return "\(selection.count) selected"
    }

    private func readout(_ rect: EditRect) -> String {
        let n = EditableLayout.number
        return "x \(n(rect.x))  y \(n(rect.y))  w \(n(rect.w))  h \(n(rect.h))"
    }

    /// One grid step in each direction. Nudging translates rather than
    /// snapping each item on its own, so a selected group keeps its shape
    /// even if the file it came from was never on the grid.
    private func nudge(_ sx: Double, _ sy: Double, _ landscape: Bool) {
        let step = EditCanvas.step
        mutate(landscape: landscape) { item in
            item.frame = item.frame.offset(dx: sx * step, dy: sy * step)
            item.extended = item.extended.offset(dx: sx * step, dy: sy * step)
        }
    }

    /// Grows or shrinks about each item's own centre. The step is in points
    /// rather than normalised units on purpose: x and y are normalised
    /// against different pixel dimensions, so a single normalised delta would
    /// squash a round button into an oval.
    private func resize(points: Double, landscape: Bool, padSize: CGSize) {
        let dw = points / Double(padSize.width)
        let dh = points / Double(padSize.height)
        let floorW = EditCanvas.step * 2
        mutate(landscape: landscape) { item in
            let pad = item.padding
            let f = item.frame
            let w = max(f.w + dw, floorW)
            let h = max(f.h + dh, floorW)
            item.frame = EditRect(x: f.midX - w / 2, y: f.midY - h / 2, w: w, h: h)
            item.applyPadding(pad)
        }
    }

    /// Widens or tightens the hit frame around the drawn one, on all sides.
    private func repad(points: Double, landscape: Bool, padSize: CGSize) {
        let dx = points / Double(padSize.width)
        let dy = points / Double(padSize.height)
        mutate(landscape: landscape) { item in
            let pad = item.padding
            item.applyPadding((
                left: max(pad.left + dx, 0), top: max(pad.top + dy, 0),
                right: max(pad.right + dx, 0), bottom: max(pad.bottom + dy, 0)
            ))
        }
    }

    private func mutate(landscape: Bool, _ transform: (inout EditableItem) -> Void) {
        var items = landscape ? (layout.landscapeItems ?? []) : layout.items
        for index in items.indices where selection.contains(items[index].id) {
            transform(&items[index])
        }
        if landscape { layout.landscapeItems = items } else { layout.items = items }
        commit()
    }

    /// Rounds every value in the file onto the grid. Mostly cosmetic, except
    /// where an earlier programmatic pass left float drift behind: psx.json
    /// carries `0.020000000000000004` for what was meant to be 0.02.
    private func tidy() {
        func clean(_ items: [EditableItem]) -> [EditableItem] {
            items.map { item in
                var copy = item
                copy.frame = EditRect(
                    x: EditCanvas.snap(item.frame.x), y: EditCanvas.snap(item.frame.y),
                    w: EditCanvas.snap(item.frame.w), h: EditCanvas.snap(item.frame.h)
                )
                copy.extended = EditRect(
                    x: EditCanvas.snap(item.extended.x), y: EditCanvas.snap(item.extended.y),
                    w: EditCanvas.snap(item.extended.w), h: EditCanvas.snap(item.extended.h)
                )
                return copy
            }
        }
        layout.items = clean(layout.items)
        if let wide = layout.landscapeItems { layout.landscapeItems = clean(wide) }
        commit()
        flash("Snapped to the grid")
    }

    private func seedLandscape() {
        layout.landscapeItems = layout.items
        commit()
        flash("Landscape set seeded from portrait")
    }

    /// A controller-only set, rebuilt at companion scale rather than
    /// copied. A copy would reproduce exactly the problem this mode
    /// exists to solve: the landscape sets are authored to sit in the
    /// gutters around a centred game, so on a panel with no game they
    /// use 13 to 21 per cent of the screen and their buttons are a
    /// quarter to a sixth of the area of the hand-tuned arcade
    /// companion's (measured across every layout, 2026-08-23).
    ///
    /// The proportions come from that arcade companion, which is the
    /// one companion arrangement already proven by a day of real
    /// hands: movement on the left at roughly a third of the width and
    /// most of the height, actions on the right in a grid, service
    /// pills along the top out of both thumbs' way.
    ///
    /// What it keeps from the existing layout is everything that
    /// carries meaning: every item, its kind, its label, its inputs,
    /// and which SIDE the author put it on, so N64's C cluster stays
    /// right and does not migrate to the left with the d-pad.
    /// Positions are a starting point to be moved by thumb, not an
    /// answer.
    private func seedCompanion() {
        let source = layout.landscapeItems ?? layout.items
        guard !source.isEmpty else { return }

        func placed(_ item: EditableItem, _ r: EditRect, pad: Double = 0.02) -> EditableItem {
            var copy = item
            copy.frame = r
            copy.extended = EditRect(
                x: r.x - pad, y: r.y - pad, w: r.w + pad * 2, h: r.h + pad * 2)
            return copy
        }

        let pills = source.filter { $0.kind == .pill }
        let rest = source.filter { $0.kind != .pill }
        let left = rest.filter { $0.frame.x + $0.frame.w / 2 < 0.5 }
        let right = rest.filter { $0.frame.x + $0.frame.w / 2 >= 0.5 }
        var out: [EditableItem] = []

        // Service pills along the top: the first half from the left
        // edge, the rest to the right, leaving the middle clear.
        let pillW = 0.11, pillH = 0.10, pillY = 0.04
        let leftCount = (pills.count + 1) / 2
        for (i, pill) in pills.enumerated() {
            let x = i < leftCount
                ? 0.03 + Double(i) * (pillW + 0.02)
                : 0.97 - pillW - Double(pills.count - 1 - i) * (pillW + 0.02)
            out.append(placed(pill, EditRect(x: x, y: pillY, w: pillW, h: pillH), pad: 0.015))
        }

        // The left column: movement, at companion scale. Two of them
        // (a stick above a d-pad, as N64 has) share the height.
        let colTop = 0.24, colH = 0.60, colW = 0.30
        for (i, item) in left.enumerated() {
            let each = left.count > 1 ? (colH - 0.04) / Double(left.count) : colH
            let y = colTop + Double(i) * (each + 0.04)
            out.append(placed(item, EditRect(x: 0.05, y: y, w: colW, h: each)))
        }

        // The right side: anything that is not a button (an N64 C
        // cluster) takes a block low on the right where a thumb rests,
        // and the buttons fill the space above it in a two-column grid.
        let blocks = right.filter { $0.kind != .button }
        let buttons = right.filter { $0.kind == .button }
        var buttonsBottom = 0.90
        for (i, block) in blocks.enumerated() {
            let h = 0.26
            let y = 0.90 - h - Double(i) * (h + 0.03)
            out.append(placed(block, EditRect(x: 0.63, y: y, w: 0.30, h: h)))
            buttonsBottom = min(buttonsBottom, y - 0.03)
        }
        if !buttons.isEmpty {
            let columns = buttons.count == 1 ? 1 : 2
            let rows = (buttons.count + columns - 1) / columns
            let w = buttons.count == 1 ? 0.20 : 0.15
            let top = 0.22
            let available = max(buttonsBottom - top, 0.2)
            let h = min((available - Double(rows - 1) * 0.03) / Double(rows), 0.30)
            for (i, button) in buttons.enumerated() {
                let row = i / columns, column = i % columns
                let x = 0.96 - Double(columns - column) * (w + 0.03)
                let y = top + Double(row) * (h + 0.03)
                out.append(placed(button, EditRect(x: x, y: y, w: w, h: h)))
            }
        }

        layout.companionItems = out
        commit()
        flash("Controller-only set seeded at panel scale")
    }

    private func revert() {
        guard let bundled = EditableLayout.loadBundled(layout.name) else { return }
        WorkingCopy.discard(layout.name)
        layout = bundled
        selection.removeAll()
        flash("Reverted to the bundled file")
    }

    private func commit() {
        WorkingCopy.save(layout)
    }

    private func close() {
        commit()
        dismiss()
    }

    // MARK: Getting the file out

    /// Neither of these touches the working copy on disk: both already read
    /// straight from `layout` in memory, so writing one first would only
    /// leave behind a working copy that looks like a real edit when nothing
    /// was actually changed, which is exactly the false signal that makes a
    /// working copy untrustworthy to read later.
    private func exportFile() {
        guard let url = WorkingCopy.exportFile(layout) else { return }
        share = ShareItem(url: url)
    }

    private func copyJSON() {
        UIPasteboard.general.string = layout.jsonText()
        flash("JSON copied")
    }

    private func flash(_ message: String) {
        note = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if note == message { note = nil }
        }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system share sheet, which is how an edited file gets to the Mac:
/// AirDrop it, or save it to Files. Universal Clipboard covers the other
/// route, since "Copy JSON" lands straight in a paste on the Mac.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
