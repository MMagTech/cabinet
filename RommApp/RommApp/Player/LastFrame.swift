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

    // MARK: The frame behind the last save

    /// A copy of the newest frame, banked the moment a state is saved from
    /// the pause menu.
    ///
    /// Exists because the hero card and the Resume button made different
    /// promises: the card showed the last frame of the session, up to the
    /// moment of quitting, while Resume loads the last *save*, which can be
    /// well before that. Someone plays past their save, quits, and the card
    /// advertises a moment the save system never kept. The frame captured
    /// just before the pause that saved is the closest picture of the saved
    /// moment this app can have, since capturing at the pause itself reads
    /// back blank (see the save screenshot dead end in PlayerView).
    private static func savedURL(romId: Int) -> URL {
        directory.appendingPathComponent("\(romId)-saved.jpg")
    }

    static func bankSavedFrame(romId: Int) {
        let current = url(romId: romId)
        guard FileManager.default.fileExists(atPath: current.path) else { return }
        let destination = savedURL(romId: romId)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: current, to: destination)
    }

    static func savedImage(romId: Int) -> UIImage? {
        UIImage(contentsOfFile: savedURL(romId: romId).path)
    }
}
