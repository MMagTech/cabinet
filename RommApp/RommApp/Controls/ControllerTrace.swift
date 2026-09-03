import Foundation
import GameController
import UIKit

/// Temporary trace for a Bluetooth pad that stops responding mid-game and
/// recovers, reported on the Mac 2026-09-02 with the game itself running
/// on. The game running on rules out the app's own thread; what is left
/// is the link between the pad and the GameController framework, and the
/// only way to see that is a timestamp on every edge that does arrive.
///
/// One line per button edge and per connect or disconnect, and one
/// heartbeat a second carrying the count of controllers the framework
/// still lists and whether the app is frontmost, which is the other thing
/// that silences a pad on the Mac. A dropout then reads as one of three
/// shapes: a disconnect and a reconnect (the link fell over), a gap with
/// a burst of stale edges after it (the radio went away and the packets
/// queued), or a gap with nothing after it and the app not frontmost.
///
/// Mac only, opt-in; the cost is one short string per edge on a
/// utility queue. File: ~/Library/Caches/Cabinet/controller-trace.log,
/// truncated at each launch. Delete this file and its four call sites in
/// GameControllerManager together once the dropout is understood.
final class ControllerTrace {
    static let shared = ControllerTrace()

    /// Opt in with `-cabinetControllerTrace 1` on the Mac; off otherwise.
    /// It was always on for the day it earned its keep and must not ship
    /// that way: a trace of every button press is a debugging tool.
    #if targetEnvironment(macCatalyst)
    private let enabled = UserDefaults.standard.bool(forKey: "cabinetControllerTrace")
    #else
    private let enabled = false
    #endif

    private let queue = DispatchQueue(label: "cabinet.controllertrace", qos: .utility)
    private var handle: FileHandle?
    private var started: CFAbsoluteTime = 0
    private var edgesThisSecond = 0
    private var heartbeat: DispatchSourceTimer?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cabinet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("controller-trace.log")
    }

    func begin() {
        guard enabled, heartbeat == nil else { return }
        started = CFAbsoluteTimeGetCurrent()
        queue.async {
            try? FileManager.default.removeItem(at: self.fileURL)
            FileManager.default.createFile(atPath: self.fileURL.path, contents: nil)
            self.handle = try? FileHandle(forWritingTo: self.fileURL)
            self.write("# controller trace, started \(Date())")
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        heartbeat = timer
    }

    func connect(_ controller: GCController, slot: Int) {
        guard enabled else { return }
        log("connect slot=\(slot) name=\(controller.vendorName ?? "?") category=\(controller.productCategory)")
    }

    func disconnect(_ controller: GCController?, slot: Int) {
        guard enabled else { return }
        log("DISCONNECT slot=\(slot) name=\(controller?.vendorName ?? "nil")")
    }

    func edge(_ id: Int, down: Bool, player: Int) {
        guard enabled else { return }
        edgesThisSecond += 1
        log("edge p\(player) id=\(id) \(down ? "down" : "up")")
    }

    private func tick() {
        let count = GCController.controllers().count
        let active = UIApplication.shared.applicationState == .active
        log("beat controllers=\(count) active=\(active) edges=\(edgesThisSecond)")
        edgesThisSecond = 0
    }

    private func log(_ line: String) {
        let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let stamp = String(format: "%8d ", ms)
        queue.async { self.write(stamp + line) }
    }

    private func write(_ line: String) {
        handle?.write(Data((line + "\n").utf8))
    }
}
