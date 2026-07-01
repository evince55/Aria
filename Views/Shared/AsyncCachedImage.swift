import SwiftUI
import UIKit
import ImageIO

/// In-memory LRU cache for downloaded track artwork. Keys are the source
/// `URL` plus the requested pixel bucket (see `ImageCacheKey`), since the
/// same source image can be decoded at different downsampled sizes by
/// different call sites (e.g. a 36pt mini-player thumbnail vs. a 290pt
/// full-screen player image). Caching per-bucket avoids serving an
/// over-large (or blurry, under-sized) decode to a view that asked for a
/// different size, while still sharing the decode across views that
/// request the same bucket. The cache is shared across all
/// `AsyncCachedImage` instances and survives view re-creation.
struct ImageCacheKey: Hashable {
    let url: URL
    /// Target pixel size, rounded to a coarse bucket so near-identical
    /// requests (e.g. 47pt vs 48pt at the same scale) share a cache entry.
    let pixelBucket: Int

    init(url: URL, targetPixelSize: CGFloat) {
        self.url = url
        // Bucket to the nearest 16px so minor layout differences reuse
        // the same decoded image instead of each fragmenting the cache.
        let bucketSize: CGFloat = 16
        self.pixelBucket = max(1, Int((targetPixelSize / bucketSize).rounded(.up)) ) * Int(bucketSize)
    }
}

final class ImageMemoryCache {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
    }

    private func nsKey(for key: ImageCacheKey) -> NSString {
        "\(key.url.absoluteString)#\(key.pixelBucket)" as NSString
    }

    func image(for key: ImageCacheKey) -> UIImage? {
        cache.object(forKey: nsKey(for: key))
    }

    func store(_ image: UIImage, for key: ImageCacheKey) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: nsKey(for: key), cost: cost)
    }
}

/// SwiftUI image view with a memory cache. While loading, shows a
/// `ShimmerView` placeholder. On success, crossfades into the image.
///
/// Artwork is decoded at `targetSize` (in points) rather than full
/// resolution: source JPEGs from the YouTube CDN can be up to 1280x720,
/// which is far larger than any on-screen thumbnail (the biggest use is
/// the 290pt full-screen player artwork). Decoding full-size for a
/// 36-52pt list thumbnail wastes memory and CPU on every cell. We use
/// `CGImageSourceCreateThumbnailAtIndex` to downsample at decode time so
/// the decoder never materializes more pixels than will be displayed.
struct AsyncCachedImage<Placeholder: View>: View {
    /// Default target size (points) for call sites that don't specify
    /// one explicitly, sized for the largest common thumbnail use
    /// (list rows / grid cells) so unmigrated call sites still get a
    /// meaningful downsampling win rather than a full-resolution decode.
    static var defaultTargetSize: CGFloat { 120 }

    let url: URL?
    var cornerRadius: CGFloat = 0
    /// Target display size in points (not pixels). Multiplied by the
    /// screen scale to get the pixel size passed to the downsampler.
    var targetSize: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var didFail: Bool = false

    init(
        url: URL?,
        cornerRadius: CGFloat = 0,
        targetSize: CGFloat = AsyncCachedImage.defaultTargetSize,
        @ViewBuilder placeholder: @escaping () -> Placeholder = { ArtworkPlaceholder() }
    ) {
        self.url = url
        self.cornerRadius = cornerRadius
        self.targetSize = targetSize
        self.placeholder = placeholder
    }

    /// The URLs to try in order, derived from `url`. For YouTube CDN
    /// URLs this is `[maxresdefault.jpg, hqdefault.jpg]` so we get the
    /// highest available quality with a guaranteed fallback.
    ///
    /// The requested `targetSize` is passed to the rewriter so the *download*
    /// resolution is chosen to fit the display size (small rows pull a
    /// `mqdefault`/`hqdefault`, the full-screen player pulls `maxresdefault`),
    /// on top of the decode-time downsampling below that keeps the full-res
    /// decoded bitmap out of memory.
    private var candidates: [URL] {
        guard let url else { return [] }
        // Pass the display size so the rewriter also shrinks the *download*,
        // not just the decode — a small row no longer pulls a 1280×720 JPEG.
        let upgraded = YouTubeThumbnailRewriter.upgradedURLs(for: url, targetSize: targetSize)
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
                } else {
                    // Same view shown for both "loading" and "failed"
                    // (`didFail`) states — the caller-supplied placeholder,
                    // or by default `ArtworkPlaceholder` — so a missing or
                    // broken artwork URL still reads as "a track" rather
                    // than reverting to a blank box once loading gives up.
                    placeholder()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: TaskID(url: url, targetSize: targetSize)) {
            await load()
        }
    }

    /// Identifies a load request; re-runs `.task` when either the URL or
    /// the requested size changes (e.g. a view reused at a new frame).
    private struct TaskID: Equatable {
        let url: URL?
        let targetSize: CGFloat
    }

    private func load() async {
        let urls = candidates
        guard !urls.isEmpty else { image = nil; return }

        let screenScale = await MainActor.run { UIScreen.main.scale }
        let targetPixelSize = targetSize * screenScale

        for candidate in urls {
            if Task.isCancelled { return }
            let cacheKey = ImageCacheKey(url: candidate, targetPixelSize: targetPixelSize)
            if let cached = ImageMemoryCache.shared.image(for: cacheKey) {
                image = cached
                return
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: candidate)
                if Task.isCancelled { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                    continue
                }
                guard let img = Self.downsampledImage(data: data, maxPixelSize: targetPixelSize) else { return }
                ImageMemoryCache.shared.store(img, for: cacheKey)
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

    /// Decodes `data` directly to a downsampled bitmap no larger than
    /// `maxPixelSize` on its longest side, using ImageIO's thumbnail
    /// path so the full-resolution image is never fully decoded into
    /// memory. Pure function (no shared state) so it's directly testable.
    static func downsampledImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize.rounded(.up)))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            // Fall back to a full decode if ImageIO couldn't produce a
            // thumbnail (e.g. malformed/unsupported source) so we don't
            // regress correctness for the sake of memory savings.
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
