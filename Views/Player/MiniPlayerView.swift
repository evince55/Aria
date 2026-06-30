import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 28)

                if let track = playerManager.currentTrack {
                    artworkThumbnail
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        subtitle
                    }
                } else {
                    Text("Not playing")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()

                trailingButton
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(height: 44)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) {
                if playerManager.currentTrack != nil {
                    progressBar
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Thin playback-progress bar pinned to the top edge of the mini player.
    /// Driven by `clock` (not `playerManager`) so the 4 Hz position tick
    /// repaints only this 2 pt bar, never the whole view tree.
    @ViewBuilder
    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = clock.duration > 0
                ? min(max(clock.currentTime / clock.duration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.12))
                Rectangle().fill(Color.primary.opacity(0.55))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artworkThumbnail: some View {
        if let url = playerManager.currentArtworkURL {
            AsyncCachedImage(url: url) {
                Rectangle().fill(.gray.opacity(0.3))
            }
        } else {
            Rectangle().fill(.gray.opacity(0.3))
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        Text(playerManager.currentTrack?.artist ?? "")
            .font(.system(size: 11))
            .lineLimit(1)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var trailingButton: some View {
        Group {
            Button {
                playerManager.togglePlayPause()
            } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.primary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")
        }
    }
}
