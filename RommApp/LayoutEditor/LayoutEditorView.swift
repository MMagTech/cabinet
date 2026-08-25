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
    /// The layout exactly as it was when this screen opened. Closing
    /// used to save a working copy UNCONDITIONALLY, so merely LOOKING at
    /// a layout forked a private snapshot of it, and that snapshot then
    /// shadowed every newer bundled version forever. Fifty-two arcade
    /// screens were shadowed that way by one browsing session, and each
    /// looked stale with nothing anywhere saying why. Marcus, 2026-08-25:
    /// "something isn't right with the app that I keep getting confused."
    /// He was right. Now a working copy is written only when the layout
    /// actually changed.
    @State private var opened: String = ""
    /// A working copy from an earlier session is hiding a newer bundled
    /// layout underneath this screen. Offer the way out, visibly, instead
    /// of leaving it to a menu item nobody knows to look for.
    @State private var shadowingNewer = false
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
    /// Which candidate ground is being previewed behind a
    /// controller-only pad. Preview only: whichever survives real
    /// hands moves into the app and the rest are deleted.
    @State private var ground: PanelGroundStyle = .pools

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
                        // to get away from. It gets a ground instead.
                        if editingCompanion {
                            PanelGround(system: layout.system, style: ground)
                        } else {
                            ScreenBackdrop(layout: layout.name)
                        }
                        EditorGrid(area: CGRect(origin: .zero, size: geo.size))
                        // DS holds the game's touch screen on the phone,
                        // so its controls have to be arranged around it.
                        if editingCompanion, layout.system == "nds" {
                            DSScreenGuide(area: CGRect(origin: .zero, size: geo.size))
                        }
                        pad(size: padSize, landscape: true)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ZStack(alignment: .top) {
                        ScreenBackdrop(layout: layout.name)
                            .frame(height: max(geo.size.height - Self.stripHeight, 0))
                        // Portrait layouts are normalised against the
                        // strip, not the screen, so the grid measures
                        // the strip or it measures nothing useful.
                        EditorGrid(area: CGRect(
                            x: 0, y: geo.size.height - padPortraitHeight,
                            width: geo.size.width, height: padPortraitHeight))
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
        .onAppear {
            ready = WorkingCopy.isReady(layout.name)
            detectShadow()
        }
        .sheet(item: $share) { item in
            ActivityView(url: item.url)
        }
        .safeAreaInset(edge: .top) {
            if shadowingNewer {
                shadowBanner
            }
        }
    }

    /// The way out of a stale shadow, in your face rather than in a menu.
    /// "Keep my copy" dismisses for this visit only: the copy stays, and
    /// so does the fact it is hiding something, so the banner returns
    /// next time until one side actually wins.
    private var shadowBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("An older saved copy is hiding a newer layout.")
                .font(.footnote)
                .foregroundStyle(.white)
            Spacer()
            Button("Use newest") {
                if let bundled = EditableLayout.loadBundled(layout.name) {
                    WorkingCopy.discard(layout.name)
                    layout = bundled
                    selection.removeAll()
                    ready = false
                    detectShadow()
                    flash("Now on the newest layout")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Keep my copy") {
                shadowingNewer = false
            }
            .controlSize(.small)
            .tint(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.82))
    }

    // MARK: The pad, and the layer that edits it

    private func pad(size: CGSize, landscape: Bool) -> some View {
        let binding = itemsBinding(landscape: landscape)
        return ZStack {
            TouchControlPad(
                items: binding.wrappedValue.map(\.rendered),
                send: { _, _ in },
                system: layout.system,
                // Moulded wherever the app moulds: the controller-only
                // panel, and portrait, whose controls sit on a black
                // strip below the picture rather than over it. Flat in
                // landscape-with-picture, matching the app exactly, so
                // the editor never flatters a layout the player will
                // draw differently.
                material: editingCompanion || !landscape
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

            // Preview grounds, companion only: the arrangement that
            // has no picture is the only one with a ground to judge.
            if landscape && editingCompanion {
                Menu {
                    Picker("", selection: $ground) {
                        ForEach(PanelGroundStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                } label: {
                    Image(systemName: "paintpalette")
                }
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
                if selection.count > 1 {
                    Button("Even up the selection", systemImage: "align.horizontal.center") {
                        evenUpSelection()
                    }
                }
                if layout.landscapeItems == nil {
                    Button("Create landscape set from portrait", systemImage: "rectangle.landscape.rotate") {
                        seedLandscape()
                    }
                }
                // Re-seeding was only ever reachable through the empty
                // state, so once a controller-only set existed there was
                // NO path back to the landscape layout at all. Change
                // something in landscape, switch to controller-only, and
                // the change simply was not there, with nothing in the
                // interface to say why or what to do about it. Reported
                // by Marcus 2026-08-24: "if in normal editor I edit
                // something and then jump to the companion it doesn't go
                // over."
                //
                // The two sets staying independent is deliberate and
                // stays that way, since the whole point is moving a
                // button on one without disturbing the other. What was
                // missing is the deliberate act of pulling the landscape
                // work across when that IS what you want. Destructive
                // because it replaces the controller-only set outright,
                // and marked as such so it reads that way in the menu.
                if editingCompanion, layout.companionItems != nil {
                    Button("Re-seed controller-only from landscape",
                           systemImage: "arrow.triangle.2.circlepath", role: .destructive) {
                        seedCompanion()
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

    /// A controller-only set: the SAME controls, moved to where thumbs
    /// actually rest once no picture is in the way.
    ///
    /// The first version of this scaled everything up, taking its
    /// proportions from the arcade companion. Marcus played it and
    /// said the d-pad had too much travel between presses, and the
    /// measurements agreed with him: that arcade d-pad is 50mm across
    /// where a real one is about 25, while the authored landscape
    /// d-pads are already 28mm and the buttons 10 to 12mm against a
    /// real button's 10. They were never too small. An arcade STICK is
    /// gripped by a whole hand so big is right; a d-pad is a thumb
    /// pivot with a correct size, and past it bigger is strictly
    /// worse, because the thumb has to lift and reposition instead of
    /// roll.
    ///
    /// So this preserves every size and every RELATIVE position: a
    /// face-button diamond stays a diamond, N64's C cluster stays
    /// beside its buttons, a stick stacked over a d-pad stays stacked.
    /// Each side moves as one piece, off the bezel it was pinned
    /// against and into the lower band where a thumb sits. Buttons get
    /// one modest step up, since a cluster is tapped rather than
    /// pivoted on and a little more room between them costs nothing.
    private func seedCompanion() {
        let source = layout.landscapeItems ?? layout.items
        guard !source.isEmpty else { return }

        /// Moves a whole group as one piece, optionally growing it
        /// about its own centre, so nothing inside it rearranges.
        /// Everything below the service pills is the playing area.
        let pillBand = 0.16

        func moved(
            _ group: [EditableItem], scale requested: Double,
            leftEdge: Double?, rightEdge: Double?, centreY: Double
        ) -> [EditableItem] {
            guard !group.isEmpty else { return [] }
            let minX = group.map(\.frame.x).min()!
            let maxX = group.map { $0.frame.x + $0.frame.w }.max()!
            let minY = group.map(\.frame.y).min()!
            let maxY = group.map { $0.frame.y + $0.frame.h }.max()!
            let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
            // Never grow a group past the room below the pill row.
            // N64's right side runs from Z at the top to the C cluster
            // at the bottom, and a flat 15% pushed Z up underneath the
            // pills, seeding a collision the editor would then warn
            // about. A group that tall simply does not get the nudge.
            let band = 0.97 - pillBand
            let fit = (maxY - minY) > 0 ? band / (maxY - minY) : requested
            let scale = min(requested, fit)
            let width = (maxX - minX) * scale, height = (maxY - minY) * scale
            let targetX = leftEdge ?? ((rightEdge ?? 0.94) - width)
            let targetY = min(max(centreY - height / 2, pillBand), 0.97 - height)
            return group.map { item in
                var copy = item
                let w = item.frame.w * scale, h = item.frame.h * scale
                // Position within the group, scaled about its centre,
                // then the whole group placed at its target.
                let ox = (item.frame.x - cx) * scale + width / 2
                let oy = (item.frame.y - cy) * scale + height / 2
                let r = EditRect(x: targetX + ox, y: targetY + oy, w: w, h: h)
                copy.frame = r
                let pad = 0.02
                copy.extended = EditRect(
                    x: r.x - pad, y: r.y - pad, w: r.w + pad * 2, h: r.h + pad * 2)
                return copy
            }
        }

        let pills = source.filter { $0.kind == .pill }
        let rest = source.filter { $0.kind != .pill }
        let left = rest.filter { $0.frame.x + $0.frame.w / 2 < 0.5 }
        let right = rest.filter { $0.frame.x + $0.frame.w / 2 >= 0.5 }
        var out: [EditableItem] = []

        // Service pills lay out as ONE row across the top edge: the
        // left group packed from the left corner, the right group from
        // the right corner, and Menu centred between them.
        //
        // This is the companion panel, not the television's overlay.
        // There is no picture to keep clear of and the top edge is one
        // long uninterrupted strip, so the stacking the television
        // layout uses to stay out of the screen's way buys nothing
        // here and only pushes pills down into the thumbs. Marcus,
        // reviewing SNES: "l on the left with select next to it and r
        // on the right with start next to it with menu in the top
        // middle."
        //
        // Within a side the television's own reading order is kept,
        // top row first, so the pill that sits outermost is the one
        // that sat highest: L then Select going inward on the left, R
        // then Start going inward on the right. That is the second
        // half of the same instruction, and it is what stops this
        // being an arbitrary shuffle.
        //
        // Menu is not a game input, it is the panel's own control, so
        // it is pulled out before the sides are divided (it cannot
        // skew which group a real pill joins) and centred every time,
        // rather than landing wherever the television happened to park
        // it. It is then the one control in the same place on every
        // machine.
        let pillGap = 0.012
        let menuPills = pills.filter { $0.label == "Menu" }
        let sidePills = pills.filter { $0.label != "Menu" }
        let topY = pills.map(\.frame.y).min() ?? 0.04

        func place(_ item: EditableItem, x: Double) -> EditableItem {
            var copy = item
            let r = EditRect(x: x, y: topY, w: item.frame.w, h: item.frame.h)
            copy.frame = r
            copy.extended = EditRect(
                x: r.x - 0.015, y: r.y - 0.015, w: r.w + 0.03, h: r.h + 0.03)
            return copy
        }

        // Reading order on the television: highest row first, then
        // left to right within a row.
        // Outermost first on BOTH sides: highest row first, then
        // nearest that side's own edge. Sorting the right-hand group by
        // ascending x sends the innermost button to the corner, which
        // is how Start ended up outside R.
        var leftPills = sidePills.filter { $0.frame.x + $0.frame.w / 2 < 0.5 }
        var rightPills = sidePills.filter { $0.frame.x + $0.frame.w / 2 >= 0.5 }
        leftPills.sort { $0.frame.y == $1.frame.y ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }
        rightPills.sort { $0.frame.y == $1.frame.y ? $0.frame.x > $1.frame.x : $0.frame.y < $1.frame.y }

        // Menu takes the LEFT CORNER, unless a shoulder already owns
        // it. It is the one control that is not part of the game, so it
        // belongs in the same place on every machine; L and R simply
        // have a stronger claim to a corner than it does, and only
        // there does it take the centre instead. Two earlier versions
        // of this, "always centred" and "always left", each produced
        // something Marcus had to correct, because neither is the rule.
        // The corner is.
        let shoulders: Set<String> = ["L", "R", "L1", "L2", "R1", "R2"]
        let hasShoulders = !shoulders.isDisjoint(with: Set(pills.compactMap(\.label)))
        if !hasShoulders, let menu = menuPills.first, !sidePills.isEmpty {
            out.append(place(menu, x: 0.03))
            // The rest keep their order and pack to the right corner,
            // so the last of them lands in it.
            var x = 0.97
            for pill in sidePills.sorted(by: { $0.frame.x > $1.frame.x }) {
                x -= pill.frame.w
                out.append(place(pill, x: x))
                x -= pillGap
            }
        } else {
            for menu in menuPills {
                out.append(place(menu, x: 0.5 - menu.frame.w / 2))
            }
            var cursor = 0.04
            for pill in leftPills {
                out.append(place(pill, x: cursor))
                cursor += pill.frame.w + pillGap
            }
            cursor = 0.96
            for pill in rightPills {
                cursor -= pill.frame.w
                out.append(place(pill, x: cursor))
                cursor -= pillGap
            }
        }

        // Movement: same size, off the left bezel, sitting in the
        // lower band rather than pinned to an edge.
        out += moved(left, scale: 1.0, leftEdge: 0.07, rightEdge: nil, centreY: 0.60)
        // Actions: one modest step up, mirrored on the right, then the
        // cluster pulled back in to the spacing the PORTRAIT layout
        // uses.
        //
        // Growing the group by 1.15 grows the gaps by 1.15 too, and the
        // television's landscape layout is already the loosest of the
        // three because it has a picture to sit under. Seeding from it
        // and then scaling up compounds both, which is how NES ended up
        // with A and B a thumb-roll apart. Marcus: "buttons are to far
        // apart should be closer like on portrait."
        //
        // Measured in units of the buttons' OWN size rather than in
        // layout units, because x and y normalise against different
        // lengths and a gap that reads as equal in the numbers is not
        // equal on glass. Only ever tightens: a cluster already at or
        // inside portrait's spacing is left alone, since the complaint
        // is always about reaching too far, never too little.
        var actions = moved(right, scale: 1.15, leftEdge: nil, rightEdge: 0.93, centreY: 0.60)
        actions = tightenedToPortrait(actions)
        out += actions

        layout.companionItems = out
        commit()
        flash("Controller-only set seeded: same sizes, thumb placement")
    }

    /// Pulls a seeded action cluster in until it is spaced like the
    /// portrait layout's, which is the one authored for a thumb rather
    /// than for sitting under a picture. See the call site.
    private func tightenedToPortrait(_ group: [EditableItem]) -> [EditableItem] {
        let buttons = group.filter { $0.kind == .button }
        let reference = layout.items.filter { $0.kind == .button }
        guard buttons.count > 1, reference.count > 1 else { return group }

        func spread(_ items: [EditableItem]) -> (Double, Double) {
            let w = items.map(\.frame.w).reduce(0, +) / Double(items.count)
            let h = items.map(\.frame.h).reduce(0, +) / Double(items.count)
            let cx = items.map { $0.frame.x + $0.frame.w / 2 }
            let cy = items.map { $0.frame.y + $0.frame.h / 2 }
            let dx = (cx.max()! - cx.min()!) / max(w, 0.0001)
            let dy = (cy.max()! - cy.min()!) / max(h, 0.0001)
            return (dx, dy)
        }
        let want = spread(reference), have = spread(buttons)
        let fx = (have.0 > 0.01 && want.0 > 0.01 && have.0 / want.0 > 1.15) ? want.0 / have.0 : 1.0
        let fy = (have.1 > 0.01 && want.1 > 0.01 && have.1 / want.1 > 1.15) ? want.1 / have.1 : 1.0
        guard fx < 1.0 || fy < 1.0 else { return group }

        let ccx = buttons.map { $0.frame.x + $0.frame.w / 2 }.reduce(0, +) / Double(buttons.count)
        let ccy = buttons.map { $0.frame.y + $0.frame.h / 2 }.reduce(0, +) / Double(buttons.count)
        return group.map { item in
            guard item.kind == .button else { return item }
            var copy = item
            let padX = item.extended.x - item.frame.x, padY = item.extended.y - item.frame.y
            let cx = ccx + (item.frame.x + item.frame.w / 2 - ccx) * fx
            let cy = ccy + (item.frame.y + item.frame.h / 2 - ccy) * fy
            copy.frame = EditRect(
                x: cx - item.frame.w / 2, y: cy - item.frame.h / 2,
                w: item.frame.w, h: item.frame.h)
            copy.extended = EditRect(
                x: copy.frame.x + padX, y: copy.frame.y + padY,
                w: item.extended.w, h: item.extended.h)
            return copy
        }
    }

    /// Makes a selection symmetric about its own centre.
    ///
    /// Built for a real defect Marcus felt before anyone measured it:
    /// every landscape face-button diamond in the library is off, the
    /// left button sitting 0.005 closer to centre than the right and
    /// the top and bottom pair nudged 0.0025 across. The same error in
    /// PlayStation, SNES and DS, so one hand made it once and it was
    /// copied. About four points on screen, which survives review and
    /// still reads as wrong in the hand.
    ///
    /// Each item is mirrored onto the partner opposite it, and the two
    /// are averaged, so the cluster keeps its size and its position and
    /// only its evenness changes. An item with no partner across the
    /// centre (an odd one out, a lone Z) is left exactly where it is
    /// rather than dragged onto an axis it never belonged to.
    private func evenUpSelection() {
        let binding = itemsBinding(landscape: currentIsLandscape)
        var items = binding.wrappedValue
        let picked = items.indices.filter { selection.contains(items[$0].id) }
        guard picked.count > 1 else { return }

        func centre(_ i: Int) -> CGPoint {
            CGPoint(x: items[i].frame.x + items[i].frame.w / 2,
                    y: items[i].frame.y + items[i].frame.h / 2)
        }
        let cx = picked.map { centre($0).x }.reduce(0, +) / Double(picked.count)
        let cy = picked.map { centre($0).y }.reduce(0, +) / Double(picked.count)

        var moved = 0
        for i in picked {
            let c = centre(i)
            // The partner is whichever selected item sits closest to
            // this one's mirror image through the cluster centre.
            let mirror = CGPoint(x: 2 * cx - c.x, y: 2 * cy - c.y)
            let partner = picked
                .filter { $0 != i }
                .min { a, b in
                    hypot(centre(a).x - mirror.x, centre(a).y - mirror.y)
                        < hypot(centre(b).x - mirror.x, centre(b).y - mirror.y)
                }
            guard let partner,
                  hypot(centre(partner).x - mirror.x, centre(partner).y - mirror.y) < 0.08
            else { continue }
            // Average this item with its partner's mirror, so neither
            // one wins and the cluster does not drift.
            let target = CGPoint(
                x: (c.x + (2 * cx - centre(partner).x)) / 2,
                y: (c.y + (2 * cy - centre(partner).y)) / 2)
            let dx = target.x - c.x, dy = target.y - c.y
            if abs(dx) > 0.0001 || abs(dy) > 0.0001 { moved += 1 }
            items[i].frame = EditRect(
                x: items[i].frame.x + dx, y: items[i].frame.y + dy,
                w: items[i].frame.w, h: items[i].frame.h)
            items[i].extended = EditRect(
                x: items[i].extended.x + dx, y: items[i].extended.y + dy,
                w: items[i].extended.w, h: items[i].extended.h)
        }
        binding.wrappedValue = items
        commit()
        flash(moved == 0 ? "Already even" : "Evened \(moved)")
    }

    /// Which set the toolbar actions apply to, matching what is drawn.
    private var currentIsLandscape: Bool {
        UIDevice.current.orientation.isLandscape
            || (UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }.first?
                .interfaceOrientation.isLandscape ?? false)
    }

    private func revert() {
        guard let bundled = EditableLayout.loadBundled(layout.name) else { return }
        WorkingCopy.discard(layout.name)
        layout = bundled
        selection.removeAll()
        flash("Reverted to the bundled file")
    }

    private func commit() {
        // Only a real edit earns a working copy; see `opened`.
        guard layout.jsonText() != opened else { return }
        WorkingCopy.save(layout)
    }

    private func close() {
        commit()
        dismiss()
    }

    private func detectShadow() {
        opened = layout.jsonText()
        guard WorkingCopy.isEdited(layout.name),
              !WorkingCopy.isReady(layout.name),
              let bundled = EditableLayout.loadBundled(layout.name)
        else { shadowingNewer = false; return }
        shadowingNewer = bundled.jsonText() != opened
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
