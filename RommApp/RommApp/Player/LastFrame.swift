import UIKit

/// The last frame seen of each game, stored as a small image per rom.
///
/// The scope doc's Home is "last played game, large, with a screenshot of
/// the frame you left on". The frame arrives from the player alongside each
/// autosave, so what Home shows is your own moment, at most thirty seconds
/// stale, rather than box art. Files live in Application Support and are
/// overwritten in place; there is nothing to clean up and losing one costs
/// a cover-art fallback.
enum LastFrame {
    private static var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = base.appendingPathComponent("LastFrames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(romId: Int) -> URL {
        directory.appendingPathComponent("\(romId).jpg")
    }

    /// The payload is a data URL from the webview, because a Blob cannot
    /// cross the message bridge and base64 through FileReader is the way
    /// web content hands binary to anyone. EmulatorJS captures at canvas
    /// resolution, which arrived as a 3.8MB png in testing; the hero shows
    /// at a few hundred points, so the frame is downscaled and recompressed
    /// before it touches disk.
    static func save(dataURL: String, romId: Int) {
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: data)
        else { return }

        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 1000 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = small.jpegData(compressionQuality: 0.8) else { return }
        try? jpeg.write(to: url(romId: romId), options: .atomic)
    }

    static func image(romId: Int) -> UIImage? {
        UIImage(contentsOfFile: url(romId: romId).path)
    }
}
