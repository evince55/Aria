import SwiftUI

/// A small three-bar "now playing" indicator that animates while audio is
/// playing. Used in lists to mark the currently playing track.
struct NowPlayingIndicator: View {
    let isPlaying: Bool
    let accent: Color

    @State private var phase: CGFloat = 0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            bar(height: 8, phase: phase)
            bar(height: 14, phase: phase + 0.2)
            bar(height: 10, phase: phase + 0.4)
        }
        .frame(width: 14, height: 14)
        .onAppear { startAnimating() }
        .onChange(of: isPlaying) { newValue in
            if newValue { startAnimating() } else { phase = 0 }
        }
    }

    private func startAnimating() {
        guard isPlaying else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            phase = 1
        }
    }

    private func bar(height: CGFloat, phase: CGFloat) -> some View {
        Capsule()
            .fill(accent)
            .frame(width: 2.5, height: height)
    }
}

/// A leading "now playing" indicator on a track row.
struct NowPlayingLeadingBar: View {
    let isCurrent: Bool
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isCurrent ? accent : Color.clear)
            .frame(width: 3, height: 28)
            .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }
}

/// A polished row used in lists (Favorites, Playlists, Search, Queue).
struct TrackRow: View {
    let track: Track
    let themeManager: ThemeManager
    let playerManager: PlayerManager
    var showChevron: Bool = false
    var onTap: () -> Void = {}

    private var tokens: DesignTokens { themeManager.tokens }
    private var isCurrent: Bool { playerManager.currentTrack?.id == track.id }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: DS.Spacing.md) {
                NowPlayingLeadingBar(isCurrent: isCurrent, accent: tokens.accent)

                TrackThumbnail(url: track.thumbnailURL, size: 48, cornerRadius: DS.Radius.sm)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(DS.Typography.bodyEm)
                        .lineLimit(1)
                        .foregroundColor(isCurrent ? tokens.accent : tokens.textPrimary)
                    HStack(spacing: 6) {
                        if isCurrent {
                            NowPlayingIndicator(isPlaying: playerManager.isPlaying, accent: tokens.accent)
                        }
                        Text(track.artist)
                            .font(DS.Typography.caption)
                            .lineLimit(1)
                            .foregroundColor(tokens.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(tokens.textSecondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Section header used in lists (Apple-style small caps).
struct SectionLabel: View {
    let title: String
    let tokens: DesignTokens

    var body: some View {
        Text(title)
            .font(DS.Typography.sectionHeader)
            .foregroundColor(tokens.textSecondary)
            .textCase(nil)
    }
}
