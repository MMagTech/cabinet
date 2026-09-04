//  Runs a PS2 game, and holds what the screen needs to show while it does.
//
//  PCSX2 is not driven a frame at a time the way a libretro core is.
//  CabinetPS2Run boots the disc and does not return until the game
//  stops, so it gets a thread of its own and everything else here is
//  about talking to it from the main one.
//
//  Mac only, deliberately and permanently. See CabinetPS2Bridge.h.

import Foundation
import Observation

@Observable
@MainActor
final class PS2Player {
    enum State: Equatable {
        case idle
        case running
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The pause panel. Owned here rather than by the view because the
    /// emulator has to be paused in step with it.
    var menuVisible = false
    var menuSelection = 0
    var menuUsingController = false
    private(set) var fps: Float = 0
    private(set) var speed: Float = 0
    private(set) var eeUsage: Float = 0
    private(set) var gsUsage: Float = 0

    private var metricsTimer: Timer?

    /// Where PCSX2 keeps the BIOS, memory cards, save states and its
    /// cache. Under Cabinet's own folder rather than PCSX2's, so that
    /// nothing here collides with a real PCSX2 install on the same Mac.
    nonisolated static var dataRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "Cabinet/PS2")
    }

    /// PCSX2's own resources, bundled with the app. It refuses to start
    /// without them: the game database, the fonts its overlay needs,
    /// and the Metal shader libraries all live here.
    /// resourcePath, not bundlePath. On iOS those are the same folder,
    /// which is why the PSP core can use the bundle root, but a
    /// Catalyst app is a real macOS bundle and its resources sit in
    /// Contents/Resources.
    nonisolated static var resourcesPath: String {
        (Bundle.main.resourcePath ?? Bundle.main.bundlePath) + "/PCSX2Resources"
    }

    func start(discPath: String, cardFileName: String?, view: UnsafeMutableRawPointer) {
        guard state != .running else { return }

        let dataRoot = Self.dataRoot
        try? FileManager.default.createDirectory(at: dataRoot.appending(path: "bios"),
                                                 withIntermediateDirectories: true)

        state = .running
        startMetrics()
        PS2Controls.attach(onMenu: { [weak self] in self?.toggleMenu() })

        Thread.detachNewThread { [weak self] in
            var error = [CChar](repeating: 0, count: 512)
            var ok = false

            discPath.withCString { disc in
                dataRoot.path.withCString { data in
                    Self.resourcesPath.withCString { resources in
                        (cardFileName ?? "").withCString { card in
                            var config = CabinetPS2Config(
                                disc_path: disc,
                                data_root: data,
                                resources_dir: resources,
                                memory_card: card,
                                view: view,
                                fast_boot: true,
                                verbose_log: true
                            )
                            ok = CabinetPS2Run(&config, &error, error.count)
                        }
                    }
                }
            }

            let message = ok ? "" : String(cString: error)
            Task { @MainActor in
                PS2Controls.detach()
                self?.stopMetrics()
                self?.state = ok ? .idle : .failed(message.isEmpty ? "PS2 failed to start." : message)
            }
        }
    }

    func toggleMenu() {
        setMenu(!menuVisible)
    }

    func setMenu(_ visible: Bool) {
        guard menuVisible != visible else { return }
        menuVisible = visible
        menuSelection = 0
        menuUsingController = false
        CabinetPS2SetPaused(visible)
    }

    func stop() {
        // Controls first. Pad::SetControllerState dereferences the pad
        // without a null check, and shutdown destroys the pads, so a
        // button released during teardown would otherwise land on
        // freed memory.
        PS2Controls.detach()
        CabinetPS2RequestStop()
    }

    private func startMetrics() {
        metricsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let m = CabinetPS2GetMetrics()
            self?.fps = m.fps
            self?.speed = m.speed
            self?.eeUsage = m.ee_usage
            self?.gsUsage = m.gs_usage
        }
    }

    private func stopMetrics() {
        metricsTimer?.invalidate()
        metricsTimer = nil
    }
}
