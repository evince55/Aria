import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var playerManager: PlayerManager
    var namespace: Namespace.ID
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            progressBar

            Button(action: onTap) {
                HStack(spacing: DS.Spacing.md) {
                    artwork

                    if let track = playerManager.currentTrack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(DS.Typography.bodyEm)
                                .lineLimit(1)
                                .foregroundColor(.primary)
                            Text(track.artist)
                                .font(DS.Typography.caption)
                                .lineLimit(1)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Not playing")
                            .font(DS.Typography.body)
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: DS.Spacing.sm)

                    playPauseButton
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.05))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.bottom, DS.Spacing.sm)
    }

    private var artwork: some View {
        Group {
            if let url = playerManager.currentTrack?.thumbnailURL {
                AsyncCachedImage(url: url, cornerRadius: DS.Radius.sm) {
                    ShimmerView(cornerRadius: DS.Radius.sm)
                }
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(Color.gray.opacity(0.25))
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundColor(.gray.opacity(0.6))
                    )
            }
        }
        .frame(width: 40, height: 40)
        .matchedGeometryEffect(id: "playerArtwork", in: namespace)
    }

    private var playPauseButton: some View {
        Button {
            Haptics.light()
            playerManager.togglePlayPause()
        } label: {
            ZStack {
                if playerManager.playbackState == .loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.primary)
                } else {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary)
                        .transition(.opacity)
                        .id(playerManager.isPlaying)
                }
            }
            .frame(width: 40, height: 40)
            .background(
                Circle()
                    .fill(Color.primary.opacity(0.08))
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")
    }

    private var progressBar: some View {
        GeometryReader { geo in
            let fraction = playerManager.duration > 0
                ? min(1, max(0, playerManager.currentTime / playerManager.duration))
                : 0
            let w = geo.size.width * fraction

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(LinearGradient(
                        colors: [Color.accentColor.opacity(0.9), Color.accentColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    ))
                    .frame(width: w)
            }
        }
        .frame(height: 2)
        .clipShape(RoundedRectangle(cornerRadius: 1, style: .continuous))
    }
}
