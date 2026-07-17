import SwiftUI

/// Renders one section of the library — a header (when grouping is on)
/// followed by the rows. Used inside `LibraryView`'s
/// `ScrollView { LazyVStack { ForEach(vm.sections) { ... } } }`.
struct LibrarySectionView: View {
    let section: LibrarySection
    let showHeader: Bool
    let tokens: DesignTokens
    let isCurrentTrack: (LocalTrack) -> Bool
    let isPlaying: Bool
    let onPlay: (LocalTrack) -> Void
    let onPlayNext: (LocalTrack) -> Void
    let onAddToQueue: (LocalTrack) -> Void
    let onAddToPlaylist: (LocalTrack) -> Void
    let onDelete: (LocalTrack) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showHeader && !section.title.isEmpty {
                Text(section.title)
                    .font(.headline)
                    .foregroundColor(tokens.textPrimary)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            ForEach(section.tracks) { track in
                LibraryTrackRow(
                    track: track,
                    isCurrentTrack: isCurrentTrack(track),
                    isPlaying: isPlaying,
                    tokens: tokens,
                    onTap: { onPlay(track) }
                )
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(tokens.cardSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contextMenu {
                    Button {
                        onPlay(track)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    if !track.isMissing {
                        Button {
                            onPlayNext(track)
                        } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            onAddToQueue(track)
                        } label: {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                        }
                    }
                    Button {
                        onAddToPlaylist(track)
                    } label: {
                        Label("Add to Playlist", systemImage: "text.badge.plus")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete(track)
                    } label: {
                        Label("Delete from Library", systemImage: "trash")
                    }
                }
            }
        }
    }
}
