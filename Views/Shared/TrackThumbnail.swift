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
    var tokens: DesignTokens = ThemeManager.fallbackTokens

    var body: some View {
        // `size` is nil for grid cells that fill available width with a
        // 1:1 aspect ratio; fall back to the shared default target so
        // those still downsample rather than decoding full resolution.
        //
        // `ArtworkPlaceholder` is shown both while loading and if the
        // load ultimately fails (see `AsyncCachedImage`), so a missing or
        // broken artwork URL renders as a recognizable music glyph
        // instead of reverting to a blank fill.
        AsyncCachedImage(
            url: url,
            cornerRadius: cornerRadius,
            targetSize: size ?? AsyncCachedImage<ArtworkPlaceholder>.defaultTargetSize
        ) {
            ArtworkPlaceholder(tokens: tokens, cornerRadius: cornerRadius)
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
