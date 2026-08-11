import SwiftUI
import MetalKit

/// Debug-menu-only go/no-go test for a native Dreamcast core (Flycast,
/// interpreter-only, GLES hardware rendered). Bypasses NativeLauncher and
/// NativePlatform entirely on purpose: Dreamcast has no place in either
/// yet, and never will unless this test actually passes on real hardware.
/// Hardcoded to one rom (San Francisco Rush 2049, chosen as the most
/// demanding open-world title in the library) and its BIOS, both fetched
/// directly by id from the real server, the same shape as the FBNeo/Saturn
/// smoke tests this app carried before its real launch flow existed. See
/// NativeLauncher.swift's header comment for that precedent, and
/// LibretroFrontend.h's LibretroCoreIDFlycast comment for why this exists
/// outside the normal core list.
struct DreamcastSpikeView: View {
    private static let romID = 564
    private static let platformID = 14
    private static let biosFileName = "dc_boot.bin"

    @EnvironmentObject private var session: Session
    @State private var status = "Not started"
    @State private var progress: Double = 0
    @State private var errorMessage: String?
    @State private var playing = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Dreamcast go/no-go spike").font(.headline)
            Text("San Francisco Rush 2049 (USA), interpreter-only Flycast, GLES hardware render.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(status).font(.caption)
            if progress > 0 && progress < 1 {
                ProgressView(value: progress)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            Button("Download & Launch") {
                Task { await downloadAndLaunch() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(status == "Downloading" || status == "Loading")
        }
        .padding()
        .fullScreenCover(isPresented: $playing) {
            DreamcastSpikePlayerView(onQuit: { playing = false })
        }
    }

    /// Fixed, not a fresh UUID per run: a throwaway spike still shouldn't
    /// re-pull a 950MB file on every relaunch when it's already sitting on
    /// the phone from last time. Lives under Caches, not the plain temp
    /// directory other launches clean up on their way in, so it survives
    /// between app runs the way an actual "already downloaded" check
    /// should.
    private var workDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dreamcast-spike", isDirectory: true)
    }

    private func downloadAndLaunch() async {
        errorMessage = nil
        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

            let rom = try await session.rom(id: Self.romID)
            let romURL = workDir.appendingPathComponent(rom.fsName)
            if FileManager.default.fileExists(atPath: romURL.path) {
                status = "Using cached download"
            } else {
                status = "Downloading"
                try await download(session.romContentRequest(rom), to: romURL) { fraction in
                    progress = fraction
                }
            }

            let biosURL = workDir.appendingPathComponent(Self.biosFileName)
            if !FileManager.default.fileExists(atPath: biosURL.path) {
                let firmwareList = try await session.firmware(platformId: Self.platformID)
                guard let bios = firmwareList.first(where: { $0.fileName == Self.biosFileName }) else {
                    throw NSError(domain: "DreamcastSpike", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "\(Self.biosFileName) not found on the server for this platform."
                    ])
                }
                try await download(session.firmwareContentRequest(bios), to: biosURL) { _ in }
            }

            status = "Loading"
            LibretroFrontend.shared.activateCore(.flycast)
            // Flycast's own threaded renderer defaults on (reicast_
            // threaded_rendering, Option<bool> default true in the core's
            // shell/libretro/option.cpp) and spins up a second thread that
            // touches the same GL context. Only one thread can legally
            // hold an EAGLContext current at a time, and this frontend
            // already keeps every GL call on the thread driving runFrame;
            // a second thread racing for the same context is consistent
            // with what real device testing showed, the very first frame
            // rendering correctly before every frame after fails the same
            // way. Provenance's own research independently flagged this
            // exact core's threaded renderer as a known iOS hazard.
            LibretroFrontend.shared.setCoreOptions(["reicast_threaded_rendering": "disabled"])

            if let failure = LibretroFrontend.shared.loadGame(romURL.path, systemDirectory: workDir.path) {
                throw NSError(domain: "DreamcastSpike", code: 2, userInfo: [NSLocalizedDescriptionKey: failure])
            }

            status = "Running"
            playing = true
        } catch {
            status = "Failed"
            errorMessage = error.localizedDescription
        }
    }

    private func download(_ request: URLRequest, to url: URL, onProgress: @escaping (Double) -> Void) async throws {
        let delegate = SpikeDownloadDelegate(onProgress: onProgress)
        let urlSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await withCheckedThrowingContinuation { continuation in
            delegate.completion = { continuation.resume(with: $0) }
            urlSession.downloadTask(with: request).resume()
        }
        urlSession.finishTasksAndInvalidate()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: "DreamcastSpike", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(url.lastPathComponent)"
            ])
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
    }
}

/// Same shape as NativeLauncher's own progress delegate: reused as a
/// private copy here rather than shared, since this whole file is a
/// throwaway spike, same reasoning the tvOS prototype gave for its own
/// duplication.
private final class SpikeDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    var completion: ((Result<(URL, URLResponse), Error>) -> Void)?

    init(onProgress: @escaping (Double) -> Void) {
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
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("dc-spike-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            completion?(.success((staged, downloadTask.response ?? URLResponse())))
        } catch {
            completion?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        completion?(.failure(error))
    }
}

/// Bare player chrome, deliberately not NativePlayerView: no control
/// layout exists for Dreamcast, no save states, no pause menu. Just
/// enough touch input (d-pad, four face buttons, Start) to drive a menu
/// and a race, plus the live FPS readout the go/no-go actually hinges on.
private struct DreamcastSpikePlayerView: View {
    let onQuit: () -> Void

    @StateObject private var renderer = NativePlayerRenderer()
    @State private var heldButtons: Set<Int> = []
    @State private var hwDiagnostic = "…"
    private let diagnosticTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private func setHeld(_ id: Int, _ down: Bool) {
        if down { heldButtons.insert(id) } else { heldButtons.remove(id) }
        renderer.setButton(id, down: down)
    }

    // Standard RetroPad ids (libretro.h RETRO_DEVICE_ID_JOYPAD_*), the
    // same space every other core in this app already drives.
    private enum Pad {
        static let b = 0, y = 1, select = 2, start = 3
        static let up = 4, down = 5, left = 6, right = 7
        static let a = 8, x = 9
    }

    var body: some View {
        ZStack {
            SpikeMetalGameView(renderer: renderer)
                .ignoresSafeArea()

            VStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(format: "%.0f fps", renderer.measuredFPS))
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button("Quit") { onQuit() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                    Text(hwDiagnostic)
                        .font(.caption2.monospaced())
                }
                .padding(6)
                .background(.black.opacity(0.6))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding()
                .onReceive(diagnosticTimer) { _ in
                    let latest = LibretroFrontend.shared.hwRenderDiagnostics() ?? "no HW render"
                    guard latest != hwDiagnostic else { return }
                    hwDiagnostic = latest
                    // Recorded on change only, not every tick: DiagnosticsLog
                    // is a 10-entry ring buffer shared with the rest of the
                    // app, and this frontend's own throttling already only
                    // changes the string roughly every few seconds, so this
                    // doesn't spam it out. Lets "Copy diagnostics" on the
                    // Debug screen capture this instead of a screenshot.
                    DiagnosticsLog.record(context: "Dreamcast spike", message: latest, romVersion: nil)
                }
                Spacer()
                controls
                    .padding()
            }
        }
    }

    private var controls: some View {
        HStack {
            dPad
            Spacer()
            VStack(spacing: 8) {
                padButton("Start", Pad.start)
            }
            Spacer()
            faceButtons
        }
    }

    private var dPad: some View {
        VStack(spacing: 4) {
            padButton("▲", Pad.up)
            HStack(spacing: 4) {
                padButton("◀", Pad.left)
                padButton("▶", Pad.right)
            }
            padButton("▼", Pad.down)
        }
    }

    private var faceButtons: some View {
        VStack(spacing: 4) {
            padButton("Y", Pad.y)
            HStack(spacing: 4) {
                padButton("X", Pad.x)
                padButton("A", Pad.a)
            }
            padButton("B", Pad.b)
        }
    }

    private func padButton(_ label: String, _ id: Int) -> some View {
        Text(label)
            .frame(width: 44, height: 44)
            .background(heldButtons.contains(id) ? Color.accentColor : Color.gray.opacity(0.4))
            .foregroundStyle(.white)
            .clipShape(Circle())
            // A bare Text only hit-tests its own glyph bounds, not the
            // circle drawn around it via background/clipShape, so taps
            // anywhere outside the letter itself were silently missing
            // the gesture entirely. This widens the tappable area to
            // match what's actually drawn.
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in setHeld(id, true) }
                    .onEnded { _ in setHeld(id, false) }
            )
    }
}

private struct SpikeMetalGameView: UIViewRepresentable {
    let renderer: NativePlayerRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = renderer
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderer.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
