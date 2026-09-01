//  Gets a PS2 game onto disk and answers whether one is playable at all.
//
//  Deliberately not part of NativeLauncher. That file resolves a
//  NativePlatform to a libretro NativeCore and hands the result to
//  LibretroFrontend, and PS2 has none of those things: no libretro
//  core, no NativePlatform case, no frontend. Bending it to carry PS2
//  would mean a PS2-shaped branch in the file every one of the other
//  twenty-three cores launches through, for no shared behaviour. The
//  download shape is copied rather than called for the same reason:
//  the helper it would reuse is private to that class, and a fifty-line
//  duplicate is cheaper than widening its surface for one caller.
//
//  Mac only, permanently. PCSX2 needs a recompiler and only macOS
//  grants one, which is the same JIT boundary that keeps Dreamcast,
//  N64 and PSP on interpreters everywhere else.

import Foundation

enum PS2Launcher {
    enum Failure: LocalizedError {
        case unsupportedFormat(String)
        case noBios

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let name):
                return "Only .chd and .iso are supported for PS2 right now, not \"\(name)\"."
            case .noBios:
                return "No PS2 BIOS. Add one to RomM as firmware for the PlayStation 2 platform."
            }
        }
    }

    /// RomM's own slug for the platform. Kept next to the launcher
    /// rather than in NativeCore's resolver, which only answers for
    /// platforms that have a libretro core behind them.
    static func isPS2(canonicalSlug: String) -> Bool {
        canonicalSlug == "ps2"
    }

    /// Downloads the disc and, if it is not already there, the BIOS.
    /// Returns the path to hand PCSX2.
    static func prepare(
        rom: Rom, session: Session, onProgress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> String {
        let name = rom.fsName.lowercased()
        guard !rom.hasMultipleFiles, name.hasSuffix(".chd") || name.hasSuffix(".iso") else {
            throw Failure.unsupportedFormat(rom.fsName)
        }

        let biosDir = PS2Player.dataRoot.appending(path: "bios")
        try FileManager.default.createDirectory(at: biosDir, withIntermediateDirectories: true)

        // The BIOS is fetched once and kept. It is the same few
        // megabytes for every PS2 game, so re-downloading it per launch
        // would be pure waste, and keeping it is what lets a second
        // game start with no network at all.
        if try isBiosFolderEmpty(biosDir) {
            var got = false
            if let firmwareList = try? await session.firmware(platformId: rom.platformId) {
                for firmware in firmwareList where !firmware.missingFromFS {
                    let url = biosDir.appending(path: firmware.fileName)
                    if (try? await download(session.firmwareContentRequest(firmware), to: url)) != nil {
                        got = true
                    }
                }
            }
            guard got else { throw Failure.noBios }
        }

        // Discs are kept too, and for a blunter reason than the BIOS:
        // a PS2 game is gigabytes, and re-downloading Killzone to play
        // it twice is not something to do to a household network.
        let gamesDir = PS2Player.dataRoot.appending(path: "games")
        try FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)
        let discURL = gamesDir.appending(path: rom.fsName)
        if !FileManager.default.fileExists(atPath: discURL.path) {
            try await download(session.romContentRequest(rom), to: discURL, onProgress: onProgress)
        }

        return discURL.path
    }

    private static func isBiosFolderEmpty(_ dir: URL) throws -> Bool {
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        return contents.filter { !$0.hasPrefix(".") }.isEmpty
    }

    private static func download(
        _ request: URLRequest, to url: URL, onProgress: @escaping @MainActor (Double) -> Void = { _ in }
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
                domain: "PS2Launcher", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"]
            )
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tempURL, to: url)
    }

    /// The temp file is only guaranteed to exist for the duration of
    /// the callback, so it is staged synchronously before the checked
    /// continuation resumes. Same constraint NativeLauncher and
    /// RomExporter each document for their own copy of this.
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
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
        ) {
            let staged = FileManager.default.temporaryDirectory
                .appending(path: "ps2-download-\(UUID().uuidString)")
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
