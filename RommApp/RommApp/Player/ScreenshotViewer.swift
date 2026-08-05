import ImageIO
import SwiftUI

/// The screenshot behind a save or a state, shown full size from the row's
/// own menu, never loaded just to render the list.
///
/// In-row thumbnails were tried first and dropped: at row size, most of
/// this library's games (dense arcade shooters especially) read as
/// indistinguishable noise, and the relative dates already tell rows
/// apart. On demand is also the only time this costs a fetch, so a list
/// of a dozen states no longer means a dozen downloads to display it.
///
/// This viewer itself was deleted once, when captures at save time were
/// believed unfixable, and restored the same night: grabbing the frame on
/// the way into the pause, one frame before the freeze, produces a real
/// image of the saved moment, so there is something true to show again.
struct ScreenshotViewer: View {
    let path: String?
    let title: String

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                } else if failed {
                    ContentUnavailableView(
                        "Couldn't load this screenshot", systemImage: "photo.badge.exclamationmark"
                    )
                    .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let path else {
            failed = true
            return
        }
        do {
            let data = try await session.screenshotData(path: path)
            // Capped rather than decoded at native size unbounded: the
            // capture is already downscaled to 1000 wide before upload,
            // so this rarely engages, but a screenshot made by RomM's own
            // player arrives at whatever size its capture chose.
            guard let decoded = Self.downsampled(data, to: 1600) else {
                failed = true
                return
            }
            image = decoded
        } catch {
            failed = true
        }
    }

    /// `CGImageSource`'s own thumbnail generator, which decodes straight to
    /// the target size rather than decoding the full image first and
    /// scaling it after.
    private static func downsampled(_ data: Data, to maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}
