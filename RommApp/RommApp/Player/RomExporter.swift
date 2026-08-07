import SwiftUI
import UIKit

/// Downloads a ROM (and optionally its BIOS) straight from RomM and hands
/// the result to the Files app, for platforms this app cannot play itself
/// and for anyone who wants a copy for another emulator.
///
/// Deliberately does not check EmulatorJS's own IndexedDB cache first: that
/// would mean moving potentially hundreds of megabytes across a
/// WKScriptMessageHandler bridge, which EmulatorJS itself avoids by
/// chunking at 50MB internally. A plain re-download from the server is
/// simpler and, since export is a one-off action per game rather than a
/// repeated one, the cost of skipping that optimization is small.
@MainActor
final class RomExporter: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Set once every requested file has downloaded, holding the folder
    /// (multi-file exports) or single file ready to hand to the document
    /// picker. Cleared once the picker is dismissed.
    @Published var exportURLs: [URL]?

    private var session: URLSession?
    private var pendingFiles: [(request: URLRequest, suggestedName: String)] = []
    private var completedURLs: [URL] = []
    private var workDirectory: URL?
    /// Where the in-flight download task should land once it finishes,
    /// read from `urlSession(_:downloadTask:didFinishDownloadingTo:)`.
    ///
    /// That delegate callback runs on a background queue and must move the
    /// temp file *before returning*: iOS deletes it the instant the
    /// callback returns, so deferring the move to a `Task { @MainActor }`
    /// loses the race and the file is gone by the time the hop runs. A
    /// plain `@MainActor` stored property can't be read synchronously from
    /// that background thread, hence the lock rather than the actor.
    private let destinationLock = NSLock()
    private nonisolated(unsafe) var pendingDestination: URL?
    /// Set when exporting a multi-file ROM: files save into this subfolder
    /// instead of directly into `workDirectory`, and the final export is
    /// the folder itself, not each loose file, so Files sees one item.
    private var folderName: String?

    /// - Parameters:
    ///   - files: one request per file to fetch, each with the filename it
    ///     should be saved under.
    ///   - folderName: non-nil for a multi-file ROM, where RomM's own zip
    ///     endpoint is known broken through the reverse proxy (scope doc,
    ///     Open items), so files are fetched individually instead and
    ///     exported as a folder RetroArch can read directly.
    func start(files: [(request: URLRequest, suggestedName: String)], folderName: String? = nil) {
        guard case .idle = state else { return }
        pendingFiles = files
        completedURLs = []
        self.folderName = folderName
        state = .downloading(fraction: 0, receivedBytes: 0, totalBytes: 0)

        let config = URLSessionConfiguration.default
        let delegateSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = delegateSession

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        let saveDirectory = folderName.map { directory.appendingPathComponent($0, isDirectory: true) } ?? directory
        try? FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        workDirectory = directory

        downloadNext()
    }

    /// Hands files that are already on this phone straight to the picker,
    /// no download and no temp copy: the picker exports `asCopy`, so the
    /// originals, a kept game's among them, are read and left in place.
    func presentLocal(urls: [URL]) {
        guard case .idle = state else { return }
        exportURLs = urls
    }

    /// Reports a failure that happened before any network request could be
    /// started, building the request itself among them.
    func fail(_ message: String) {
        state = .failed(message)
    }

    func cancel() {
        session?.invalidateAndCancel()
        reset()
    }

    /// Called once the document picker has been presented and dismissed, so
    /// a later export starts clean.
    func finishExport() {
        exportURLs = nil
        reset()
    }

    private func reset() {
        state = .idle
        pendingFiles = []
        completedURLs = []
        destinationLock.lock()
        pendingDestination = nil
        destinationLock.unlock()
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
        workDirectory = nil
        folderName = nil
        session = nil
    }

    /// Where a completed file actually gets written: the plain work
    /// directory for a single-file export, or a named subfolder for a
    /// multi-file one, so Files sees one folder rather than loose parts.
    private var saveDirectory: URL? {
        guard let workDirectory else { return nil }
        guard let folderName else { return workDirectory }
        return workDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    private func downloadNext() {
        guard let next = pendingFiles.first else {
            if let folderName, let workDirectory {
                exportURLs = [workDirectory.appendingPathComponent(folderName, isDirectory: true)]
            } else {
                exportURLs = completedURLs
            }
            state = .idle
            return
        }
        destinationLock.lock()
        pendingDestination = saveDirectory?.appendingPathComponent(next.suggestedName)
        destinationLock.unlock()
        session?.downloadTask(with: next.request).resume()
    }
}

extension RomExporter: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            let fraction = totalBytesExpectedToWrite > 0
                ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            self.state = .downloading(
                fraction: fraction, receivedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        guard let response = downloadTask.response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
            Task { @MainActor in
                self.state = .failed(
                    status.map { "The server returned an error (\($0))." }
                        ?? "The download failed."
                )
            }
            return
        }

        // Move synchronously, on this callback's own thread, before it is
        // allowed to return: `location` is only guaranteed to exist for the
        // duration of this call.
        destinationLock.lock()
        let destination = pendingDestination
        destinationLock.unlock()

        guard let destination else {
            Task { @MainActor in self.state = .failed("Couldn't save the downloaded file.") }
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in self.state = .failed("Couldn't save the downloaded file.") }
            return
        }

        Task { @MainActor in
            self.completedURLs.append(destination)
            if !self.pendingFiles.isEmpty { self.pendingFiles.removeFirst() }
            self.downloadNext()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        Task { @MainActor in
            self.state = .failed("The connection dropped partway through.")
        }
    }
}

/// Presents the Files export sheet for one or more already-downloaded
/// local files.
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onDismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss()
        }
    }
}
