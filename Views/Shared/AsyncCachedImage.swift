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

    /// The URLs to try in order, derived from `url`. For YouTube CDN
    /// URLs this is `[maxresdefault.jpg, hqdefault.jpg]` so we get the
    /// highest available quality with a guaranteed fallback.
    private var candidates: [URL] {
        guard let url else { return [] }
        let upgraded = YouTubeThumbnailRewriter.upgradedURLs(for: url)
        return upgraded.isEmpty ? [url] : upgraded
    }

    var body: some View {
        GeometryReader { proxy in
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
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        let urls = candidates
        guard !urls.isEmpty else { image = nil; return }

        for candidate in urls {
            if Task.isCancelled { return }
            if let cached = ImageMemoryCache.shared.image(for: candidate) {
                image = cached
                return
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: candidate)
                if Task.isCancelled { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    continue
                }
                guard let img = UIImage(data: data) else { return }
                ImageMemoryCache.shared.store(img, for: candidate)
                image = img
                return
            } catch {
                continue
            }
        }

        if !Task.isCancelled {
            didFail = true
        }
    }
}
