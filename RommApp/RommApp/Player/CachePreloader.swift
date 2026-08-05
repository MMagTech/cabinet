import Foundation

/// Fetches a ROM into memory and hands it to `EmulatorCacheBridge` to
/// write into EmulatorJS's own on-device cache, "Data Saver": unlike
/// `RomExporter`, nothing goes to Files, the whole point is a later real
/// play session finding the game already cached and skipping the network
/// entirely for weak-signal launches.
///
/// A separate, small class rather than a mode on `RomExporter`: that one
/// streams straight to disk through a download-task delegate, this one has
/// to hold the whole file in memory to hand it to the cache bridge as
/// bytes, different enough machinery that forcing them into one class
/// would blur both.
@MainActor
final class CachePreloader: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(fraction: Double, receivedBytes: Int64, totalBytes: Int64)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// The raw `Content-Length` header string from the response that
    /// produced the last successful fetch. EmulatorJS validates a cached
    /// entry by strictly comparing its stored `content-length` string to
    /// a live HEAD response's header, so the cache write needs the exact
    /// header string, not a recomputed byte count.
    private(set) var contentLengthHeader: String?

    private var session: URLSession?
    private var buffer = Data()
    private var expectedBytes: Int64 = 0
    private var completion: ((Data?) -> Void)?

    /// Resolves with the downloaded bytes, or `nil` on failure (`state`
    /// already carries the message by then).
    func fetch(_ request: URLRequest) async -> Data? {
        guard case .idle = state else { return nil }
        buffer = Data()
        expectedBytes = 0
        contentLengthHeader = nil
        state = .downloading(fraction: 0, receivedBytes: 0, totalBytes: 0)

        let config = URLSessionConfiguration.default
        let delegateSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = delegateSession

        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            completion = { data in
                continuation.resume(returning: data)
            }
            delegateSession.dataTask(with: request).resume()
        }
    }

    func reset() {
        session?.invalidateAndCancel()
        session = nil
        buffer = Data()
        state = .idle
        completion = nil
    }
}

extension CachePreloader: URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let total = response.expectedContentLength
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let lengthHeader = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length")
        Task { @MainActor in
            guard (200..<300).contains(status) else {
                self.state = .failed("The server returned an error (\(status)).")
                completionHandler(.cancel)
                self.finish(nil)
                return
            }
            self.expectedBytes = total > 0 ? total : 0
            self.contentLengthHeader = lengthHeader
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        Task { @MainActor in
            self.buffer.append(data)
            let fraction = self.expectedBytes > 0 ? Double(self.buffer.count) / Double(self.expectedBytes) : 0
            self.state = .downloading(
                fraction: fraction, receivedBytes: Int64(self.buffer.count), totalBytes: self.expectedBytes
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error {
                let nsError = error as NSError
                if nsError.code != NSURLErrorCancelled {
                    self.state = .failed("The connection dropped partway through.")
                }
                self.finish(nil)
                return
            }
            self.finish(self.buffer)
        }
    }

    private func finish(_ data: Data?) {
        completion?(data)
        completion = nil
        if data != nil { state = .idle }
    }
}
