import Foundation
import CoreGraphics

/// Rewrites YouTube thumbnail URLs to higher-quality versions.
///
/// YouTube thumbnail URLs follow the pattern:
///   `https://i.ytimg.com/vi/{video_id}/default.jpg`        (120×90)
///   `https://i.ytimg.com/vi/{video_id}/mqdefault.jpg`       (320×180)
///   `https://i.ytimg.com/vi/{video_id}/hqdefault.jpg`       (480×360)
///   `https://i.ytimg.com/vi/{video_id}/sddefault.jpg`       (640×480)
///   `https://i.ytimg.com/vi/{video_id}/maxresdefault.jpg`   (1280×720)
///
/// For the full-screen player (290pt × 3x = 870px), `maxresdefault.jpg`
/// provides enough resolution to look sharp. However, `maxresdefault.jpg`
/// returns 404 for some older videos (pre-2014), so we always include
/// `hqdefault.jpg` as a guaranteed fallback (480×360, ~270px @3x — still
/// much sharper than `default.jpg` at 120×90).
///
/// The iOS app receives these URLs from the backend (`backend/app.py`)
/// which uses `default.jpg` as a fallback. This rewriter upgrades the
/// URL on the client side so every consumer (list rows, mini player,
/// full-screen player) benefits.
enum YouTubeThumbnailRewriter {
    private static let pattern = #"https?://i\.ytimg\.com/vi/([^/]+)/"#

    /// Returns candidate YouTube thumbnail URLs ordered by quality (highest
    /// first), or `[url]` if the URL doesn't match the YouTube CDN pattern. The
    /// caller tries them in order, falling back on 404.
    ///
    /// `targetSize` is the display size in points; the primary candidate is the
    /// smallest YouTube variant that still covers it at ~3× (so a 48pt row pulls
    /// a 320×180 `mqdefault` instead of a 1280×720 `maxresdefault` — real
    /// bytes-over-the-wire savings). `hqdefault` (480×360, always present) is
    /// appended as a guaranteed fallback since `maxres`/`sd` 404 on old videos.
    /// `targetSize <= 0` keeps the legacy "maxres then hq" behavior.
    static func upgradedURLs(for url: URL, targetSize: CGFloat = 0) -> [URL] {
        let absolute = url.absoluteString
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [url]
        }
        let range = NSRange(absolute.startIndex..., in: absolute)
        guard let match = regex.firstMatch(in: absolute, range: range),
              match.numberOfRanges > 1,
              let videoIDRange = Range(match.range(at: 1), in: absolute)
        else {
            return [url]
        }
        let videoID = String(absolute[videoIDRange])

        let variants: [String]
        if targetSize <= 0 {
            variants = ["maxresdefault", "hqdefault"]
        } else {
            let primary: String
            switch targetSize {
            case ..<64:  primary = "mqdefault"      // 320×180
            case ..<160: primary = "hqdefault"      // 480×360
            case ..<214: primary = "sddefault"      // 640×480
            default:     primary = "maxresdefault"  // 1280×720
            }
            variants = primary == "hqdefault" ? ["hqdefault"] : [primary, "hqdefault"]
        }

        var result: [URL] = []
        for name in variants {
            if let u = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg"), u != url {
                result.append(u)
            }
        }
        return result.isEmpty ? [url] : result
    }
}
