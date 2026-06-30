import SwiftUI

/// One row in the Library list. Extracted from `LibraryView` so
/// `LibrarySectionView` can reuse the same row rendering under each
/// section header. The shape matches what `LibraryView` rendered
/// inline before B3 (HStack: artwork + title/artist/size/duration +
/// current-track icon), plus the B1 missing-track badge + 0.55 opacity.
struct LibraryTrackRow: View {
    let track: LocalTrack
    let isCurrentTrack: Bool
    let isPlaying: Bool
    let tokens: DesignTokens
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                artworkView
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .foregroundColor(tokens.textPrimary)
                        .lineLimit(1)
                    if let artist = track.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(tokens.textSecondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(formatBytes(track.fileSizeBytes))
                        if let duration = track.durationSeconds, duration > 0 {
                            Text("·")
                            Text(formatDuration(duration))
                        }
                    }
                    .font(.caption2)
                    .foregroundColor(tokens.textSecondary)
                }

                Spacer()

                if track.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .imageScale(.small)
                }

                if isCurrentTrack {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(tokens.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(track.isMissing ? 0.55 : 1.0)
        .trackRowAccessibility(
            title: track.isMissing ? "\(track.title), missing file" : track.title,
            artist: track.artist ?? "Unknown artist",
            isCurrent: isCurrentTrack, isPlaying: isPlaying
        )
    }

    @ViewBuilder
    private var artworkView: some View {
        if let url = track.artworkURL {
            AsyncCachedImage(url: url, targetSize: 48) {
                placeholderArtwork
            }
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
        ArtworkPlaceholder(tokens: tokens, cornerRadius: 6)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
