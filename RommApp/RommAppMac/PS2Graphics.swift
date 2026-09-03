//  The picture settings the PS2 pause panel offers.
//
//  Minimal on purpose, the same rule the other cores' settings follow:
//  the most impactful options, not everything PCSX2 exposes. All four
//  are things you judge by eye, which is why they live in the pause
//  panel rather than on the launch screen. That split is the native
//  player's own rule, from macPauseMenu: a setting you judge by looking
//  at the picture cannot live on a screen where the picture is gone.
//
//  Values are source-exact, taken from PCSX2 rather than retyped:
//  the shader list is GS.cpp's own, the aspect names are
//  Pcsx2Config's AspectRatioNames verbatim.
//
//  NO WIDESCREEN HACKS. Marcus's call: PS2 games are played as they
//  shipped. The aspect row is for the titles that genuinely offered
//  widescreen, which need only the ratio set and their own in-game
//  option turned on. PCSX2's per-game widescreen patches are
//  deliberately not wired, and patches.zip is deliberately not
//  bundled.

import Foundation
import SwiftUI

enum PS2Graphics {
    struct Shader: Identifiable, Equatable {
        let index: Int
        let label: String
        var id: Int { index }
    }

    /// PCSX2's TVShader order, source-exact.
    ///
    /// These needed fixing before they were worth offering. They mask
    /// alternate OUTPUT rows, which was right when output was near the
    /// PS2's own 640x448 and is invisible at 2880 tall. The scanline
    /// family is patched to follow the SOURCE resolution instead, so a
    /// scanline stays one source line thick whatever the window size.
    /// See tools/patch-pcsx2-mac.py. Wave needed no patch: it already
    /// worked in source texture space.
    ///
    /// Lottes CRT is deliberately absent. It is a full CRT model whose
    /// constants assume that old ratio, and at this size it crushes the
    /// picture to black with nothing reporting a fault.
    static let shaders: [Shader] = [
        Shader(index: 0, label: "None"),
        Shader(index: 1, label: "Scanlines"),
        Shader(index: 2, label: "Diagonal"),
        Shader(index: 3, label: "Triangular"),
        Shader(index: 4, label: "Wave"),
    ]

    @AppStorage("ps2-shader") static var shaderIndex: Int = 0

    static func shaderLabel(_ index: Int) -> String {
        shaders.first { $0.index == index }?.label ?? "None"
    }

    /// Stretch is missing deliberately: it distorts the picture, which
    /// is the opposite of playing a game as it shipped.
    static let aspects: [String] = ["Auto 4:3/3:2", "4:3", "16:9"]

    static let blendingLabels: [String] = [
        "Minimum", "Basic", "Medium", "High", "Full", "Maximum",
    ]

    static let upscales: [(value: Float, label: String)] = [
        (1.0, "Native"), (2.0, "2x"), (3.0, "3x"), (4.0, "4x"),
    ]

    // MARK: - What is remembered, and at what scope

    /// Per game, because whether a title is widescreen is a fact about
    /// the title, not a preference.
    static func aspect(romId: Int?) -> String {
        guard let romId else { return aspects[0] }
        return UserDefaults.standard.string(forKey: "ps2-aspect-\(romId)") ?? aspects[0]
    }

    static func setAspect(_ value: String, romId: Int?) {
        guard let romId else { return }
        UserDefaults.standard.set(value, forKey: "ps2-aspect-\(romId)")
    }

    /// Machine-wide, because these are facts about how much headroom
    /// this Mac has, not about any one game.
    @AppStorage("ps2-blending") static var blending: Int = 1
    @AppStorage("ps2-upscale") static var upscale: Double = 1.0

    /// Diagnostic, no UI.
    @AppStorage("ps2-deinterlace") static var deinterlace: Int = -1

    /// PCSX2's GSRendererType values, source-exact.
    ///
    /// Not a preference: some PS2 games draw nothing at all on the
    /// hardware renderer and are perfect on the software one. Mobile
    /// Light Force 2 is one, verified 2026-08-31, and it presents as a
    /// black screen with working audio, which looks like a broken app
    /// rather than a game needing a different renderer. Upstream
    /// PCSX2 has this picker for the same reason.
    ///
    /// Software costs speed, which on this machine there is plenty of:
    /// PS2 runs at 100% with the EE under a quarter loaded.
    /// Labelled as a remedy rather than a preference, because that is
    /// what it is. Someone whose screen is black has exactly one thing
    /// they can do, open this panel, and nothing else in the app can
    /// tell them a renderer is the answer.
    static let renderers: [(value: Int, label: String)] = [
        (17, "Hardware"),
        (13, "Software (fixes black screens)"),
    ]

    /// Per game, because it is a fact about the title's compatibility
    /// rather than a preference about this Mac.
    static func renderer(romId: Int?) -> Int {
        // Harness only: -cabinetPS2Renderer 13 boots a disc on the
        // software renderer, which a command-line run otherwise
        // cannot reach because it has no RomM id to store one under.
        if UserDefaults.standard.object(forKey: "cabinetPS2Renderer") != nil {
            return UserDefaults.standard.integer(forKey: "cabinetPS2Renderer")
        }
        guard let romId else { return 17 }
        let stored = UserDefaults.standard.object(forKey: "ps2-renderer-\(romId)") as? Int
        return stored ?? 17
    }

    static func setRenderer(_ value: Int, romId: Int?) {
        guard let romId else { return }
        UserDefaults.standard.set(value, forKey: "ps2-renderer-\(romId)")
    }

    static func rendererLabel(_ value: Int) -> String {
        renderers.first { $0.value == value }?.label ?? "Hardware"
    }

    static func upscaleLabel(_ value: Double) -> String {
        upscales.first { Double($0.value) == value }?.label ?? "Native"
    }

    // MARK: - Not letting one bad setting poison every launch

    /// Set while a game is running with these settings, cleared when
    /// the player is left normally.
    ///
    /// If it is still set at the next launch, the last session did not
    /// end cleanly, and the settings that were live are the prime
    /// suspect. They go back to defaults rather than being applied
    /// again. This is the MAME cfg lesson: a bad value that reapplies
    /// itself forever turns one mistake into a permanently broken
    /// platform, and the only way out is knowing to delete a file
    /// nobody told you about.
    ///
    /// Aspect is deliberately spared. It is per game, chosen because a
    /// title is widescreen, and it is the least likely of the four to
    /// break a picture.
    private static let pendingKey = "ps2-graphics-session-open"

    /// True when the last session ended badly and settings were reset.
    @discardableResult
    static func recoverIfLastSessionFailed() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingKey) else { return false }

        UserDefaults.standard.removeObject(forKey: "ps2-shader")
        UserDefaults.standard.removeObject(forKey: "ps2-blending")
        UserDefaults.standard.removeObject(forKey: "ps2-upscale")
        UserDefaults.standard.set(false, forKey: pendingKey)
        return true
    }

    static func markSessionOpen() {
        UserDefaults.standard.set(true, forKey: pendingKey)
    }

    static func markSessionClosed() {
        UserDefaults.standard.set(false, forKey: pendingKey)
    }

    /// Pushes the current choices at PCSX2. Safe before a game starts,
    /// where it simply decides what the game boots with.
    static func apply(romId: Int?) {
        aspect(romId: romId).withCString { aspectName in
            var graphics = CabinetPS2Graphics(
                tv_shader: Int32(shaderIndex),
                aspect: aspectName,
                blending: Int32(blending),
                upscale: Float(upscale),
                renderer: Int32(renderer(romId: romId)),
                deinterlace: Int32(deinterlace)
            )
            CabinetPS2SetGraphics(&graphics)
        }
    }
}
