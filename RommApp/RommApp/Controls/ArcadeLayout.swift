import Foundation

/// Builds a control layout from an arcade profile at runtime.
///
/// Arcade layouts are per game, not per system, so they cannot be bundled
/// files like console layouts. The profile says how many buttons and what
/// kind of stick; this arranges them. Button labels are generic numbers for
/// v0.1, per the scope doc: labels are cosmetic, the index to core input
/// mapping is what matters.
///
/// RetroPad ids per position, matching FBNeo's conventions:
/// - Up to four buttons run B, A, Y, X (0, 8, 1, 9), which on Neo Geo is
///   exactly A, B, C, D.
/// - Five and six button games get two rows of three, punches over kicks:
///   Y, X, L over B, A, R (1, 9, 10 over 0, 8, 11), the CPS fighter order.
/// - Coin is Select (2) and Start is Start (3) on every arcade core.
///
/// Coin is a primary control, not a small central pill. People feed arcade
/// machines coins constantly.
enum ArcadeLayout {
    /// `analog` is what the game's own driver says it wants
    /// (analog-controls.json); passed only by the native player when the
    /// running core's mouse channel is actually wired, so the webview
    /// player keeps its d-pad and nothing changes for it.
    static func build(for profile: ArcadeProfile, analog: AnalogControls? = nil) -> ControlLayout {
        // Arcade accurate: the panel the player stood at. The driver
        // data says which analog controls the cabinet had; the profile
        // says whether a joystick was there too. Between them every
        // shape in the library is one of a dozen panels.
        if let analog, let panel = panel(for: profile, analog: analog) {
            return panel
        }
        return buildStandard(for: profile)
    }

    /// The same cabinet, drawn for a phone that IS the panel.
    ///
    /// Every layout above shares its screen with the picture: portrait
    /// items are normalised against a bottom strip, landscape items hug
    /// the gutters beside a centred canvas. A phone driving a television
    /// has no picture, and reusing those layouts stretched a 330 point
    /// strip over a whole screen: a tiny trackball in a corner of a black
    /// expanse, pill text taller than the pill. Marcus saw it on the
    /// first live run and called it horrible, correctly.
    ///
    /// So the companion arrangement is its own geometry with one idea:
    /// the mechanism is the point, so give it the space a cabinet gave
    /// it. The analog control gets the left half at full height under
    /// the resting thumb, buttons get the right at sizes a thumb cannot
    /// miss, and the coin/start/menu row keeps the top. Ids and
    /// sensitivities are identical to the local panels, so the wire and
    /// the game cannot tell which layout produced a press.
    static func companion(for profile: ArcadeProfile, analog: AnalogControls?) -> ControlLayout {
        let analog = analog ?? AnalogControls()
        // A hand-tuned companion set wins, the same way it does for a
        // console. Every non-arcade platform has read its companionItems
        // from the layout file since companion panels existed; arcade was
        // the one family that always rebuilt them here and threw the
        // tuning away. Falls through to the generated panel when a file
        // has no companion set, which is every file until one is authored,
        // so this changes nothing on its own.
        let tunedName = tunedPanelName(for: profile, analog: analog)
            ?? tunedStickName(for: profile)
        if let file = loadLayout(named: tunedName),
           let companion = file.companionItems, !companion.isEmpty {
            return ControlLayout(
                system: file.system, items: companion, landscapeItems: companion,
                companionItems: companion, headroom: file.headroom)
        }
        var kinds: [ControlLayout.Item.Kind] = []
        if (analog.rotary ?? 0) > 0 { kinds.append(.rotary) }
        if (analog.trackball ?? 0) > 0 { kinds.append(.trackball) }
        if (analog.dial ?? 0) > 0 || (analog.paddle ?? 0) > 0 { kinds.append(.spinner) }
        let gun = (analog.lightgun ?? 0) > 0
        let pedals = min(analog.pedals ?? 0, 2)
        let hasStick: Bool = {
            if let stated = analog.joystick { return stated != 0 }
            if (analog.trackball ?? 0) > 0 { return false }
            if kinds.contains(.rotary) { return false }
            return profile.profile != "special"
        }()
        let buttons = max(0, min(profile.buttons, 6))

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, pad: Double = 0.02) -> (ControlLayout.Rect, ControlLayout.Rect) {
            (ControlLayout.Rect(x: x, y: y, w: w, h: h),
             ControlLayout.Rect(x: x - pad, y: y - pad, w: w + pad * 2, h: h + pad * 2))
        }

        // One builder for both orientations: the shapes are the same,
        // only the axis that has room to spare differs.
        func build(landscape: Bool) -> [ControlLayout.Item] {
            var items: [ControlLayout.Item] = []

            // The service row. Small on purpose: pressed a few times a
            // session, and the game controls own everything below it.
            let pillH = landscape ? 0.12 : 0.055
            let pillY = landscape ? 0.04 : 0.045
            for (label, input, x, w) in [
                ("Coin", RetroPad.select, 0.03, 0.11),
                ("Menu", RetroPad.overlay, 0.17, 0.13),
                ("Start", RetroPad.start, landscape ? 0.84 : 0.72, 0.13),
            ] {
                let (f, e) = rect(x, pillY, w, pillH)
                items.append(ControlLayout.Item(
                    kind: .pill, label: label, input: input, inputs: nil,
                    frame: f, extended: e, fourWay: nil))
            }

            // A gun panel is the exception to everything: the surface is
            // the whole screen, buttons ride the bottom corners where
            // thumbs already are while hands aim.
            if gun {
                items.append(ControlLayout.Item(
                    kind: .gun, label: nil, input: nil, inputs: nil,
                    frame: ControlLayout.Rect(x: 0, y: 0, w: 1, h: 1),
                    extended: ControlLayout.Rect(x: 0, y: 0, w: 1, h: 1),
                    fourWay: nil, sensitivity: nil))
                let ids = [RetroPad.b, RetroPad.a, RetroPad.y]
                for index in 0..<min(buttons, 3) {
                    let w = landscape ? 0.10 : 0.20
                    let h = landscape ? 0.20 : 0.10
                    let x = index == 0 ? 0.03 : (1.0 - w - 0.03 - Double(index - 1) * (w + 0.02))
                    let (f, e) = rect(x, 1.0 - h - 0.04, w, h)
                    items.append(ControlLayout.Item(
                        kind: .button, label: "\(index + 1)", input: ids[index], inputs: nil,
                        frame: f, extended: e, fourWay: nil))
                }
                return items
            }

            // The left column: the movement control, at cabinet scale.
            // Stick and analog both there when the machine had both,
            // stacked; alone, whichever exists takes the full height.
            // Landscape: mechanism left, buttons right, side by side.
            // Portrait: mechanism top, buttons below, stacked. The first
            // draft used the landscape split in both and the geometry
            // check caught the mechanism drawn through button one in
            // every portrait dial shape.
            let top = landscape ? 0.22 : 0.155
            let mechanism = kinds.first
            // Pedals narrow the left column: they take the right edge
            // and push the button block toward the middle, and the
            // mechanism must not be under that block.
            let leftW = landscape ? (pedals > 0 ? 0.32 : 0.42) : 0.60
            if let mechanism, hasStick {
                let (sf, se) = rect(0.04, top, landscape ? leftW * 0.55 : 0.44, landscape ? 0.44 : 0.20)
                items.append(ControlLayout.Item(
                    kind: .dpad, label: nil, input: nil, inputs: [4, 5, 6, 7],
                    frame: sf, extended: se, fourWay: profile.isFourWay))
                let (af, ae) = rect(0.04, top + (landscape ? 0.50 : 0.23), landscape ? leftW * 0.55 : 0.44, landscape ? 0.28 : 0.14)
                items.append(ControlLayout.Item(
                    kind: mechanism, label: nil, input: nil, inputs: nil,
                    frame: af, extended: ae, fourWay: nil,
                    sensitivity: mechanism == .spinner ? 768 : 300))
            } else if let mechanism {
                // The mechanism alone, as large as the screen allows. A
                // rotary ring carries the direction ids for the tilt to
                // assert, same as the local panel.
                let h = landscape ? 0.68 : 0.34
                let (f, e) = rect(0.05, top, landscape ? leftW : 0.90, h)
                items.append(ControlLayout.Item(
                    kind: mechanism, label: nil, input: nil,
                    inputs: mechanism == .rotary ? [4, 5, 6, 7] : nil,
                    frame: f, extended: e, fourWay: mechanism == .rotary ? false : nil,
                    sensitivity: mechanism == .spinner ? 768 : (mechanism == .rotary ? 384 : 300)))
            } else if hasStick || pedals > 0 {
                // Plain stick, or a wheel-with-pedals cabinet whose wheel
                // is the phone itself held like one.
                let kind: ControlLayout.Item.Kind = (analog.axis ?? 0) > 0 || pedals > 0 && !hasStick ? .wheel : .dpad
                let h = landscape ? 0.60 : 0.32
                let (f, e) = rect(0.05, top + 0.02, landscape ? leftW * 0.85 : 0.54, h)
                if kind == .dpad {
                    items.append(ControlLayout.Item(
                        kind: .dpad, label: nil, input: nil, inputs: [4, 5, 6, 7],
                        frame: f, extended: e, fourWay: profile.isFourWay))
                } else {
                    items.append(ControlLayout.Item(
                        kind: .wheel, label: nil, input: nil, inputs: nil,
                        frame: f, extended: e, fourWay: nil, sensitivity: 500))
                }
            }

            // Pedals: the right edge, tall, exactly where a resting
            // right thumb sits, same R/L ids the core reads.
            var buttonRight = landscape ? 0.96 : 0.94
            if pedals > 0 {
                // A pedal is held for whole races while the other hand
                // tilts the phone, and tilting is exactly the motion
                // that slides a resting thumb around the glass. So a
                // pedal is the biggest single target on the panel, and
                // its hit frame is padded further than anything else:
                // Marcus's throttle finger slid off the first size mid
                // corner. One pedal takes half the edge; two share it.
                let w = landscape ? 0.14 : 0.18
                let h = landscape ? (pedals == 1 ? 0.52 : 0.36) : 0.17
                for (i, spec) in pedalSpecs(count: pedals).enumerated() {
                    let y = (landscape ? (pedals == 1 ? 0.30 : 0.22) : 0.58) + Double(i) * (h + 0.06)
                    let (f, e) = rect(1.0 - w - 0.02, y, w, h, pad: 0.035)
                    items.append(ControlLayout.Item(
                        kind: .pedal, label: spec.label, input: spec.input, inputs: nil,
                        frame: f, extended: e, fourWay: nil))
                }
                buttonRight -= (w + 0.05)
            }

            // Buttons: the right block, big. One or two get huge single
            // targets; more fall into the two-column grid every arcade
            // player's hand already knows.
            //
            if buttons > 0 {
                let ids = buttons <= 4 ? [RetroPad.b, RetroPad.a, RetroPad.y, RetroPad.x]
                                       : [RetroPad.y, RetroPad.x, RetroPad.b, RetroPad.a, RetroPad.l, RetroPad.r]
                let columns = buttons == 1 ? 1 : 2
                let rows = (buttons + columns - 1) / columns
                // Portrait buttons live below everything the left
                // column drew; landscape beside it.
                let areaTop = landscape ? 0.24 : 0.60
                let areaH = landscape ? 0.68 : 0.36
                let w = landscape ? (buttons == 1 ? 0.20 : 0.15) : (buttons == 1 ? 0.34 : 0.26)
                let h = min((areaH - Double(rows - 1) * 0.04) / Double(rows), landscape ? 0.34 : 0.18)
                for index in 0..<buttons {
                    let row = index / columns
                    let column = index % columns
                    // On a driving cabinet the block anchors to the
                    // WHEEL, not the far edge: the pedal owns that edge
                    // under a holding thumb, and the first anchored-right
                    // attempt left the boost stranded mid-screen, which
                    // is what Marcus actually reported. The wheel ends at
                    // 0.37; buttons start right where it does.
                    let x = (pedals > 0 && landscape)
                        ? 0.42 + Double(column) * (w + 0.06)
                        : buttonRight - Double(columns - column) * (w + 0.03)
                    let y = areaTop + Double(row) * (h + 0.04)
                    let (f, e) = rect(x, y, w, h)
                    items.append(ControlLayout.Item(
                        kind: .button, label: "\(index + 1)", input: ids[index], inputs: nil,
                        frame: f, extended: e, fourWay: nil))
                }
            }
            return items
        }

        return ControlLayout(
            system: "arcade:\(profile.profile):\(buttons)",
            items: build(landscape: false),
            landscapeItems: build(landscape: true),
            // Arcade builds its own companion arrangement in code (see
            // `companion(for:analog:)`), rather than carrying one as
            // data the way the console layouts do.
            companionItems: nil,
            headroom: nil)
    }

    /// Assembles the cabinet's panel: the analog controls the driver
    /// declares, the joystick if the machine had one, and the buttons.
    ///
    /// A tuned file always wins, so the LayoutEditor stays the way these
    /// get made properly; this is what a shape looks like before anyone
    /// has tuned it, which is the same relationship every arcade layout
    /// has always had to its generator.
    /// The file name a hand-tuned panel for this cabinet would live under,
    /// or nil for a cabinet with no analog control at all (those are named
    /// by tunedLayout's stick/twin scheme instead).
    ///
    /// EVERYTHING that moves a control has to be in this name, and that is
    /// the whole lesson of the version this replaces. It named a file by
    /// the control type and the button count only, so one name covered
    /// cabinets with one pedal and cabinets with two. A file cannot be
    /// right for both, which is why the old code refused to load a tuned
    /// panel for any cabinet with pedals at all rather than draw a brake
    /// on the 91 machines that never had one. Refusing was the correct
    /// call given the name; the fix is to make the name complete.
    ///
    /// Naming is here, in one function, called by both the app and the
    /// exporter in tools/lab/arcade. Two copies of this rule would drift,
    /// and a drift means a file that is silently never read: exactly what
    /// happened to the wheel, gun and rotary panels, which sat in the
    /// bundle unreachable because nothing ever resolved their names.
    ///
    /// tools/lab/arcade/panels.sh proves the mapping is one to one over
    /// every romset in the data before it exports anything: two cabinets
    /// that share a name must generate the same panel, or that file is
    /// wrong for one of them. It refuses to write if that fails.
    static func tunedPanelName(for profile: ArcadeProfile, analog: AnalogControls) -> String? {
        let rotary = (analog.rotary ?? 0) > 0
        let gun = (analog.lightgun ?? 0) > 0
        let trackball = (analog.trackball ?? 0) > 0
        let spinner = (analog.dial ?? 0) > 0 || (analog.paddle ?? 0) > 0
        let pedals = min(max(analog.pedals ?? 0, 0), 2)
        guard rotary || gun || trackball || spinner || pedals > 0 else { return nil }

        // A handful of cabinets carried two mechanisms at once, so the
        // stem is a list rather than a choice. Fixed order, so the same
        // panel always spells itself the same way.
        var families: [String] = []
        if rotary { families.append("rotary") }
        if gun { families.append("gun") }
        if trackball { families.append("trackball") }
        if spinner { families.append("spinner") }
        let stem = families.isEmpty ? "pedal" : families.joined(separator: "-")

        var name = "arcade-\(stem)\(max(0, min(profile.buttons, 6)))"
        if pedals > 0 { name += "p\(pedals)" }
        // A joystick beside the mechanism narrows the stick and moves the
        // mechanism into its own lane, so it is a different panel. It only
        // changes anything when there IS a mechanism to sit beside.
        if (trackball || spinner) && joystickPresent(profile: profile, analog: analog) {
            name += "j"
        }
        return name
    }

    /// Did this cabinet have a joystick as well? Extracted so the name and
    /// the layout cannot disagree about it.
    private static func joystickPresent(profile: ArcadeProfile, analog: AnalogControls) -> Bool {
        if let stated = analog.joystick { return stated != 0 }
        if (analog.trackball ?? 0) > 0 { return false }
        return profile.profile != "special"
    }

    private static func panel(for profile: ArcadeProfile, analog: AnalogControls) -> ControlLayout? {
        // A hand-tuned panel wins, and is looked up BEFORE anything else
        // here so that every family reaches it. The rotary branch below
        // returns early and the gun and pedal cases were refused outright,
        // which between them left 21 of the bundle's 35 analog panels
        // unreachable: they could be edited in the LayoutEditor and could
        // never appear in a game.
        if let name = tunedPanelName(for: profile, analog: analog),
           let file = loadLayout(named: name) {
            return file
        }
        // Did this cabinet have a joystick? The profile is a weak
        // answer: it says "special" only when a modern MAME listxml
        // happened to classify the machine that way, which is how
        // Centipede ended up with a d-pad beside its trackball. Nobody
        // chose that. A trackball takes the movement role outright, so a
        // trackball cabinet has no stick unless the curated file says
        // otherwise, and any panel can state the answer directly.
        let hasJoystick = joystickPresent(profile: profile, analog: analog)
        var analogKinds: [ControlLayout.Item.Kind] = []
        // A rotary joystick was one control: the player pushed it and
        // twisted it with the same hand, at the same time. A thumb on
        // glass cannot do both to one spot, and being able to walk one
        // way while firing another IS the game, so the control splits
        // across the two thumbs rather than sitting whole under one.
        // The stick keeps its slot; the twist becomes a ring the right
        // thumb reaches, above the buttons.
        if (analog.rotary ?? 0) > 0 {
            // Same lane discipline as any other analog panel: the ring is
            // a thumb control, so it narrows and the buttons stack in the
            // lane that frees up rather than running under it.
            let base = buildStandard(for: profile, narrowStick: true)
            // The stick's slot becomes the aim ring, and the four
            // direction ids ride along on it for the tilt to assert.
            // Marcus's split, and the better one: aiming is the precise
            // act (twelve exact positions, worth a thumb) while movement
            // is eight coarse directions a tilt covers easily.
            func mark(_ list: [ControlLayout.Item]) -> [ControlLayout.Item] {
                list.map { item in
                    guard item.kind == .dpad else { return item }
                    // The slot, but not the d-pad's reach: inherited, the
                    // ring's hit frame ran under the first action button
                    // and, because analog kinds claim a touch first, that
                    // button stopped firing entirely.
                    let f = item.frame
                    return ControlLayout.Item(
                        kind: .rotary, label: nil, input: nil, inputs: item.inputs,
                        frame: f,
                        extended: ControlLayout.Rect(
                            x: f.x - 0.02, y: f.y - 0.02, w: f.w + 0.04, h: f.h + 0.04),
                        fourWay: false, sensitivity: 384)
                }
            }
            return ControlLayout(
                system: base.system, items: mark(base.items),
                landscapeItems: base.landscapeItems.map(mark),
                companionItems: base.companionItems.map(mark), headroom: base.headroom)
        }
        if (analog.trackball ?? 0) > 0 { analogKinds.append(.trackball) }
        if (analog.dial ?? 0) > 0 || (analog.paddle ?? 0) > 0 { analogKinds.append(.spinner) }
        // An analog stick cabinet gets NO extra control here, and that is
        // a deletion made on evidence rather than taste. These games read
        // RETRO_DEVICE_ANALOG on the left stick (mame2003-plus's
        // osd_analogjoy_read); the wheel this used to add writes relative
        // deltas into the MOUSE channel, which is a different path in the
        // same core (osd_xy_device_read) and one an ad_stick game never
        // calls. So the wheel was drawn, took touches from the buttons
        // beside it, and did nothing, on 229 games. The core also
        // describes plain Up/Down/Left/Right for every one of them, so
        // the d-pad already carries the control.
        //
        // A real analog stick would be better than a d-pad here, and the
        // native path already answers ANALOG_LEFT for every core but
        // FBNeo. That is an input change, so it needs the device pass on
        // a Bluetooth pad the project rules require, and it is not this.
        let gun = (analog.lightgun ?? 0) > 0
        let pedalCount = analog.pedals ?? 0
        let pedals = pedalCount > 0
        // An analog stick is a stick: the existing kind already serves
        // it, and the standard layout already draws one.
        if analogKinds.isEmpty && !gun && !pedals { return nil }

        let besideStick = hasJoystick && !analogKinds.isEmpty
        let base = buildStandard(
            for: profile, pedals: pedalCount, narrowStick: besideStick)
        var items = base.items
        var wide = base.landscapeItems ?? base.items

        // A gun cabinet aims at the picture, so its surface is the whole
        // screen and the panel keeps only its buttons. Landscape only:
        // in portrait the pad occupies a strip and cannot reach the
        // picture, and every gun cabinet was landscape anyway.
        if gun {
            let surface = ControlLayout.Item(
                kind: .gun, label: nil, input: nil, inputs: nil,
                frame: ControlLayout.Rect(x: 0, y: 0, w: 1, h: 1),
                extended: ControlLayout.Rect(x: 0, y: 0, w: 1, h: 1),
                fourWay: nil, sensitivity: nil)
            wide = [surface] + wide.filter { $0.kind != .dpad && $0.kind != .stick }
            // Portrait used to keep a d-pad and get no gun at all, which
            // left the one control the cabinet had missing on half the
            // orientations: you could not aim, only nudge a crosshair
            // with a stick MAME provides for players who own no gun. The
            // player takes the whole screen here too, so the surface
            // reaches the picture, and the buttons drop to a band along
            // the bottom where a thumb can hold them while the other
            // hand aims. Normalised against the full screen, not the
            // strip, which is why these coordinates are not the ones
            // above.
            let count = max(0, min(profile.buttons, 6))
            var portrait: [ControlLayout.Item] = [surface]
            for index in 0..<count {
                let across = min(count, 3)
                let row = index / 3, column = index % 3
                let w = 0.20, gap = (1.0 - Double(across) * w) / Double(across + 1)
                portrait.append(ControlLayout.Item(
                    kind: .button, label: "\(index + 1)",
                    input: [RetroPad.b, RetroPad.a, RetroPad.y, RetroPad.x, RetroPad.l, RetroPad.r][index],
                    inputs: nil,
                    frame: ControlLayout.Rect(
                        x: gap + Double(column) * (w + gap),
                        y: 0.86 - Double(row) * 0.11, w: w, h: 0.075),
                    extended: ControlLayout.Rect(
                        x: gap - 0.02 + Double(column) * (w + gap),
                        y: 0.845 - Double(row) * 0.11, w: w + 0.04, h: 0.105),
                    fourWay: nil, sensitivity: nil))
            }
            portrait += items.filter { $0.kind == .pill || $0.label == "Coin" }.map { item in
                // Coin, Start and Menu ride the very bottom, clear of the
                // picture and of the button band above them.
                let f = item.frame
                let y = 0.955
                return ControlLayout.Item(
                    kind: item.kind, label: item.label, input: item.input, inputs: item.inputs,
                    frame: ControlLayout.Rect(x: f.x, y: y, w: f.w * 0.9, h: 0.038),
                    extended: ControlLayout.Rect(x: f.x - 0.02, y: y - 0.014, w: f.w * 0.9 + 0.04, h: 0.066),
                    fourWay: nil, sensitivity: nil)
            }
            items = portrait
        }

        for (index, kind) in analogKinds.enumerated() {
            let sens: Double = kind == .spinner ? 768 : (kind == .wheel ? 500 : 300)
            if gun {
                // A cabinet that carried a gun AND a mechanism. Two of
                // them exist: Lucky & Wild, where one player steers while
                // another shoots, and Born to Fight. Both lost their
                // mechanism completely until now, because the placement
                // below works by REPLACING the d-pad and the gun branch
                // above has already stripped the d-pad out. Nothing
                // errored; the control simply was not in the file.
                //
                // Aiming owns the screen here, so the mechanism cannot
                // take a lane the way it does on an ordinary panel. It
                // gets the lower left instead, the one corner a gun panel
                // leaves free: the button band is along the bottom, Coin
                // is under it, and a pedal, if the cabinet has one, holds
                // the right edge. Normalised against the whole screen,
                // like everything else on a gun panel.
                let tall = ControlLayout.Item(
                    kind: kind, label: nil, input: nil, inputs: nil,
                    frame: ControlLayout.Rect(
                        x: 0.06 + Double(index) * 0.30, y: 0.70, w: 0.26, h: 0.12),
                    extended: ControlLayout.Rect(
                        x: 0.03 + Double(index) * 0.30, y: 0.68, w: 0.32, h: 0.16),
                    fourWay: nil, sensitivity: sens)
                let flat = ControlLayout.Item(
                    kind: kind, label: nil, input: nil, inputs: nil,
                    frame: ControlLayout.Rect(
                        x: 0.03 + Double(index) * 0.17, y: 0.54, w: 0.14, h: 0.30),
                    extended: ControlLayout.Rect(
                        x: 0.01 + Double(index) * 0.17, y: 0.50, w: 0.18, h: 0.38),
                    fourWay: nil, sensitivity: sens)
                items.append(tall); wide.append(flat)
                continue
            }
            if !hasJoystick && index == 0 {
                // No stick on this panel: the analog control takes its
                // slot and its reach.
                func swap(_ list: [ControlLayout.Item]) -> [ControlLayout.Item] {
                    list.map { item in
                        guard item.kind == .dpad else { return item }
                        // The slot, but not the reach. A d-pad's extended
                        // frame is deliberately enormous so a thumb sliding
                        // off a diagonal still steers; an analog control
                        // inheriting that swallows the first action button,
                        // and because analog kinds claim a touch before
                        // buttons are even considered, the button then does
                        // nothing at all. Measured at 823 square points on
                        // the plain dial panel before this.
                        // On a pedal cabinet the panel has to hold a
                        // wheel, a button arc and a pedal column in one
                        // strip. The wheel gives up the width: it is a
                        // thumb turning a dial, not a trackball being
                        // palmed, so it does not need half the screen and
                        // taking it left no lane for button one.
                        let f = ControlLayout.Rect(
                            x: item.frame.x, y: item.frame.y,
                            w: item.frame.w * 0.72, h: item.frame.h)
                        let pad = 0.02
                        return ControlLayout.Item(
                            kind: kind, label: nil, input: nil, inputs: nil,
                            frame: f,
                            extended: ControlLayout.Rect(
                                x: f.x - pad, y: f.y - pad,
                                w: f.w + pad * 2, h: f.h + pad * 2),
                            fourWay: nil, sensitivity: sens)
                    }
                }
                items = swap(items); wide = swap(wide)
            } else {
                // Beside the stick. "Upper right" used to mean on top of
                // the Menu pill: the pills live in the top band and the
                // control was drawn straight through them, taking 6435
                // square points of touches that were meant for Menu and
                // Start. Since an analog kind claims a touch before the
                // pills are even considered, Menu was not merely covered,
                // it was unreachable. It sits below the pill band now, in
                // its own lane, and takes the outer edge in landscape
                // where the picture leaves a gutter.
                let y = 0.60 - Double(index) * 0.32
                let tall = ControlLayout.Item(
                    kind: kind, label: nil, input: nil, inputs: nil,
                    frame: ControlLayout.Rect(x: 0.38, y: y, w: 0.24, h: 0.28),
                    extended: ControlLayout.Rect(x: 0.36, y: y - 0.02, w: 0.28, h: 0.32),
                    fourWay: nil, sensitivity: sens)
                let flat = ControlLayout.Item(
                    kind: kind, label: nil, input: nil, inputs: nil,
                    frame: ControlLayout.Rect(x: 0.30 + Double(index) * 0.16, y: 0.60, w: 0.13, h: 0.30),
                    extended: ControlLayout.Rect(x: 0.28 + Double(index) * 0.16, y: 0.57, w: 0.17, h: 0.36),
                    fourWay: nil, sensitivity: sens)
                items.append(tall); wide.append(flat)
            }
        }

        // Pedals ride RetroPad R and L, which is where this core puts
        // them: it maps MAME's button 6 to R and button 5 to L and
        // renames them "Pedal" and "Pedal2" when a driver declares them.
        // Guessed ids sent a Super Off Road accelerator to the wrong
        // button entirely. And the count is the driver's: that cabinet
        // has one pedal, so drawing a brake it never had is exactly the
        // invention this rule exists to prevent.
        for (i, spec) in pedalSpecs(count: pedalCount).enumerated() {
            let pedal = ControlLayout.Item(
                kind: .pedal, label: spec.label, input: spec.input, inputs: nil,
                frame: ControlLayout.Rect(x: 0.855, y: 0.40 + Double(i) * 0.27, w: 0.125, h: 0.23),
                extended: ControlLayout.Rect(x: 0.815, y: 0.36 + Double(i) * 0.27, w: 0.185, h: 0.29),
                fourWay: nil, sensitivity: nil)
            items.append(pedal); wide.append(pedal)
        }

        return ControlLayout(
            system: base.system, items: items,
            landscapeItems: wide, companionItems: base.companionItems, headroom: base.headroom)
    }

    /// One pedal is an accelerator and says so; two are gas and brake.
    /// Short labels because a pedal is drawn as a narrow pill and a long
    /// word truncates to initials, which is how "Gas" and "Brake" first
    /// appeared on screen as G and B.
    private static func pedalSpecs(count: Int) -> [(label: String, input: Int)] {
        switch count {
        case 0: return []            // no pedals on the panel, none drawn
        case 1: return [("Gas", RetroPad.r)]
        default: return [("Gas", RetroPad.r), ("Brake", RetroPad.l)]
        }
    }

    /// One bundled layout file by name, or nil if it has never been
    /// authored. Loaded here rather than through ControlLayout.named,
    /// which asserts on a miss because everywhere else a missing layout IS
    /// a bug; here it just means this panel shape has no tuned file and
    /// the generator is the answer.
    private static func loadLayout(named name: String) -> ControlLayout? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else { return nil }
        return file
    }

    /// A cabinet whose panel carried a joystick AND a dial or trackball
    /// (Discs of Tron, the joystick-plus-spinner family). The stick keeps
    /// its slot; the analog control takes the upper right, clear of the
    /// action buttons below it.
    private static func withAnalogBeside(_ base: ControlLayout, kind: ControlLayout.Item.Kind) -> ControlLayout {
        let sens: Double = kind == .spinner ? 768 : 300
        let item = ControlLayout.Item(
            kind: kind, label: nil, input: nil, inputs: nil,
            frame: ControlLayout.Rect(x: 0.60, y: 0.06, w: 0.30, h: 0.30),
            extended: ControlLayout.Rect(x: 0.56, y: 0.02, w: 0.38, h: 0.38),
            fourWay: nil, sensitivity: sens)
        return ControlLayout(
            system: base.system, items: base.items + [item],
            landscapeItems: base.landscapeItems.map { $0 + [item] },
            companionItems: base.companionItems.map { $0 + [item] },
            headroom: base.headroom)
    }

    private static func buildStandard(for profile: ArcadeProfile, pedals: Int = 0, narrowStick: Bool = false) -> ControlLayout {
        let clearOfPedals = pedals > 0
        // A tuned file wins over the generated arrangement. The generator
        // below is what produced these files in the first place
        // (tools/arcade-layouts), so this changes nothing until one is
        // edited; it exists so arcade layouts can be tuned in the
        // LayoutEditor like every other system instead of being the one
        // corner of the app where layouts are code.
        // A tuned file wins, except on a panel it was never drawn for.
        // Every arcade-stickN.json was authored for a cabinet with no
        // pedals, so on a pedal cabinet its button arc runs straight
        // through the pedal column: that is how button 3 ended up on Super
        // Off Road's accelerator. Fall through to the generator, which
        // knows to keep clear. A tuned pedal panel can claim this back by
        // being authored under its own name.
        if !clearOfPedals, !narrowStick, let tuned = tunedLayout(for: profile) {
            return tuned
        }
        var items: [ControlLayout.Item] = []

        // The stick, low in the left thumb's arc, pivoting from the bottom
        // corner grip. Four way games actively suppress diagonals, which
        // matters for the Pac-Man and Donkey Kong family. A twin-stick game
        // shrinks it to leave room for the second one mirroring it on the
        // right, where the action button arc would otherwise go: aiming is
        // this genre's primary control, not a secondary one competing with
        // movement for space.
        if profile.isDualStick {
            items.append(ControlLayout.Item(
                kind: .dpad,
                label: nil,
                input: nil,
                inputs: [4, 5, 6, 7],
                frame: ControlLayout.Rect(x: 0.04, y: 0.40, w: 0.34, h: 0.46),
                extended: ControlLayout.Rect(x: 0.0, y: 0.32, w: 0.40, h: 0.62),
                fourWay: false
            ))
            items.append(secondStick(landscape: false))
            items.append(contentsOf: dualStickButtons(count: profile.buttons))
        } else {
            // A cabinet that carried a stick AND a dial has to fit three
            // things across one strip, so the stick gives up width. It
            // keeps its height and its bottom-corner pivot, which is what
            // the thumb actually rests on.
            items.append(ControlLayout.Item(
                kind: .dpad,
                label: nil,
                input: nil,
                inputs: [4, 5, 6, 7],
                frame: narrowStick
                    ? ControlLayout.Rect(x: 0.04, y: 0.38, w: 0.30, h: 0.52)
                    : ControlLayout.Rect(x: 0.07, y: 0.38, w: 0.40, h: 0.52),
                extended: narrowStick
                    ? ControlLayout.Rect(x: 0.01, y: 0.32, w: 0.34, h: 0.62)
                    : ControlLayout.Rect(x: 0.02, y: 0.30, w: 0.50, h: 0.68),
                fourWay: profile.isFourWay
            ))
            items.append(contentsOf: actionButtons(
                count: max(0, min(profile.buttons, 6)),
                pedals: pedals, rightLane: narrowStick))
        }

        // Coin and Start are pressed a few times a session, so they take the
        // top band of the strip, out of both thumb arcs where mid-game hands
        // never stray. Coin stays big and obvious: primary in presence, not
        // in position.
        // A breath of margin above both, so Coin never rides the canvas edge.
        items.append(ControlLayout.Item(
            kind: .button,
            label: "Coin",
            input: 2,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.05, y: 0.07, w: 0.14, h: 0.17),
            extended: ControlLayout.Rect(x: 0.01, y: 0.03, w: 0.22, h: 0.26),
            fourWay: nil
        ))
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Start",
            input: 3,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.40, y: 0.10, w: 0.20, h: 0.10),
            extended: ControlLayout.Rect(x: 0.36, y: 0.05, w: 0.28, h: 0.20),
            fourWay: nil
        ))

        // Menu freezes the game the moment it is pressed, so it lives on
        // the pad like any control: hunting a pause through a web menu
        // while something shoots at you is how runs end. Arcade games have
        // no pause of their own, which is exactly why this one matters.
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Menu",
            input: RetroPad.overlay,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.72, y: 0.10, w: 0.17, h: 0.10),
            extended: ControlLayout.Rect(x: 0.68, y: 0.05, w: 0.25, h: 0.20),
            fourWay: nil
        ))

        // The button count rides in the system name because that is what
        // decides the colours: a game overridden to six buttons needs the
        // fighter palette even though its profile still says whatever the
        // cabinet data called it.
        return ControlLayout(
            system: "arcade:\(profile.profile):\(max(0, min(profile.buttons, 6)))",
            items: items,
            landscapeItems: landscapeItems(for: profile, pedals: pedals),
            companionItems: nil,
            headroom: nil
        )
    }

    /// The tuned file for this profile's geometry, if one is bundled.
    ///
    /// Only the stick kind and the button count pick the file: everything
    /// else about a profile is either behaviour or palette, and both are
    /// re-applied here from the live profile rather than trusted from the
    /// file. Four-way-ness in particular is the game's own cabinet data
    /// (Pac-Man and Donkey Kong break when fed diagonals), so it overrides
    /// whatever the file happens to carry, and the system string is rebuilt
    /// so the palette still follows the running game.
    /// The stick or twin-stick file name for a cabinet with no analog
    /// mechanism. Split out so the companion path can ask for it by name
    /// without building the whole layout.
    static func tunedStickName(for profile: ArcadeProfile) -> String {
        "arcade-\(profile.isDualStick ? "twin" : "stick")\(max(0, min(profile.buttons, 6)))"
    }

    private static func tunedLayout(for profile: ArcadeProfile) -> ControlLayout? {
        let count = max(0, min(profile.buttons, 6))
        let name = tunedStickName(for: profile)
        // Loaded here rather than through ControlLayout.named, which
        // asserts on a miss because everywhere else a missing layout IS a
        // bug. Here it simply means this variant has never been tuned, and
        // the generator below is the answer.
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else { return nil }
        let fourWay = profile.isDualStick ? false : profile.isFourWay
        func applied(_ items: [ControlLayout.Item]) -> [ControlLayout.Item] {
            items.map { item in
                guard item.kind == .dpad, item.inputs == [4, 5, 6, 7] else { return item }
                return ControlLayout.Item(
                    kind: item.kind, label: item.label, input: item.input,
                    inputs: item.inputs, frame: item.frame,
                    extended: item.extended, fourWay: fourWay
                )
            }
        }
        return ControlLayout(
            system: "arcade:\(profile.profile):\(count)",
            items: applied(file.items),
            landscapeItems: file.landscapeItems.map(applied),
            companionItems: file.companionItems.map(applied),
            headroom: file.headroom
        )
    }

    /// The landscape arrangement: canvas centred, controls flanking it in
    /// the gutters. Frames are normalised against the full screen.
    private static func landscapeItems(for profile: ArcadeProfile, pedals: Int = 0) -> [ControlLayout.Item] {
        let clearOfPedals = pedals > 0
        var items: [ControlLayout.Item] = []

        if profile.isDualStick {
            items.append(ControlLayout.Item(
                kind: .dpad,
                label: nil,
                input: nil,
                inputs: [4, 5, 6, 7],
                frame: ControlLayout.Rect(x: 0.03, y: 0.42, w: 0.19, h: 0.42),
                extended: ControlLayout.Rect(x: 0.00, y: 0.32, w: 0.24, h: 0.58),
                fourWay: false
            ))
            items.append(secondStick(landscape: true))
            items.append(contentsOf: dualStickButtons(count: profile.buttons, landscape: true))
            items.append(ControlLayout.Item(
                kind: .button,
                label: "Coin",
                input: 2,
                inputs: nil,
                frame: ControlLayout.Rect(x: 0.025, y: 0.06, w: 0.065, h: 0.15),
                extended: ControlLayout.Rect(x: 0.00, y: 0.02, w: 0.10, h: 0.24),
                fourWay: nil
            ))
            items.append(ControlLayout.Item(
                kind: .pill,
                label: "Start",
                input: 3,
                inputs: nil,
                frame: ControlLayout.Rect(x: 0.87, y: 0.07, w: 0.10, h: 0.09),
                extended: ControlLayout.Rect(x: 0.84, y: 0.03, w: 0.15, h: 0.16),
                fourWay: nil
            ))
            items.append(ControlLayout.Item(
                kind: .pill,
                label: "Menu",
                input: RetroPad.overlay,
                inputs: nil,
                frame: ControlLayout.Rect(x: 0.105, y: 0.07, w: 0.10, h: 0.09),
                extended: ControlLayout.Rect(x: 0.10, y: 0.03, w: 0.14, h: 0.16),
                fourWay: nil
            ))
            return items
        }

        items.append(ControlLayout.Item(
            kind: .dpad,
            label: nil,
            input: nil,
            inputs: [4, 5, 6, 7],
            frame: ControlLayout.Rect(x: 0.03, y: 0.42, w: 0.19, h: 0.42),
            extended: ControlLayout.Rect(x: 0.00, y: 0.32, w: 0.24, h: 0.58),
            fourWay: profile.isFourWay
        ))

        // Same reservation the portrait panel makes: a pedal owns L or R,
        // so an action button cannot also send it. See actionIds.
        let singleRowIds = actionIds([0, 8, 1, 9], pedals: pedals)
        let doubleRowIds = actionIds([1, 9, 10, 0, 8, 11], pedals: pedals)
        let wanted = max(0, min(profile.buttons, 6))
        let count = min(wanted, wanted <= 4 ? singleRowIds.count : doubleRowIds.count)

        // Same growth the portrait panel makes, and for the same reason.
        // Smaller here because landscape normalises x against the whole
        // screen rather than a strip, so a landscape button is already
        // wider in points than its fraction suggests.
        let grow: Double = count == 1 ? 1.30 : (count == 2 ? 1.14 : 1)

        func button(id: Int, label: String, x: Double, y: Double) -> ControlLayout.Item {
            let w = 0.07 * grow, h = 0.16 * grow
            // Grown about its own centre and then clamped so the TOUCH
            // frame stays on the panel too. Without the clamp a grown
            // button at the outer end of the arc pushes its own right
            // side off, which is what the rotary and beside-the-stick
            // panels did the first time this was tried.
            let ox = min(max(x - (w - 0.07) / 2, 0.02), 1 - w - 0.02)
            let oy = min(max(y - (h - 0.16) / 2, 0), 1 - h)
            return ControlLayout.Item(
                kind: .button,
                label: label,
                input: id,
                inputs: nil,
                frame: ControlLayout.Rect(x: ox, y: oy, w: w, h: h),
                extended: ControlLayout.Rect(
                    x: ox - 0.02, y: oy - 0.05, w: w + 0.04, h: h + 0.10),
                fourWay: nil
            )
        }

        if count <= 4 {
            // The right thumb's sweep, rotated for landscape: rising from
            // low inside toward the upper corner.
            // A driving cabinet's buttons belong beside the wheel, not out
            // in the middle. Super Off Road put its boost on the panel by
            // the wheel, and the ergonomics say the same thing louder: the
            // pedal lives on the right edge and is held down continuously,
            // so a button anywhere right of centre can only be reached by
            // the thumb that is holding the gas. Put them by the wheel and
            // the steering hand takes them while the throttle hand never
            // moves. Marcus found this playing it.
            let positions: [(Double, Double)] = clearOfPedals
                ? [(0.22, 0.66), (0.22, 0.42), (0.30, 0.66), (0.30, 0.42)]
                : [(0.78, 0.64), (0.85, 0.46), (0.90, 0.26), (0.90, 0.68)]
            for index in 0..<count {
                let (x, y) = positions[index]
                items.append(button(
                    id: singleRowIds[index], label: "\(index + 1)", x: x, y: y
                ))
            }
        } else {
            let columns: [Double] = clearOfPedals ? [0.22, 0.30, 0.38] : [0.77, 0.845, 0.92]
            // Three columns where there is room, two where a pedal or an
            // analog control has taken a lane. The row count follows.
            let perRow = columns.count
            let rowY: [Double] = perRow == 3 ? [0.36, 0.62] : [0.22, 0.48, 0.74]
            for index in 0..<count {
                let row = index / perRow
                let column = index % perRow
                items.append(button(
                    id: doubleRowIds[index],
                    label: "\(index + 1)",
                    x: columns[column],
                    y: rowY[min(row, rowY.count - 1)]
                ))
            }
        }

        items.append(ControlLayout.Item(
            kind: .button,
            label: "Coin",
            input: 2,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.025, y: 0.06, w: 0.065, h: 0.15),
            extended: ControlLayout.Rect(x: 0.00, y: 0.02, w: 0.10, h: 0.24),
            fourWay: nil
        ))
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Start",
            input: 3,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.87, y: 0.07, w: 0.10, h: 0.09),
            extended: ControlLayout.Rect(x: 0.84, y: 0.03, w: 0.15, h: 0.16),
            fourWay: nil
        ))

        // Beside Coin in the top left gutter, out of both thumb arcs.
        items.append(ControlLayout.Item(
            kind: .pill,
            label: "Menu",
            input: RetroPad.overlay,
            inputs: nil,
            frame: ControlLayout.Rect(x: 0.105, y: 0.07, w: 0.10, h: 0.09),
            extended: ControlLayout.Rect(x: 0.10, y: 0.03, w: 0.14, h: 0.16),
            fourWay: nil
        ))

        return items
    }

    /// Action buttons in the right thumb's arc. The arc curls with the
    /// thumb's natural sweep, from low inside toward the corner, so moving
    /// between buttons is a rotation of the thumb, never a new grip. Two
    /// rows of three keep cabinet muscle memory for six button games,
    /// dropped low enough that the top row is a stretch, not a reach.
    /// The right-hand column a pedal occupies, hit frame included. Buttons
    /// generated past this collide with it, and a pedal is a wide target a
    /// thumb rests on, so the collision is not theoretical.
    private static let pedalColumn = 0.815


    /// The RetroPad ids an action button may use on this panel.
    ///
    /// L and R are the PEDALS on a cabinet that has them: this core maps
    /// MAME's button 6 to R and button 5 to L and renames them Pedal and
    /// Pedal2 when a driver declares them. So a cabinet the profile calls
    /// "six button" with one pedal really has five buttons and a pedal,
    /// and drawing six put button 6 on the same id as the Gas. Pressing it
    /// pressed the accelerator, on Cruis'n USA, San Francisco Rush,
    /// California Speed, Spy Hunter II, Virtua Racing, Off Road Challenge,
    /// Hydra and Golden Tee. Found 2026-08-25 by drawing every panel at
    /// its real size and then checking what each control actually sends.
    ///
    /// The count follows the ids rather than the other way round: a panel
    /// cannot show more buttons than the pad has left.
    private static func actionIds(_ order: [Int], pedals: Int) -> [Int] {
        let taken = Set(pedalSpecs(count: pedals).map(\.input))
        return order.filter { !taken.contains($0) }
    }

    private static func actionButtons(count: Int, pedals: Int = 0, rightLane: Bool = false) -> [ControlLayout.Item] {
        let clearOfPedals = pedals > 0
        let singleRowIds = actionIds([0, 8, 1, 9], pedals: pedals)          // B A Y X
        let doubleRowIds = actionIds([1, 9, 10, 0, 8, 11], pedals: pedals)  // Y X L / B A R
        let count = min(count, count <= 4 ? singleRowIds.count : doubleRowIds.count)
        guard count > 0 else { return [] }

        var items: [ControlLayout.Item] = []

        // A panel with one or two buttons has the whole thumb arc to
        // itself, so the buttons grow into it. The POSITIONS do not move:
        // the arc starts at the thumb's resting place on purpose, and
        // sliding a lone button up the sweep away from that rest would
        // trade a good spot for a centred one. Size is what a sparse panel
        // was actually wasting. Donkey Kong, Galaga, Dig Dug and most of
        // the era get a target a third wider; three or more buttons are
        // untouched, because there the arc is already full.
        let grow: Double = count == 1 ? 1.34 : (count == 2 ? 1.16 : 1)
        func button(id: Int, label: String, x: Double, y: Double) -> ControlLayout.Item {
            let w = 0.15 * grow, h = 0.20 * grow
            // Grown about its own centre and then clamped so the TOUCH
            // frame stays on the panel too. Without the clamp a grown
            // button at the outer end of the arc pushes its own right
            // side off, which is what the rotary and beside-the-stick
            // panels did the first time this was tried.
            let ox = min(max(x - (w - 0.15) / 2, 0.04), 1 - w - 0.04)
            let oy = min(max(y - (h - 0.20) / 2, 0), 1 - h)
            return ControlLayout.Item(
                kind: .button,
                label: label,
                input: id,
                inputs: nil,
                frame: ControlLayout.Rect(x: ox, y: oy, w: w, h: h),
                extended: ControlLayout.Rect(
                    x: ox - 0.04, y: oy - 0.06, w: w + 0.08, h: h + 0.12),
                fourWay: nil
            )
        }

        if count <= 4 {
            // The sweep: button one sits at the thumb's rest, later buttons
            // follow the arc up and outward. A fourth tucks below the arc.
            //
            // A cabinet with pedals gives that outward room away: the pedal
            // column is a wide target on the right edge and the arc used to
            // be drawn straight through it, putting button 3 on the Gas.
            // The arc tightens instead of overlapping, which costs some
            // spread and costs nothing that works.
            //
            // A button is 0.20 tall and its touch frame reaches 0.26 below
            // its own top, so 0.74 is the lowest a fourth button can start
            // and still be on the panel at all. Both tightened arcs used to
            // put it lower than that: the pedal arc at 0.84 drew button
            // four thirteen points BELOW the bottom edge of the strip, and
            // the right-lane arc at 0.80 kept the button on screen while
            // hanging a third of its touch area off. Neither was visible
            // until every panel was drawn side by side.
            let positions: [(Double, Double)]
            if rightLane {
                // The analog control owns the middle lane, so the arc
                // stacks in the right one rather than sweeping across it.
                positions = [(0.70, 0.62), (0.84, 0.44), (0.70, 0.26), (0.84, 0.74)]
            } else if clearOfPedals {
                // The pedal column starts at 0.855 and its touch frame at
                // 0.815, so the fourth tucks inside that rather than under
                // button one, where there is no room left below.
                positions = [(0.42, 0.62), (0.56, 0.44), (0.50, 0.24), (0.62, 0.70)]
            } else {
                positions = [(0.54, 0.58), (0.70, 0.44), (0.82, 0.28), (0.80, 0.62)]
            }
            for index in 0..<count {
                let (x, y) = positions[index]
                items.append(button(
                    id: singleRowIds[index], label: "\(index + 1)", x: x, y: y
                ))
            }
        } else {
            // Two rows of three, low in the strip, pulled left of the
            // pedal column when the cabinet has one.
            // Three columns where there is room, two where a pedal or an
            // analog control has taken a lane. Columns sit 0.16 apart so
            // two 0.15-wide buttons never draw through each other, and the
            // row count follows from how many columns are left.
            let columns: [Double] = rightLane ? [0.68, 0.84]
                : (clearOfPedals ? [0.42, 0.58] : [0.50, 0.66, 0.82])
            let rowY: [Double] = columns.count == 3 ? [0.36, 0.62] : [0.20, 0.46, 0.72]
            for index in 0..<count {
                let row = index / columns.count
                let column = index % columns.count
                items.append(button(
                    id: doubleRowIds[index],
                    label: "\(index + 1)",
                    x: columns[column],
                    y: rowY[min(row, rowY.count - 1)]
                ))
            }
        }

        return items
    }

    /// The second joystick, mirroring the first on the right rather than
    /// taking the action buttons' usual arc: aiming is this genre's primary
    /// control. Drawn as a d-pad, the same digital cross the first stick is,
    /// because it is one on the real cabinet; FBNeo routes it through the
    /// analog right stick indices underneath, which `PlayerView.Input.send`
    /// already handles for anything in that range, so nothing here needs to
    /// know the difference.
    private static func secondStick(landscape: Bool) -> ControlLayout.Item {
        let ids = [23, 22, 21, 20]   // up, down, left, right
        if landscape {
            return ControlLayout.Item(
                kind: .dpad, label: nil, input: nil, inputs: ids,
                frame: ControlLayout.Rect(x: 0.78, y: 0.42, w: 0.19, h: 0.42),
                extended: ControlLayout.Rect(x: 0.76, y: 0.32, w: 0.24, h: 0.58),
                fourWay: false
            )
        }
        return ControlLayout.Item(
            kind: .dpad, label: nil, input: nil, inputs: ids,
            frame: ControlLayout.Rect(x: 0.62, y: 0.40, w: 0.34, h: 0.46),
            extended: ControlLayout.Rect(x: 0.60, y: 0.32, w: 0.40, h: 0.62),
            fourWay: false
        )
    }

    /// A twin-stick game's own fire/bomb buttons, ordinary digital buttons
    /// on the real cabinet and RetroPad ids here, unlike the sticks either
    /// side of them: only a joystick's directions get the analog reroute.
    /// Portrait, they sit in the gap the two sticks leave between them, the
    /// one open patch of strip; landscape has no equivalent gap, so they
    /// stack in the same top corner Start already occupies its own game's
    /// worth of room away from.
    /// The buttons on a twin-stick panel, which live in the corridor
    /// between the two sticks because both thumbs are already spoken for.
    ///
    /// Two faults, found by Marcus on 2026-08-25 looking at arcade-twin6
    /// in the editor, and both invisible to the checks of the day. It
    /// stopped at FOUR ids, so a six button cabinet silently lost buttons
    /// five and six: Air Race, Last Starfighter and two others were
    /// missing controls with nothing said. And the four it did draw
    /// overlapped each other by 43 percent of their own area, three of
    /// them sharing one row 0.08 apart when each was 0.14 wide, so the
    /// circles drew straight through one another.
    ///
    /// The corridor is 0.24 wide in portrait, between sticks that end at
    /// 0.38 and begin again at 0.62. Two columns of 0.11 fit inside it
    /// with a gap, which is 47 points on the narrow axis, and three rows
    /// carry six. Nothing here is allowed to touch its neighbour: buttons
    /// may share a TOUCH frame, which is the deliberate diagonal-friendly
    /// trick a face-button diamond uses, but two drawn circles running
    /// through each other is just a mistake.
    private static func dualStickButtons(count: Int, landscape: Bool = false) -> [ControlLayout.Item] {
        let ids = [0, 8, 1, 9, 10, 11]              // B A Y X L R
        let shown = max(0, min(count, ids.count))
        guard shown > 0 else { return [] }

        func item(id: Int, label: String, x: Double, y: Double, w: Double, h: Double) -> ControlLayout.Item {
            ControlLayout.Item(
                kind: .button, label: label, input: id, inputs: nil,
                frame: ControlLayout.Rect(x: x, y: y, w: w, h: h),
                extended: ControlLayout.Rect(x: x - 0.03, y: y - 0.03, w: w + 0.06, h: h + 0.06),
                fourWay: nil
            )
        }

        // One or two buttons keep the single centred column they have
        // always had: it is roomier than a grid and it does not overlap,
        // and 170 of the 198 twin-stick cabinets in the data are in that
        // group. Only three or more move.
        let single: [(Double, Double)] = landscape
            ? [(0.47, 0.30), (0.47, 0.52)]
            : [(0.43, 0.44), (0.43, 0.68)]
        let (w, h) = landscape ? (0.06, 0.14) : (0.14, 0.16)
        if shown <= 2 {
            return (0..<shown).map { i in
                item(id: ids[i], label: "\(i + 1)", x: single[i].0, y: single[i].1, w: w, h: h)
            }
        }

        // Three or more: two columns in the corridor, filled in reading
        // order, and only as many rows as the count actually needs so a
        // four button panel sits centred rather than leaving a hole.
        let columns: [Double] = landscape ? [0.42, 0.54] : [0.375, 0.505]
        let gw = landscape ? 0.06 : 0.11
        let gh = landscape ? 0.14 : 0.145
        let rows = (shown + 1) / 2
        let span = landscape ? 0.22 : 0.22
        let top = landscape ? (0.50 - Double(rows - 1) * span / 2 - gh / 2)
                            : (0.56 - Double(rows - 1) * span / 2 - gh / 2)
        return (0..<shown).map { i in
            item(id: ids[i], label: "\(i + 1)",
                 x: columns[i % 2], y: top + Double(i / 2) * span, w: gw, h: gh)
        }
    }
}
