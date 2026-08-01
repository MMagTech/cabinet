import SwiftUI

/// Cover art, fetched through the authenticated client rather than AsyncImage,
/// because the request may need the bearer token and AsyncImage cannot add one.
///
/// Decoded images are kept in one shared in-memory cache so scrolling back
/// through the grid does not refetch every cover.
struct CoverImage: View {
    let path: String?
    let title: String

    @EnvironmentObject private var session: Session
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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

    private func load() async {
        guard image == nil, !failed, let path else { return }

        if let cached = CoverCache.shared.image(forKey: path) {
            image = cached
            return
        }

        do {
            let data = try await session.coverData(path: path)
            guard let decoded = UIImage(data: data) else {
                failed = true
                return
            }
            CoverCache.shared.set(decoded, forKey: path)
            image = decoded
        } catch {
            failed = true
        }
    }
}

final class CoverCache {
    static let shared = CoverCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}
