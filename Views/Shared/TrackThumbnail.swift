import SwiftUI

/// Shared thumbnail view for a track. Uses `AsyncCachedImage` so the
/// same artwork URL is only downloaded once across the whole app.
struct TrackThumbnail: View {
    let url: URL?
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 6

    var body: some View {
        AsyncCachedImage(url: url, cornerRadius: cornerRadius) {
            ShimmerView(cornerRadius: cornerRadius)
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
