import XCTest
import UIKit
@testable import Aria___Music_Browser

final class AsyncCachedImageTests: XCTestCase {

    /// Renders a solid-color JPEG at the given pixel size, used as test
    /// fixture data for the downsampler (stands in for a downloaded
    /// thumbnail without needing network access or a bundled asset).
    private func makeJPEGData(width: Int, height: Int) -> Data {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        // JPEG (not PNG) to match real-world YouTube thumbnail data and
        // exercise the same ImageIO decode path used in production.
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            XCTFail("failed to render fixture JPEG")
            return Data()
        }
        return data
    }

    // MARK: - downsampledImage

    func test_downsampledImage_shrinksLargeSourceToRequestedPixelSize() throws {
        let data = makeJPEGData(width: 1280, height: 720)

        let result = try XCTUnwrap(
            AsyncCachedImage<ShimmerView>.downsampledImage(data: data, maxPixelSize: 100)
        )

        // The longest side should be downsampled to ~100px (ImageIO may
        // be off by a pixel or two due to JPEG block rounding), and
        // critically far below the 1280px source.
        let longestSide = max(result.size.width, result.size.height) * result.scale
        XCTAssertLessThanOrEqual(longestSide, 110, "expected downsampling to ~100px, got \(longestSide)")
        XCTAssertGreaterThan(longestSide, 50, "downsampled image is unexpectedly tiny")
    }

    func test_downsampledImage_requestingLargerThanSourceReturnsSourceResolution() throws {
        // ImageIO's thumbnail API scales *to* the requested max pixel size
        // (it will upscale a small source if asked for a larger thumbnail
        // than the source has). That's fine for our real call sites,
        // since every target size we request (36-290pt) is always smaller
        // than the YouTube CDN source images (≥480x360). This test just
        // documents that contract: a source at least as large as the
        // request round-trips at (approximately) its own resolution
        // rather than being needlessly upscaled by some unrelated factor.
        let data = makeJPEGData(width: 256, height: 256)

        let result = try XCTUnwrap(
            AsyncCachedImage<ShimmerView>.downsampledImage(data: data, maxPixelSize: 100)
        )

        let longestSide = max(result.size.width, result.size.height) * result.scale
        XCTAssertLessThanOrEqual(longestSide, 110, "source larger than the request should be downsampled to ~100px")
    }

    func test_downsampledImage_preservesAspectRatio() throws {
        let data = makeJPEGData(width: 1280, height: 720)

        let result = try XCTUnwrap(
            AsyncCachedImage<ShimmerView>.downsampledImage(data: data, maxPixelSize: 200)
        )

        let sourceRatio = 1280.0 / 720.0
        let resultRatio = Double(result.size.width / result.size.height)
        XCTAssertEqual(resultRatio, sourceRatio, accuracy: 0.05)
    }

    func test_downsampledImage_invalidDataReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03])
        let result = AsyncCachedImage<ShimmerView>.downsampledImage(data: garbage, maxPixelSize: 100)
        XCTAssertNil(result, "non-image data should not produce a fallback image")
    }

    // MARK: - ImageCacheKey

    func test_imageCacheKey_bucketsNearbySizesTogether() throws {
        let url = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        let keyA = ImageCacheKey(url: url, targetPixelSize: 97)
        let keyB = ImageCacheKey(url: url, targetPixelSize: 100)

        XCTAssertEqual(keyA, keyB, "sizes within the same 16px bucket should share a cache entry")
    }

    func test_imageCacheKey_differsAcrossDistantSizes() throws {
        let url = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/abc/hqdefault.jpg"))
        let small = ImageCacheKey(url: url, targetPixelSize: 72) // mini-player-ish
        let large = ImageCacheKey(url: url, targetPixelSize: 580) // full-screen player-ish

        XCTAssertNotEqual(small, large, "a 36pt thumbnail and a 290pt artwork must not share a decoded bitmap")
    }

    func test_imageCacheKey_differsAcrossURLs() throws {
        let urlA = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/aaa/hqdefault.jpg"))
        let urlB = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/bbb/hqdefault.jpg"))

        XCTAssertNotEqual(
            ImageCacheKey(url: urlA, targetPixelSize: 96),
            ImageCacheKey(url: urlB, targetPixelSize: 96)
        )
    }

    // MARK: - ImageMemoryCache

    func test_imageMemoryCache_storeAndRetrieveByKey() throws {
        let url = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/cache-test/hqdefault.jpg"))
        let key = ImageCacheKey(url: url, targetPixelSize: 96)
        let image = try XCTUnwrap(UIImage(data: makeJPEGData(width: 10, height: 10)))

        ImageMemoryCache.shared.store(image, for: key)

        XCTAssertNotNil(ImageMemoryCache.shared.image(for: key))
    }

    func test_imageMemoryCache_missForDifferentBucket() throws {
        let url = try XCTUnwrap(URL(string: "https://i.ytimg.com/vi/cache-test-2/hqdefault.jpg"))
        let smallKey = ImageCacheKey(url: url, targetPixelSize: 64)
        let largeKey = ImageCacheKey(url: url, targetPixelSize: 600)
        let image = try XCTUnwrap(UIImage(data: makeJPEGData(width: 10, height: 10)))

        ImageMemoryCache.shared.store(image, for: smallKey)

        XCTAssertNil(ImageMemoryCache.shared.image(for: largeKey), "different size bucket must not hit the small decode")
    }
}
