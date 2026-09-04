import SwiftUI
import MetalKit

/// The VMU minigame player: the phone becomes the VMU. Full shell edge
/// to edge, the screen sunk in its slate bezel, d-pad lower left, A/B
/// lower right, SLEEP and MENU pills flanking the speaker grille, the
/// beeper's audio coming from the core. The skin is the feature, not
/// decoration, and it is a game surface, so the ambient-restraint rule
/// is not violated.
///
/// Every measurement, color and behavior here transcribes the stamped
/// reference, spikes/vmu/vmu-skin-mock2.html, approved to the pixel on
/// 2026-08-29: the seamless drawn cross that tilts ~14deg toward the
/// pressed wing while the disc stays fixed, buttons that visibly
/// depress, the LED lighting for SLEEP and MENU only, and the sleep
/// screen's little cabinet with two z's rising one at a time. The mock's
/// per-button beeps were demo flavor and are deliberately absent; real
/// audio comes from the emulated VMU alone, and presses give a haptic
/// tick honoring the existing Rumble setting instead.
///
/// MENU and SLEEP are frontend-side on purpose, never core inputs:
/// VeMUlator leaves MODE disabled (sending START hangs the HLE boot,
/// documented in the core's own main.cpp) and never maps SLEEP. MENU
/// opens Cabinet's in-player menu overlay, truer to the real button's
/// 1999 return-to-menu role than a hard exit; SLEEP pauses with the LCD
/// fading to the sleep animation, tap again to wake. The pill reads
/// MENU rather than the historical MODE because it opens Cabinet's
/// menu: honest labels over museum labels.
struct VMUPlayerView: View {
    let rom: Rom
    let cardURL: URL

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var renderer = NativePlayerRenderer()
    @ObservedObject private var controllers = GameControllerManager.shared
    @State private var previousControllerSend: ((Int, Int, Bool) -> Void)?
    @State private var previousControllerStick: ((Int, Float, Float) -> Void)?
    @State private var previousControllerMenu: (() -> Void)?
    @State private var previousControllerDisconnect: ((Int) -> Void)?
    @State private var bootError: String?
    @State private var menuVisible = false
    @State private var asleep = false
    @State private var sleepFrame = 0
    @State private var sleepTicker: Timer?
    /// The LED, one light with three reasons: the steady ember while
    /// asleep, lit while MENU is held, and one blink as the menu closes.
    @State private var menuHeld = false
    @State private var ledBlink = false
    @State private var tiltX = 0.0
    @State private var tiltY = 0.0

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let m = VMUSkinMetrics(size: geo.size)
            ZStack {
                // The dark ground the cap sits against, the one part of
                // the screen that is not shell.
                Color(red: 0.067, green: 0.082, blue: 0.106)

                connectorCap(m)
                shell(m)

                brand(m)

                led(m)

                VMULCDScreen(
                    renderer: renderer, asleep: asleep, sleepFrame: sleepFrame, metrics: m
                )
                .position(x: m.w / 2, y: m.top(297))

                dpad(m)
                actionButtons(m)
                bottomRow(m)

                if menuVisible { menu }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                renderer.paused = true
                // The server half of the sync policy: a pocketed phone
                // or an iOS kill must not strand the card on this
                // device. The core is paused, so the file is quiescent.
                Task { await VMULauncher.capture(rom: rom, session: session) }
            } else if phase == .active && !menuVisible && !asleep {
                renderer.paused = false
            }
        }
        .alert(
            "Couldn't start the VMU",
            isPresented: Binding(get: { bootError != nil }, set: { if !$0 { bootError = nil; dismiss() } })
        ) {
            Button("OK") { bootError = nil; dismiss() }
        } message: {
            Text(bootError ?? "")
        }
    }

    // MARK: Lifecycle

    private func start() {
        OrientationLock.lockToPortrait()
        UIApplication.shared.isIdleTimerDisabled = true
        GameControllerManager.shared.start()
        previousControllerSend = GameControllerManager.shared.send
        previousControllerStick = GameControllerManager.shared.sendStick
        previousControllerMenu = GameControllerManager.shared.onMenu
        previousControllerDisconnect = GameControllerManager.shared.onDisconnect
        // A Bluetooth pad auto-works through the standard path, filtered
        // to the buttons a VMU has. The whitelist is load-bearing, not
        // tidiness: RetroPad.start would reach the core as MODE, whose
        // handler upstream disabled because it hangs the BIOS-less boot.
        // Everything lands on port 0; a VMU is one player by definition.
        let allowed: Set<Int> = [RetroPad.b, RetroPad.up, RetroPad.down, RetroPad.left, RetroPad.right, RetroPad.a]
        GameControllerManager.shared.send = { [weak renderer] _, id, down in
            guard allowed.contains(id) else { return }
            renderer?.setButton(id, down: down, port: 0)
        }
        GameControllerManager.shared.sendStick = { _, _, _ in }
        GameControllerManager.shared.onMenu = { openMenu() }
        GameControllerManager.shared.onDisconnect = { player in
            if player == 0 { openMenu() }
        }
        if let failure = VMULauncher.boot(cardURL: cardURL) {
            bootError = failure
        }
    }

    private func stop() {
        sleepTicker?.invalidate()
        sleepTicker = nil
        UIApplication.shared.isIdleTimerDisabled = false
        OrientationLock.unlock()
        GameControllerManager.shared.send = previousControllerSend
        GameControllerManager.shared.sendStick = previousControllerStick
        GameControllerManager.shared.onMenu = previousControllerMenu
        GameControllerManager.shared.onDisconnect = previousControllerDisconnect
        // Shut the core down first, the order NativePlayerView settled:
        // deinit closes the core's flash writer, so the capture below
        // reads a file nothing holds open.
        LibretroFrontend.shared.unloadGame()
        Task { await VMULauncher.capture(rom: rom, session: session) }
    }

    private func openMenu() {
        guard !menuVisible else { return }
        renderer.paused = true
        menuVisible = true
    }

    private func closeMenu() {
        menuVisible = false
        // One blink as the menu goes, the LED's third and last job.
        ledBlink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { ledBlink = false }
        if !asleep { renderer.paused = false }
    }

    private func toggleSleep() {
        asleep.toggle()
        if asleep {
            renderer.paused = true
            sleepFrame = 0
            sleepTicker = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { _ in
                sleepFrame = (sleepFrame + 1) % 3
            }
        } else {
            sleepTicker?.invalidate()
            sleepTicker = nil
            if !menuVisible { renderer.paused = false }
        }
    }

    private func tick() {
        guard UserDefaults.standard.bool(forKey: "com.mmagtech.RommApp.rumbleEnabled") else { return }
        haptic.impactOccurred(intensity: 0.7)
    }

    // MARK: Pieces

    private func brand(_ m: VMUSkinMetrics) -> some View {
        let brandY: CGFloat = m.top(96) + 10 * m.s
        let dotsY: CGFloat = m.top(128) + 5 * m.s
        return ZStack {
            Text("CABINET")
                .font(.system(size: 20 * m.s, weight: .bold))
                .tracking(10 * m.s)
                .foregroundStyle(Color(red: 0.357, green: 0.4, blue: 0.459))
                // Half the trailing tracking, so the tracked text still
                // reads centred.
                .offset(x: 5 * m.s)
                .position(x: m.w / 2, y: brandY)

            Text("\u{2022} \u{2022} \u{2022} \u{2022}")
                .font(.system(size: 9 * m.s))
                .tracking(12 * m.s)
                .foregroundStyle(Color(red: 0.545, green: 0.58, blue: 0.635))
                .offset(x: 6 * m.s)
                .position(x: m.w / 2, y: dotsY)
        }
    }

    private func connectorCap(_ m: VMUSkinMetrics) -> some View {
        VStack(spacing: 5 * m.s) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2 * m.s)
                    .fill(Color.black.opacity(0.18))
                    .frame(width: 146 * m.s, height: 3 * m.s)
            }
        }
        .frame(width: 190 * m.s, height: 70 * m.s, alignment: .top)
        .padding(.top, 16 * m.s)
        .background(
            RoundedRectangle(cornerRadius: 14 * m.s)
                .fill(LinearGradient(
                    colors: [Color(red: 0.541, green: 0.576, blue: 0.639), Color(red: 0.427, green: 0.463, blue: 0.525)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 14 * m.s)
                        .fill(LinearGradient(
                            colors: [.clear, Color.black.opacity(0.25)],
                            startPoint: .center, endPoint: .bottom
                        ))
                )
        )
        .position(x: m.w / 2, y: m.top(61))
    }

    private func shell(_ m: VMUSkinMetrics) -> some View {
        let shellW: CGFloat = m.w - 20 * m.s
        let shellH: CGFloat = m.h - m.top(64) - 8 * m.s
        let shellY: CGFloat = m.top(64) + shellH / 2
        return UnevenRoundedRectangle(
            topLeadingRadius: 44 * m.s, bottomLeadingRadius: 52 * m.s,
            bottomTrailingRadius: 52 * m.s, topTrailingRadius: 44 * m.s
        )
        .fill(LinearGradient(
            colors: [
                Color(red: 0.957, green: 0.945, blue: 0.918),
                Color(red: 0.925, green: 0.91, blue: 0.875),
                Color(red: 0.867, green: 0.847, blue: 0.804),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 44 * m.s, bottomLeadingRadius: 52 * m.s,
                bottomTrailingRadius: 52 * m.s, topTrailingRadius: 44 * m.s
            )
            .stroke(Color.white.opacity(0.5), lineWidth: 1.5 * m.s)
            .blendMode(.overlay)
        )
        .shadow(color: .black.opacity(0.35), radius: 8 * m.s, y: 3 * m.s)
        .frame(width: shellW, height: shellH)
        .position(x: m.w / 2, y: shellY)
    }

    private var ledOn: Bool {
        asleep || menuHeld || ledBlink
    }

    private func led(_ m: VMUSkinMetrics) -> some View {
        RoundedRectangle(cornerRadius: 4 * m.s)
            .fill(ledOn ? Color(red: 0.243, green: 0.941, blue: 0.494) : Color(red: 0.608, green: 0.91, blue: 0.69))
            .frame(width: 34 * m.s, height: 7 * m.s)
            .shadow(
                color: Color(red: 0.243, green: 0.941, blue: 0.494).opacity(ledOn ? 0.9 : 0.35),
                radius: (ledOn ? 8 : 4) * m.s
            )
            .animation(.easeOut(duration: 0.08), value: ledOn)
            .position(x: m.w / 2, y: m.top(151.5))
    }

    private func dpad(_ m: VMUSkinMetrics) -> some View {
        let size = 148 * m.s
        let dpadY: CGFloat = m.bottom(166) - size / 2
        return ZStack {
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: Color(red: 0.431, green: 0.478, blue: 0.541), location: 0),
                        .init(color: Color(red: 0.302, green: 0.345, blue: 0.4), location: 0.7),
                        .init(color: Color(red: 0.247, green: 0.29, blue: 0.341), location: 1),
                    ]),
                    center: UnitPoint(x: 0.42, y: 0.32),
                    startRadius: 0, endRadius: size * 0.75
                ))
                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1.5 * m.s))
                .frame(width: size, height: size)

            VMUCross(s: m.s)
                .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.3)
                .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
                .animation(.easeOut(duration: 0.07), value: tiltX)
                .animation(.easeOut(duration: 0.07), value: tiltY)

            // The four wings, each an independent control. The hit
            // frames are the mock's 50x50 zones; the tilt composes, so
            // a diagonal hold leans the cross diagonally.
            wing(m, id: RetroPad.up, x: 74, y: 25) { down in tiltX = down ? 14 : 0 }
            wing(m, id: RetroPad.down, x: 74, y: 123) { down in tiltX = down ? -14 : 0 }
            wing(m, id: RetroPad.left, x: 25, y: 74) { down in tiltY = down ? -14 : 0 }
            wing(m, id: RetroPad.right, x: 123, y: 74) { down in tiltY = down ? 14 : 0 }
        }
        .frame(width: size, height: size)
        .position(x: 30 * m.s + size / 2, y: dpadY)
    }

    private func wing(
        _ m: VMUSkinMetrics, id: Int, x: CGFloat, y: CGFloat,
        tilt: @escaping (Bool) -> Void
    ) -> some View {
        VMUPressZone(
            onPress: {
                tilt(true)
                renderer.setButton(id, down: true, port: 0)
                tick()
            },
            onRelease: {
                tilt(false)
                renderer.setButton(id, down: false, port: 0)
            }
        )
        .frame(width: 50 * m.s, height: 50 * m.s)
        .position(x: x * m.s, y: y * m.s)
    }

    private func actionButtons(_ m: VMUSkinMetrics) -> some View {
        let bX: CGFloat = m.w - 75 * m.s
        let bY: CGFloat = m.bottom(240) - 31 * m.s
        let aX: CGFloat = m.w - 127 * m.s
        let aY: CGFloat = m.bottom(178) - 31 * m.s
        return ZStack {
            VMURoundButton(
                label: "B", s: m.s,
                colors: (
                    Color(red: 0.843, green: 0.765, blue: 0.91),
                    Color(red: 0.706, green: 0.608, blue: 0.808),
                    Color(red: 0.631, green: 0.537, blue: 0.741)
                ),
                text: Color(red: 0.357, green: 0.29, blue: 0.439),
                onPress: { renderer.setButton(RetroPad.b, down: true, port: 0); tick() },
                onRelease: { renderer.setButton(RetroPad.b, down: false, port: 0) }
            )
            .position(x: bX, y: bY)

            VMURoundButton(
                label: "A", s: m.s,
                colors: (
                    Color(red: 0.718, green: 0.863, blue: 0.769),
                    Color(red: 0.561, green: 0.761, blue: 0.631),
                    Color(red: 0.486, green: 0.698, blue: 0.561)
                ),
                text: Color(red: 0.235, green: 0.42, blue: 0.306),
                onPress: { renderer.setButton(RetroPad.a, down: true, port: 0); tick() },
                onRelease: { renderer.setButton(RetroPad.a, down: false, port: 0) }
            )
            .position(x: aX, y: aY)
        }
    }

    private func bottomRow(_ m: VMUSkinMetrics) -> some View {
        let rowY: CGFloat = m.bottom(64) - 16 * m.s
        let sleepX: CGFloat = 83 * m.s
        let menuX: CGFloat = m.w - 83 * m.s
        return ZStack {
            VMUPill(label: "SLEEP", s: m.s, onPress: {
                tick()
                // The deliberate fades live on the LCD cover; the state
                // flips now and the 0.6 seconds belong to the show.
                withAnimation(.easeInOut(duration: 0.6)) { toggleSleep() }
            }, onRelease: {})
            .position(x: sleepX, y: rowY)

            // The speaker grille, 12 drilled dots. Decoration with a
            // real referent: the beeper underneath is the core's.
            VStack(spacing: 6 * m.s) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 6 * m.s) {
                        ForEach(0..<6, id: \.self) { _ in
                            Circle()
                                .fill(Color(red: 0.353, green: 0.333, blue: 0.275).opacity(0.35))
                                .frame(width: 5 * m.s, height: 5 * m.s)
                        }
                    }
                }
            }
            .position(x: m.w / 2, y: rowY)

            VMUPill(label: "MENU", s: m.s, onPress: {
                menuHeld = true
                tick()
            }, onRelease: {
                menuHeld = false
                openMenu()
            })
            .position(x: menuX, y: rowY)
        }
    }

    /// The player menu MENU opens: resume and quit, nothing more. No
    /// save states (the core cannot serialize, and the card file is the
    /// persistence), no shader row (the skin is the presentation). The
    /// card matches the other players' pause menus so mid-session
    /// Cabinet reads as one app.
    private var menu: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { closeMenu() }
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(rom.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Paused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        Label("Quit", systemImage: "xmark")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        closeMenu()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: 280)
            .padding(24)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .padding(40)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Geometry

/// The stamped mock's 360x780 design space mapped onto a real screen:
/// one uniform scale from the width, top chrome anchored to the top,
/// the control cluster anchored to the bottom, so a taller phone
/// stretches only the blank shell between the bezel and the d-pad.
struct VMUSkinMetrics {
    let w: CGFloat
    let h: CGFloat
    let s: CGFloat

    init(size: CGSize) {
        w = size.width
        h = size.height
        s = size.width / 360
    }

    /// A design-space y measured from the mock's top edge.
    func top(_ y: CGFloat) -> CGFloat { y * s }
    /// A design-space distance from the mock's bottom edge, as a real y.
    func bottom(_ d: CGFloat) -> CGFloat { h - d * s }
}

// MARK: - Press handling

/// A press the skin can act on: down fires immediately (games read the
/// button that frame), up or the finger wandering off releases. The
/// generic overlay's extended-hit sophistication deliberately stays
/// there; a VMU's five controls are big and far apart.
private struct VMUPressZone: View {
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            // A finger wandering off the wing releases
                            // it, the stamped mock's pointerleave rule; a
                            // small margin keeps a held press from
                            // fluttering right at the edge.
                            let inside = CGRect(origin: .zero, size: geo.size)
                                .insetBy(dx: -8, dy: -8)
                                .contains(g.location)
                            if inside, !pressed {
                                pressed = true
                                onPress()
                            } else if !inside, pressed {
                                pressed = false
                                onRelease()
                            }
                        }
                        .onEnded { _ in
                            if pressed {
                                pressed = false
                                onRelease()
                            }
                        }
                )
        }
    }
}

// MARK: - The cross

/// The d-pad cross as one drawn, molded piece, never assembled parts:
/// two rounded bars unioned into a single fill, the sheen and center
/// dome clipped to it, four small triangles on the wings. Lesson paid
/// for in the mock's iterations and kept: build the cross as one shape.
private struct VMUCross: View {
    let s: CGFloat

    var body: some View {
        let size = 148 * s
        ZStack {
            crossShape
                .fill(Color(red: 0.322, green: 0.373, blue: 0.439))
                .shadow(color: .black.opacity(0.38), radius: 4 * s, y: 5 * s)

            // Sheen and dome live inside the molding.
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0.30), location: 0),
                    .init(color: .white.opacity(0.06), location: 0.35),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                startPoint: .top, endPoint: .bottom
            )
            .clipShape(crossShape)

            RadialGradient(
                gradient: Gradient(colors: [Color(red: 0.365, green: 0.416, blue: 0.478), Color(red: 0.365, green: 0.416, blue: 0.478).opacity(0)]),
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0, endRadius: 30 * s
            )
            .clipShape(crossShape)

            triangles
                .fill(Color(red: 0.682, green: 0.725, blue: 0.784).opacity(0.75))
        }
        .frame(width: size, height: size)
    }

    private var crossShape: Path {
        var p = Path()
        p.addRoundedRect(
            in: CGRect(x: 51 * s, y: 8 * s, width: 46 * s, height: 132 * s),
            cornerSize: CGSize(width: 17 * s, height: 17 * s)
        )
        p.addRoundedRect(
            in: CGRect(x: 8 * s, y: 51 * s, width: 132 * s, height: 46 * s),
            cornerSize: CGSize(width: 17 * s, height: 17 * s)
        )
        return p
    }

    private var triangles: Path {
        var p = Path()
        // Up: apex toward the center, exactly the mock's four marks.
        p.move(to: CGPoint(x: 74 * s, y: 20 * s))
        p.addLine(to: CGPoint(x: 81 * s, y: 30 * s))
        p.addLine(to: CGPoint(x: 67 * s, y: 30 * s))
        p.closeSubpath()
        p.move(to: CGPoint(x: 74 * s, y: 128 * s))
        p.addLine(to: CGPoint(x: 81 * s, y: 118 * s))
        p.addLine(to: CGPoint(x: 67 * s, y: 118 * s))
        p.closeSubpath()
        p.move(to: CGPoint(x: 20 * s, y: 74 * s))
        p.addLine(to: CGPoint(x: 30 * s, y: 67 * s))
        p.addLine(to: CGPoint(x: 30 * s, y: 81 * s))
        p.closeSubpath()
        p.move(to: CGPoint(x: 128 * s, y: 74 * s))
        p.addLine(to: CGPoint(x: 118 * s, y: 67 * s))
        p.addLine(to: CGPoint(x: 118 * s, y: 81 * s))
        p.closeSubpath()
        return p
    }
}

// MARK: - Buttons

private struct VMURoundButton: View {
    let label: String
    let s: CGFloat
    let colors: (Color, Color, Color)
    let text: Color
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        let size = 62 * s
        Text(label)
            .font(.system(size: 24 * s, weight: .bold))
            .foregroundStyle(text)
            .frame(width: size, height: size)
            .background(
                Circle().fill(RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: colors.0, location: 0),
                        .init(color: colors.1, location: 0.7),
                        .init(color: colors.2, location: 1),
                    ]),
                    center: UnitPoint(x: 0.38, y: 0.3),
                    startRadius: 0, endRadius: size * 0.75
                ))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(pressed ? 0.3 : 0.5), lineWidth: 2 * s)
                    .blur(radius: 1 * s)
                    .offset(y: 1 * s)
                    .mask(Circle())
            )
            // The cap sinks and its shadow shortens: the depress the
            // stamped mock requires, not a highlight swap.
            .shadow(
                color: .black.opacity(pressed ? 0.4 : 0.3),
                radius: (pressed ? 3 : 8) * s, y: (pressed ? 2 : 8) * s
            )
            .offset(y: (pressed ? 4 : 0) * s)
            .animation(.easeOut(duration: 0.06), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

private struct VMUPill: View {
    let label: String
    let s: CGFloat
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 11 * s, weight: .bold))
            .tracking(2 * s)
            .foregroundStyle(Color(red: 0.486, green: 0.525, blue: 0.58))
            .frame(width: 74 * s, height: 32 * s)
            .background(
                RoundedRectangle(cornerRadius: 18 * s)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.98, green: 0.973, blue: 0.949), Color(red: 0.91, green: 0.894, blue: 0.855)],
                        startPoint: .top, endPoint: .bottom
                    ))
            )
            .shadow(
                color: .black.opacity(pressed ? 0.3 : 0.22),
                radius: (pressed ? 2 : 5) * s, y: (pressed ? 1 : 4) * s
            )
            .offset(y: (pressed ? 2 : 0) * s)
            .animation(.easeOut(duration: 0.06), value: pressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        onRelease()
                    }
            )
    }
}

// MARK: - The screen

/// The slate bezel and the sage LCD sunk into it. The picture is the
/// core's frame through the vmuLCD shader, whose paper gradient is this
/// view's own face gradient at the picture's fixed position (160 of 208
/// design units, centred; the shader's 0.1154..0.8846 remap encodes
/// exactly that, keep the two in lock step). Sleep covers the picture
/// with the stamped animation frames, fading over the 0.6 seconds the
/// design gives the show.
private struct VMULCDScreen: View {
    @ObservedObject var renderer: NativePlayerRenderer
    let asleep: Bool
    let sleepFrame: Int
    let metrics: VMUSkinMetrics

    var body: some View {
        let s = metrics.s
        ZStack {
            RoundedRectangle(cornerRadius: 26 * s)
                .fill(LinearGradient(
                    colors: [Color(red: 0.365, green: 0.416, blue: 0.486), Color(red: 0.275, green: 0.322, blue: 0.373)],
                    startPoint: .top, endPoint: .bottom
                ))
                .shadow(color: .black.opacity(0.25), radius: 6 * s, y: 6 * s)
                .frame(width: 286 * s, height: 250 * s)

            ZStack {
                // The face, whose gradient the shader's paper continues.
                RoundedRectangle(cornerRadius: 10 * s)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.765, green: 0.804, blue: 0.706), Color(red: 0.702, green: 0.749, blue: 0.651)],
                        startPoint: .top, endPoint: .bottom
                    ))

                MetalGameView(
                    renderer: renderer,
                    clearColor: MTLClearColorMake(0.733, 0.776, 0.678, 1)
                )
                .frame(width: 240 * s, height: 160 * s)
                .opacity(asleep ? 0 : 1)

                VMUSleepScreen(frame: sleepFrame, s: s)
                    .frame(width: 240 * s, height: 160 * s)
                    .opacity(asleep ? 1 : 0)

                // The glass: an inner shadow at the top edge and a
                // diagonal sheen, both the mock's.
                RoundedRectangle(cornerRadius: 10 * s)
                    .stroke(Color(red: 0.157, green: 0.196, blue: 0.137).opacity(0.45), lineWidth: 6 * s)
                    .blur(radius: 5 * s)
                    .offset(y: 2 * s)
                    .mask(RoundedRectangle(cornerRadius: 10 * s))
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .white.opacity(0.25), location: 0),
                        .init(color: .white.opacity(0), location: 0.3),
                    ]),
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
                .mask(RoundedRectangle(cornerRadius: 10 * s))
            }
            .frame(width: 246 * s, height: 208 * s)
        }
        .frame(width: 286 * s, height: 250 * s)
        .onChange(of: renderer.shader) { _, shader in
            // Nothing else may ever repaint this screen; the skin is
            // the presentation. Reasserted rather than assumed so a
            // future shared-code change surfaces here as a visible
            // revert, not a silent one.
            if shader != .vmuLCD { renderer.shader = .vmuLCD }
        }
        .onAppear { renderer.shader = .vmuLCD }
    }
}

/// The sleep animation: the 48x32 1-bit frames stamped beside the mock
/// (a pixel Cabinet low in the frame, two z's rising one at a time,
/// 600ms cadence), drawn as chunky ink pixels over the face, ink at
/// 0.15 x paper exactly like the shader's live picture.
private struct VMUSleepScreen: View {
    let frame: Int
    let s: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let bits = VMUSleepFrames.frames[safe: frame] else { return }
            let px = size.width / 48
            let py = size.height / 32
            for y in 0..<32 {
                // The shader's own paper math at this row, so the sleep
                // screen and the live picture are one surface.
                let faceY = 0.1154 + (0.8846 - 0.1154) * (Double(y) + 0.5) / 32
                let paper = (
                    r: 0.765 + (0.702 - 0.765) * faceY,
                    g: 0.804 + (0.749 - 0.804) * faceY,
                    b: 0.706 + (0.651 - 0.706) * faceY
                )
                let ink = Color(red: paper.r * 0.15, green: paper.g * 0.15, blue: paper.b * 0.15)
                for x in 0..<48 where bits[y * 48 + x] {
                    context.fill(
                        Path(CGRect(x: CGFloat(x) * px, y: CGFloat(y) * py, width: px + 0.5, height: py + 0.5)),
                        with: .color(ink)
                    )
                }
            }
        }
    }
}

/// The stamped frames decoded once: sleep0 is the cabinet alone, sleep1
/// adds the small z, sleep2 both z's, the exact trio the approved mock
/// cycles. True means ink.
enum VMUSleepFrames {
    static let frames: [[Bool]] = (0..<3).compactMap { decode("sleep\($0)") }

    private static func decode(_ name: String) -> [Bool]? {
        guard let cg = UIImage(named: name)?.cgImage, cg.width == 48, cg.height == 32 else { return nil }
        // The context stays a live local until after the reads: its
        // `data` pointer is into storage the context owns, and reading
        // it past the context's life was a real crash, found in the
        // simulator skin bench before this ever reached a device.
        guard let ctx = CGContext(
            data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 48 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 48, height: 32))
        guard let data = ctx.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        return (0..<(48 * 32)).map { i in
            // Ink is dark: the PNGs are black marks on white.
            pixels[i * 4] < 128
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
