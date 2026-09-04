//  The phone's ROM transfers, carried by the system rather than the app.
//
//  A download that dies when the screen locks is no way to bring down a
//  platform, so on iOS every kept game's ROM comes through one background
//  URLSession. Apple's page for background(withIdentifier:): the transfers
//  run "in a separate process", and "continue even when the app itself is
//  suspended or terminated"; if the system terminates the app, it is
//  relaunched to collect the results. Two more lines from the same
//  documentation shape everything here. waitsForConnectivity "is ignored
//  by background sessions, which always wait for connectivity", which is
//  what makes a Wi-Fi-only request wait for Wi-Fi instead of failing on
//  cellular. And a task's finished file "only exists for the duration of"
//  the delegate callback, so it is moved on the spot into a landing
//  folder the store reads from later, whichever launch of the app that
//  turns out to be.
//
//  Only the ROM goes through here. Firmware, the newest state and the
//  in-game save are small and fetched by the store as it always has,
//  right after the ROM lands.

#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import UIKit

final class BackgroundDownloads: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloads()
    /// The session's identifier, which is also how the app delegate
    /// recognises a relaunch for its events. Never changes: a different
    /// string would orphan every transfer in flight at an update.
    static let identifier = "com.mmagtech.RommApp.keptGames"

    private let lock = NSLock()
    /// Every transfer this launch knows about, by rom id: started here,
    /// or found still running when the session was reattached.
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var continuations: [Int: CheckedContinuation<String?, Error>] = [:]
    /// A bad status or a failed move, carried from the finish callback to
    /// the completion one, where the waiting caller is answered.
    private var failures: [Int: Error] = [:]
    private var reattaching: Task<Void, Never>?
    /// Handed over by the app delegate when the system relaunched the app
    /// for this session's events, and called back once they are delivered.
    var eventsCompletionHandler: (() -> Void)?

    /// Where a finished ROM waits for the store, next to the kept games
    /// themselves: Application Support/KeptGames/landed/<romId>, with
    /// the response's Content-Length beside it as <romId>.length, since
    /// the web player's cache validates on that exact string.
    private let landingRoot: URL

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        // The same rule RommClient applies to every request: RomM sends
        // no Cache-Control, and a stale body served from cache would be
        // a stale ROM.
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A person tapped Download and expects to watch it go, not to
        // have the system wait for a charger.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        landingRoot = support
            .appendingPathComponent("KeptGames", isDirectory: true)
            .appendingPathComponent("landed", isDirectory: true)
        try? FileManager.default.createDirectory(at: landingRoot, withIntermediateDirectories: true)
        super.init()
    }

    // MARK: Launch

    /// Creates the session and learns which transfers are still running,
    /// so a queue started in a previous launch is picked up rather than
    /// started twice. Called at launch by the app delegate; every other
    /// entry point waits on it.
    func prepare() {
        _ = reattach()
    }

    @discardableResult
    private func reattach() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let reattaching { return reattaching }
        let session = self.session
        let task = Task { [weak self] in
            let all = await session.allTasks
            guard let self else { return }
            self.lock.lock()
            for case let task as URLSessionDownloadTask in all
            where task.state == .running || task.state == .suspended {
                if let romId = Self.romId(of: task) { self.tasks[romId] = task }
            }
            self.lock.unlock()
        }
        reattaching = task
        return task
    }

    // MARK: Transfers

    func landingURL(romId: Int) -> URL {
        landingRoot.appendingPathComponent(String(romId))
    }

    private func lengthURL(romId: Int) -> URL {
        landingRoot.appendingPathComponent("\(romId).length")
    }

    /// The finished ROM for a game, if its transfer completed, in this
    /// launch or an earlier one.
    func landed(romId: Int) -> (file: URL, contentLength: String?)? {
        let file = landingURL(romId: romId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let length = try? String(contentsOf: lengthURL(romId: romId), encoding: .utf8)
        return (file, length)
    }

    /// Forgets a landed ROM once the store has made it a kept game, or
    /// when the game is removed.
    func clearLanded(romId: Int) {
        try? FileManager.default.removeItem(at: landingURL(romId: romId))
        try? FileManager.default.removeItem(at: lengthURL(romId: romId))
    }

    /// Starts a transfer unless one is already running or already
    /// finished. Download All calls this for the whole platform up front,
    /// so the system works through the list while the app sleeps, then
    /// the store's queue awaits each one in turn.
    func enqueue(_ request: URLRequest, romId: Int, wifiOnly: Bool) async {
        await reattach().value
        lock.lock()
        defer { lock.unlock() }
        guard tasks[romId] == nil, landed(romId: romId) == nil else { return }
        var request = request
        request.allowsCellularAccess = !wifiOnly
        let task = session.downloadTask(with: request)
        task.taskDescription = "rom.\(romId)"
        tasks[romId] = task
        task.resume()
    }

    /// Waits for a game's ROM to land, starting the transfer if nothing
    /// has. Returns the response's Content-Length header, as the
    /// store's foreground downloader does.
    func download(_ request: URLRequest, romId: Int, wifiOnly: Bool) async throws -> String? {
        await enqueue(request, romId: romId, wifiOnly: wifiOnly)
        if let landed = landed(romId: romId) { return landed.contentLength }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                lock.lock()
                // The transfer may have finished between the checks above
                // and here: a small file on the local network is quick.
                if let landed = landed(romId: romId) {
                    lock.unlock()
                    continuation.resume(returning: landed.contentLength)
                    return
                }
                guard tasks[romId] != nil else {
                    let failure = failures.removeValue(forKey: romId)
                    lock.unlock()
                    continuation.resume(throwing: failure ?? Self.error("The download didn't start."))
                    return
                }
                continuations[romId] = continuation
                lock.unlock()
            }
        } onCancel: {
            cancel(romId: romId)
        }
    }

    /// Stops a transfer and forgets anything it landed.
    func cancel(romId: Int) {
        lock.lock()
        let task = tasks[romId]
        lock.unlock()
        task?.cancel()
        clearLanded(romId: romId)
    }

    private static func romId(of task: URLSessionTask) -> Int? {
        guard let description = task.taskDescription, description.hasPrefix("rom.") else { return nil }
        return Int(description.dropFirst("rom.".count))
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "KeptGames", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let romId = Self.romId(of: downloadTask) else { return }
        Task { @MainActor in
            KeptGameStore.shared.reportTransfer(romId: romId, received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let romId = Self.romId(of: downloadTask) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        if let status = response?.statusCode, !(200...299).contains(status) {
            lock.lock()
            failures[romId] = Self.error("HTTP \(status) for rom \(romId)")
            lock.unlock()
            return
        }
        do {
            let destination = landingURL(romId: romId)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            if let length = response?.value(forHTTPHeaderField: "Content-Length") {
                try? length.write(to: lengthURL(romId: romId), atomically: true, encoding: .utf8)
            }
        } catch {
            lock.lock()
            failures[romId] = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let romId = Self.romId(of: task) else { return }
        lock.lock()
        if tasks[romId] === task { tasks[romId] = nil }
        let continuation = continuations.removeValue(forKey: romId)
        let failure = failures.removeValue(forKey: romId)
        lock.unlock()
        guard let continuation else { return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                continuation.resume(throwing: error)
            }
        } else if let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume(returning: landed(romId: romId)?.contentLength)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.eventsCompletionHandler?()
            self?.eventsCompletionHandler = nil
        }
    }
}
#endif
