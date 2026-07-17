import SwiftUI

/// A small capsule pill rendering an `AudioQuality` (codec + optional bitrate).
/// Shared by the two offline row types — `LibraryTrackRow` (imported files) and
/// `LibraryView.downloadRow` (YouTube downloads) — so both read the same.
///
/// Renders nothing for an `.unknown` quality: a "—" pill is noise on rows where
/// the codec couldn't be derived.
struct QualityBadge: View {
    let quality: AudioQuality
    let tokens: DesignTokens

    init(_ quality: AudioQuality, tokens: DesignTokens) {
        self.quality = quality
        self.tokens = tokens
    }

    var body: some View {
        if quality.category != .unknown {
            Text(quality.display)
                .font(DS.Typography.micro)
                .foregroundColor(tokens.textSecondary)
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(tokens.dividerColor)
                )
                .accessibilityLabel("Audio quality \(quality.display)")
        }
    }
}
