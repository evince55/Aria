import SwiftUI
import UIKit

/// In-memory LRU cache for downloaded track artwork. Keys are the source
/// `URL`; values are the decoded `UIImage`. The cache is shared across all
/// `AsyncCachedImage` instances and survives view re-creation.
final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func store(_ image: UIImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

/// SwiftUI image view with a memory cache. While loading, shows a
/// `ShimmerView` placeholder. On success, crossfades into the image.
struct AsyncCachedImage<Placeholder: View>: View {
    let url: URL?
    var cornerRadius: CGFloat = 0
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var didFail: Bool = false

    init(
        url: URL?,
        cornerRadius: CGFloat = 0,
        @ViewBuilder placeholder: @escaping () -> Placeholder = { ShimmerView() }
    ) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
    }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(.easeIn(duration: 0.18)))
            } else if didFail {
                ZStack {
                    Color.gray.opacity(0.15)
                    Image(systemName: "photo")
                        .foregroundColor(.gray.opacity(0.5))
                }
            } else {
                placeholder()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        if let cached = ImageMemoryCache.shared.image(for: url) {
            image = cached
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, let img = UIImage(data: data) else { return }
            ImageMemoryCache.shared.store(img, for: url)
            image = img
        } catch {
            if !Task.isCancelled {
                didFail = true
            }
        }
    }
}
