import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
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
        }
        .buttonStyle(.plain)
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
