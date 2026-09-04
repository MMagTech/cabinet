//  Gets a GameCube game onto disk and answers whether one is playable
//  at all.
//
//  Deliberately not part of NativeLauncher, for the same reason
//  PS2Launcher is not. That file resolves a NativePlatform to a libretro
//  NativeCore and hands the result to LibretroFrontend, and GameCube has
//  none of those things: no libretro core, no NativePlatform case, no
//  frontend.
//
//  Simpler than PS2's in one real way: there is no firmware step.
//  Dolphin boots a GameCube disc with its own HLE IPL, so unlike PS2
//  there is nothing to fetch from RomM before a game will start and no
//  "add a BIOS" failure to explain to anybody.
//
//  Mac only, permanently. Dolphin needs a recompiler and only macOS
//  grants one, the same JIT boundary that keeps Dreamcast, N64 and PSP
//  on interpreters everywhere else.

import Foundation

enum GCLauncher {
    enum Failure: LocalizedError {
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name):
                return "Cabinet can play .iso, .gcm, .rvz, .ciso and .gcz GameCube discs, not \"\(name)\"."
            }
        }
    }

    /// The disc formats Dolphin's DiscIO opens. Named here rather than
    /// passed through blindly so an unsupported file fails with a
    /// sentence instead of Dolphin refusing to boot for no stated
    /// reason.
    private static let formats = ["iso", "gcm", "rvz", "ciso", "gcz"]

    /// RomM's own slug for the platform. Kept next to the launcher
    /// rather than in NativeCore's resolver, which only answers for
    /// platforms that have a libretro core behind them.
    static func isGameCube(canonicalSlug: String) -> Bool {
        canonicalSlug == "ngc" || canonicalSlug == "gc" || canonicalSlug == "gamecube"
    }

    /// Downloads the disc if it is not already on this Mac and returns
    /// the path to hand Dolphin.
    static func prepare(
        rom: Rom, session: Session, onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> String {
        let name = rom.fsName.lowercased()
        guard !rom.hasMultipleFiles,
              formats.contains(where: { name.hasSuffix(".\($0)") })
        else {
            throw Failure.unsupportedFormat(rom.fsName)
        }

        // A game Cabinet already downloaded is used where it lies.
        // Without this a kept game is fetched a second time into a
        // second folder, which on this platform means gigabytes
        // duplicated on disk and a download the person watching has
        // every reason to think should not be happening. Same check
        // NativeLauncher and PS2Launcher each make before their own.
        // KeptGameStore is main-actor isolated, so the lookup hops
        // there rather than the whole prepare becoming main-actor work:
        // the download below must not run on the main thread.
        let keptDirectory = await MainActor.run { KeptGameStore.shared.launchDirectory(romId: rom.id) }
        if let keptDir = keptDirectory {
            let kept = keptDir.appending(path: rom.fsName)
            if FileManager.default.fileExists(atPath: kept.path) {
                return kept.path
            }
        }

        // Otherwise a copy of our own, kept rather than fetched per
        // launch: a GameCube disc is over a gigabyte, and
        // re-downloading Wind Waker to play it twice is not something
        // to do to a household network.
        let gamesDir = GCPlayer.dataRoot.appending(path: "discs")
        try FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        let discURL = gamesDir.appending(path: rom.fsName)
        if !FileManager.default.fileExists(atPath: discURL.path) {
            try await download(session.romContentRequest(rom), to: discURL, onProgress: onProgress)
        }

        return discURL.path
    }

    private static func download(
        _ request: URLRequest, to url: URL,
        onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws {
        let delegate = ProgressDelegate(onProgress: onProgress)
        let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { urlSession.finishTasksAndInvalidate() }
        let (tempURL, response) = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { continuation.resume(with: $0) }
            urlSession.downloadTask(with: request).resume()
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: "GCLauncher", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"]
            )
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    /// The temp file is only guaranteed to exist for the duration of
    /// the callback, so it is staged synchronously before the checked
    /// continuation resumes. Same constraint NativeLauncher, PS2Launcher
    /// and RomExporter each document for their own copy of this.
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate {
        private let onProgress: @MainActor (Double) -> Void
        var completion: ((Result<(URL, URLResponse), Error>) -> Void)?

        init(onProgress: @escaping @MainActor (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            let onProgress = onProgress
            Task { @MainActor in onProgress(fraction) }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            let staged = FileManager.default.temporaryDirectory
                .appending(path: "gc-download-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: staged)
            } catch {
                completion?(.failure(error))
                return
            }
            completion?(.success((staged, downloadTask.response ?? URLResponse())))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { completion?(.failure(error)) }
        }
    }
}
