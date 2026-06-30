import SwiftUI

/// Shared placeholder for track/album artwork, used both while an
/// `AsyncCachedImage` is loading and when it has permanently failed to
/// load (no URL, 404, decode failure, etc). Renders a subtle themed fill
/// with a centered `music.note` glyph instead of a blank rectangle, so a
/// missing-artwork track is still visually recognizable as "a track" at
/// every call site — from a 36pt mini-player thumbnail up to the 290pt
/// full-screen player artwork.
///
/// The glyph is sized as a fraction of the container (via `GeometryReader`)
/// rather than a fixed point size, so it scales correctly across that
/// entire size range without needing per-call-site tuning.
struct ArtworkPlaceholder: View {
    var tokens: DesignTokens = ThemeManager.fallbackTokens
    var cornerRadius: CGFloat = 0

    /// Glyph size as a fraction of the shorter container dimension.
    /// Tuned so the icon reads clearly without crowding the fill at
    /// small sizes (36pt mini-player) or looking lost at large sizes
    /// (290pt full-screen artwork).
    private let glyphScale: CGFloat = 0.38

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tokens.dividerColor)
                Image(systemName: "music.note")
                    .font(.system(size: max(10, side * glyphScale), weight: .medium))
                    .foregroundColor(tokens.textSecondary)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // Decorative — the surrounding row/track already carries the
        // accessible label, so this shouldn't add VoiceOver noise.
        .accessibilityHidden(true)
    }
}

#Preview("Sizes") {
    let tokens = DesignTokens(isDark: true, accent: .pink)
    return HStack(alignment: .bottom, spacing: 16) {
        ArtworkPlaceholder(tokens: tokens, cornerRadius: 4)
            .frame(width: 36, height: 36)
        ArtworkPlaceholder(tokens: tokens, cornerRadius: 6)
            .frame(width: 48, height: 48)
        ArtworkPlaceholder(tokens: tokens, cornerRadius: 10)
            .frame(width: 130, height: 130)
        ArtworkPlaceholder(tokens: tokens, cornerRadius: 12)
            .frame(width: 290, height: 290)
    }
    .padding()
    .background(tokens.background)
}

#Preview("Light mode") {
    let tokens = DesignTokens(isDark: false, accent: .blue)
    return ArtworkPlaceholder(tokens: tokens, cornerRadius: 12)
        .frame(width: 200, height: 200)
        .padding()
        .background(tokens.background)
}
