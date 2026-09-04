import SwiftUI

/// Cover art, fetched through the authenticated client rather than AsyncImage,
/// because the request may need the bearer token and AsyncImage cannot add one.
///
/// Decoded images are kept in one shared in-memory cache so scrolling back
/// through the grid does not refetch every cover, and written to disk
/// underneath it so a cold launch does not re-download the whole library.
struct CoverImage: View {
    let path: String?
    let title: String
    /// Whether a missing or failed cover draws the titled placeholder.
    /// Defaults to true, so every existing caller behaves exactly as
    /// before. tvOS's library tiles pass false: there the art sits on the
    /// app's own coloured panel, and a grey placeholder box reads as a
    /// broken tile rather than as a game with no art.
    var showsPlaceholder: Bool = true
    /// Fill for grids and rails, where every tile has to be the same shape.
    /// Fit for the Home hero, which shows the whole image rather than a
    /// crop of it.
    var contentMode: ContentMode = .fill

    @EnvironmentObject private var session: Session
    @State private var image: UIImage?
    @State private var failed = false

    /// Whether this cover's shape is meaningfully different from the 3:4
    /// box every fill-mode surface in the app sizes its cells to. Most
    /// cover art is box-shaped and fills cleanly; the exceptions, 3DO's
    /// long boxes the loudest among them, get cropped into nonsense by a
    /// straight fill, often losing the title text that lives at the top
    /// of the tall art.
    private func oddAspect(_ image: UIImage) -> Bool {
        guard image.size.height > 0 else { return false }
        return abs(image.size.width / image.size.height - 0.75) > 0.06
    }

    /// Debug builds only: `-cabinetBlurCovers 1` blurs every cover past
    /// recognition, for App Store screenshots taken against a real
    /// library without putting its box art on the store page. Applied
    /// to the decoded image itself, so every surface that draws a cover
    /// gets it and nothing about layout changes.
    static let blursCovers: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "cabinetBlurCovers")
        #else
        return false
        #endif
    }()

    static func screenshotBlurred(_ image: UIImage) -> UIImage {
        guard blursCovers, let input = CIImage(image: image) else { return image }
        let clamped = input.clampedToExtent()
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return image }
        blur.setValue(clamped, forKey: kCIInputImageKey)
        blur.setValue(max(image.size.width, image.size.height) / 12, forKey: kCIInputRadiusKey)
        guard let output = blur.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    var body: some View {
        ZStack {
            if let image {
                if contentMode == .fill && oddAspect(image) {
                    // Fit on a blurred echo of itself rather than crop:
                    // the whole cover stays visible, the cell keeps its
                    // shape, and the letterbox bars are the art's own
                    // colours instead of dead space. Same visual idea as
                    // the launch screen's ambient backdrop.
                    //
                    // The backdrop lives in an .overlay on Color.clear,
                    // never as a ZStack child, and that is load-bearing:
                    // a fill-mode image REPORTS its enlarged size to
                    // layout, not just draws it, so as a plain sibling
                    // it grew the whole tile past its grid column and
                    // pushed into the neighbouring tiles (seen on
                    // device: The Coven's entire row bled together).
                    // Overlay content contributes nothing to layout, so
                    // the tile answers exactly the proposed cell and the
                    // caller's clip catches the backdrop's overdraw.
                    Color.clear
                        .overlay(
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .scaleEffect(1.3)
                                .blur(radius: 12)
                        )
                    Color.black.opacity(0.18)
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if contentMode == .fill {
                    // The same overlay trick the odd-aspect branch uses,
                    // and for the same load-bearing reason: a fill-mode
                    // image REPORTS its enlarged size to layout and to
                    // HIT TESTING, and clipping only hides the spill,
                    // it does not stop it taking taps. A near-3:4 cover
                    // filling a 3:4 cell still overhangs a few points;
                    // a genuinely wide one overhangs into the next tile,
                    // which is how tapping one Game & Watch game opened
                    // its neighbour. Overlay content contributes nothing
                    // to layout or hit tests, so the view answers
                    // exactly the proposed cell, every time, for every
                    // cover shape.
                    Color.clear
                        .overlay(
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        )
                        .clipped()
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            } else if !showsPlaceholder {
                Color.clear
            } else {
                // Arcade sets often have no art at all. A titled placeholder
                // keeps the tile identifiable instead of a gray void.
                Rectangle()
                    .fill(.quaternary)
                VStack(spacing: 6) {
                    Image(systemName: "gamecontroller")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(title)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
            }
        }
        .task(id: path) { await load() }
    }

    /// Runs on appear and again whenever `path` changes, via task(id:).
    /// The change case matters: SwiftUI reuses this view when the rom in
    /// a slot changes (Home's hero card after a play reorders recents),
    /// and an early-out on the already-loaded image kept the previous
    /// game's art under the new game's title.
    private func load() async {
        guard let path else {
            image = nil
            return
        }

        if let cached = await CoverCache.shared.image(forKey: path) {
            image = Self.screenshotBlurred(cached)
            return
        }

        image = nil
        failed = false
        do {
            let data = try await session.coverData(path: path)
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            await CoverCache.shared.set(decoded, data: data, forKey: path)
            image = Self.screenshotBlurred(decoded)
        } catch {
            // A cancelled fetch is the view moving on to a newer path,
            // not a failure of this one.
            if !Task.isCancelled { failed = true }
        }
    }
}

/// Two tiers: an in-memory cache for the current session, and a disk cache
/// underneath it so covers survive the app being closed. Before the disk
/// tier existed, every cold launch re-downloaded the whole visible library,
/// which is slow on a weak connection and pure waste on a metered one.
///
/// Kept deliberately simple. Nothing here tracks which game a file belongs
/// to or tries to stay in step with the server: a cover is disposable, and
/// the worst case for a stale one is re-downloading it.
actor CoverCache {
    static let shared = CoverCache()

    /// No expiry on purpose. RomM's cover paths carry the timestamp of the
    /// last artwork change (`...small.png?ts=2025-03-11 06:50:19`) and that
    /// whole string is the key here, so replacing a game's art in RomM
    /// changes the key and downloads the new file by itself. An age limit
    /// on top of that would only throw away valid artwork and re-fetch it,
    /// which is the exact data waste this cache exists to avoid.
    ///
    /// Trimmed back to this, least recently used first, whenever a write
    /// pushes it over. Small covers run 20 to 50KB, so this holds a few
    /// thousand of them: a ceiling that a normal library never reaches,
    /// not a budget. Living in the system caches directory means iOS can
    /// also reclaim the whole thing under real storage pressure.
    private static let maxBytes = 200 * 1024 * 1024

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    /// Bytes written since the last size check. Checking on every write
    /// would mean listing the whole directory per cover, and checking only
    /// once per launch (the first version of this) would let a long
    /// session blow well past the cap without noticing: someone scrolling
    /// a 50,000 game library does thousands of writes before they ever
    /// relaunch. Re-checking every few megabytes costs one directory
    /// listing per 200 or so covers and keeps the cap honest.
    private static let trimInterval = 8 * 1024 * 1024
    private var bytesSinceTrim = CoverCache.trimInterval

    func image(forKey key: String) -> UIImage? {
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let file = fileURL(for: key)
        guard let data = try? Data(contentsOf: file), let decoded = UIImage(data: data) else {
            return nil
        }
        // Stamp the file as used, which is what makes the size trim a real
        // least-recently-used eviction rather than "delete whatever was
        // downloaded longest ago". Without this, a cover seen every day
        // would be evicted ahead of one fetched last week and never
        // looked at again.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        memory.setObject(decoded, forKey: key as NSString)
        return decoded
    }

    /// Stores the original bytes rather than re-encoding the decoded image:
    /// the server already sent a compressed cover, and round tripping it
    /// through `pngData()` would inflate it several times over.
    func set(_ image: UIImage, data: Data, forKey key: String) {
        memory.setObject(image, forKey: key as NSString)
        try? data.write(to: fileURL(for: key), options: .atomic)
        bytesSinceTrim += data.count
        if bytesSinceTrim >= Self.trimInterval {
            bytesSinceTrim = 0
            trimIfNeeded()
        }
    }

    /// Total bytes currently on disk, for the Cache screen.
    func diskUsage() -> Int64 {
        contents().reduce(0) { $0 + Int64($1.size) }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Trims to 80% of the cap rather than exactly to it, so a full cache
    /// does not run a delete pass on every single write.
    private func trimIfNeeded() {
        var files = contents()
        var total = files.reduce(0) { $0 + $1.size }
        guard total > Self.maxBytes else { return }
        let target = Self.maxBytes * 8 / 10

        files.sort { $0.modified < $1.modified }
        for file in files {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    private func contents() -> [(url: URL, size: Int, modified: Date)] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                let size = values.fileSize,
                let modified = values.contentModificationDate
            else { return nil }
            return (url, size, modified)
        }
    }

    /// A cover path is a URL path with slashes and a query string, so it
    /// cannot be a filename as is. Hashing also keeps the name a fixed
    /// length regardless of how long the original path was.
    private func fileURL(for key: String) -> URL {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return directory.appendingPathComponent(String(hash, radix: 16))
    }
}
