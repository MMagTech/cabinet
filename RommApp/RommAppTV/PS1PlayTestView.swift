#if os(tvOS)
import SwiftUI
import CoreGraphics

/// The playable half of the PS1 go/no-go: same hardcoded rom as
/// PS1PerfTestView (no picker, no library), but actually drawn to the
/// screen and driven by a real controller instead of just timed. Still a
/// throwaway test screen, not the real player: no audio, no pause menu, no
/// save states, no way back out except the Menu button on the controller
/// (mapped to RetroPad.overlay's default binding) exiting this view.
struct PS1PlayTestView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    private static let testRomID = 322

    @State private var status = "Idle"
    @State private var frameImage: CGImage?
    @State private var loopTask: Task<Void, Never>?
    @State private var buttonMask: UInt32 = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let frameImage {
                Image(decorative: frameImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
        .task { await start() }
        .onDisappear { loopTask?.cancel() }
    }

    private func start() async {
        do {
            status = "Fetching rom \(Self.testRomID)…"
            let rom = try await session.rom(id: Self.testRomID)

            status = "Downloading \(rom.name)…"
            _ = try await NativeLauncher.prepare(rom: rom, session: session)

            status = "Loaded, waiting for first frame…"
            GameControllerManager.shared.send = { id, pressed in
                guard id >= 0, id < 32 else { return }
                if pressed {
                    buttonMask |= (1 << UInt32(id))
                } else {
                    buttonMask &= ~(1 << UInt32(id))
                }
            }
            GameControllerManager.shared.onMenu = { dismiss() }
            GameControllerManager.shared.start()

            loopTask = Task { await runLoop() }
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            LibretroFrontend.shared.setButtonMask(buttonMask)
            LibretroFrontend.shared.runFrame()
            if let frame = LibretroFrontend.shared.latestFrame(), let image = Self.cgImage(from: frame) {
                frameImage = image
            }
            try? await Task.sleep(nanoseconds: 16_666_667) // ~60fps
        }
    }

    /// Converts one raw libretro video frame straight to a `CGImage`, no
    /// Metal, no texture cache: this is a test screen, not the real
    /// player's render path, and a per-frame CPU blit is the simplest thing
    /// that can prove the pixels are correct before anyone builds a real
    /// GPU pipeline for it.
    private static func cgImage(from frame: LibretroFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        switch frame.pixelFormat {
        case .XRGB8888:
            return CGImage(
                width: Int(frame.width), height: Int(frame.height),
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(frame.bytesPerRow),
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        case .RGB565:
            // CGImage's public API requires equal bits per color component;
            // 565's uneven 5-6-5 split has no legal bitsPerComponent value
            // to hand it (5 silently produced a nil image every frame, the
            // actual cause of a PS1 test that loaded correctly per the
            // native core's own log but never showed a picture). Unpack to
            // 8-bit RGBA by hand instead of asking CGImage to parse 565
            // directly.
            return rgba8888(unpacking565: frame, colorSpace: colorSpace)
        case .RGB1555:
            return CGImage(
                width: Int(frame.width), height: Int(frame.height),
                bitsPerComponent: 5, bitsPerPixel: 16, bytesPerRow: Int(frame.bytesPerRow),
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        @unknown default:
            return nil
        }
    }

    private static func rgba8888(unpacking565 frame: LibretroFrame, colorSpace: CGColorSpace) -> CGImage? {
        let width = Int(frame.width), height = Int(frame.height)
        let srcStride = Int(frame.bytesPerRow)
        var out = [UInt8](repeating: 0, count: width * height * 4)

        frame.pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<height {
                let rowBase = raw.baseAddress!.advanced(by: y * srcStride).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let pixel = rowBase[x].littleEndian
                    let r5 = (pixel >> 11) & 0x1F
                    let g6 = (pixel >> 5) & 0x3F
                    let b5 = pixel & 0x1F
                    let outIndex = (y * width + x) * 4
                    out[outIndex + 0] = UInt8((r5 * 255) / 31)
                    out[outIndex + 1] = UInt8((g6 * 255) / 63)
                    out[outIndex + 2] = UInt8((b5 * 255) / 31)
                    out[outIndex + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
#endif
