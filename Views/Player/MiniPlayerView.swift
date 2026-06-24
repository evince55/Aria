import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 36)

                if let track = playerManager.currentTrack {
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
    private var subtitle: some View {
        if case .preparingDownload(let progress) = playerManager.playbackState {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                Text("Preparing…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        } else {
            Text(playerManager.currentTrack?.artist ?? "")
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var trailingButton: some View {
        if case .preparingDownload = playerManager.playbackState {
            // No transport control while the engine is still downloading
            // — tapping play would race the in-flight download and
            // produce no audible difference.
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 40, height: 40)
        } else {
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
