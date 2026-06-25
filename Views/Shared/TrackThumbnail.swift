import SwiftUI

/// Shared thumbnail view for a track. Uses `AsyncCachedImage` so the
/// same artwork URL is only downloaded once across the whole app.
///
/// When `size` is provided, the thumbnail is fixed at that size.
/// When `size` is nil, the thumbnail fills the available width with a
/// 1:1 aspect ratio (useful for grid cells).
struct TrackThumbnail: View {
    let url: URL?
    var size: CGFloat? = nil
    var cornerRadius: CGFloat = 6

    var body: some View {
        AsyncCachedImage(url: url, cornerRadius: cornerRadius) {
            ShimmerView(cornerRadius: cornerRadius)
        }
        .modifier(ThumbnailSizing(size: size))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct ThumbnailSizing: ViewModifier {
    let size: CGFloat?

    func body(content: Content) -> some View {
        if let size {
            content.frame(width: size, height: size)
        } else {
            content
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
        }
    }
}
