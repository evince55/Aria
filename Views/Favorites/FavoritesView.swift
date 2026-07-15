import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var addToPlaylistTrack: Track?

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()

            if favoritesManager.tracks.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    shuffleButton
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.md)
                        .padding(.bottom, DS.Spacing.lg)

                    listContent
                }
            }
        }
        .sheet(item: $addToPlaylistTrack) { track in
            addToPlaylistSheet(for: track)
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [tokens.accent.opacity(0.35), tokens.accent.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                Image(systemName: "heart.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(tokens.accent)
            }
            .softShadow()

            VStack(spacing: DS.Spacing.sm) {
                Text("No Favorites Yet")
                    .font(DS.Typography.titleLarge)
                    .foregroundColor(tokens.textPrimary)
                Text("Tap the heart on any song to add it here.")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Spacing.xl)

            Spacer()
        }
        .padding(.bottom, 80)
    }

    private var shuffleButton: some View {
        Button {
            Haptics.medium()
            let tracks = favoritesManager.tracks.shuffled()
            guard !tracks.isEmpty else { return }
            playerManager.playSlice(tracks, startIndex: 0)
            recentlyPlayedManager.trackPlayed(tracks[0])
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .bold))
                Text("Shuffle Play")
                    .font(DS.Typography.bodyEm)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.md)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tokens.accent, tokens.accent.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .softShadow()
        }
        .buttonStyle(.plain)
    }

    private var listContent: some View {
        List {
            ForEach(favoritesManager.groupedByLetter(), id: \.letter) { group in
                Section {
                    ForEach(group.tracks) { track in
                        trackRow(track)
                            .listRowBackground(tokens.background)
                            .listRowSeparatorTint(tokens.hairline)
                            .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.lg, bottom: 4, trailing: DS.Spacing.lg))
                    }
                    .onDelete { offsets in
                        guard let idx = offsets.first else { return }
                        let track = group.tracks[idx]
                        Haptics.warning()
                        favoritesManager.remove(track)
                    }
                } header: {
                    HStack {
                        SectionLabel(title: group.letter, tokens: tokens)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.xs)
                }
            }

            Section {
                Color.clear.frame(height: 80)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 0) {
            Button {
                Haptics.light()
                let allTracks = favoritesManager.groupedByLetter().flatMap { $0.tracks }
                let idx = allTracks.firstIndex(where: { $0.id == track.id }) ?? 0
                playerManager.playSlice(allTracks, startIndex: idx)
                recentlyPlayedManager.trackPlayed(track)
            } label: {
                HStack(spacing: DS.Spacing.sm) {
                    TrackThumbnail(url: track.thumbnailURL, size: 48, cornerRadius: DS.Radius.sm, tokens: tokens)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(DS.Typography.bodyEm)
                            .lineLimit(1)
                            .foregroundColor(playerManager.currentTrack?.id == track.id ? tokens.accent : tokens.textPrimary)
                        HStack(spacing: 4) {
                            if playerManager.currentTrack?.id == track.id {
                                NowPlayingIndicator(isPlaying: playerManager.isPlaying, accent: tokens.accent)
                            }
                            Text(track.artist)
                                .font(DS.Typography.caption)
                                .lineLimit(1)
                                .foregroundColor(tokens.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trackMenu(track)
        }
        .addToQueueGesture(playerManager: playerManager, track: track)
        .trackRowAccessibility(
            title: track.title, artist: track.artist,
            isCurrent: playerManager.currentTrack?.id == track.id,
            isPlaying: playerManager.isPlaying
        )
    }

    /// The row's action menu — the ellipsis used to be decorative; now it
    /// carries the actions users expect from a favorites row.
    private func trackMenu(_ track: Track) -> some View {
        Menu {
            Button {
                Haptics.medium()
                playerManager.addToQueue(track)
            } label: {
                Label("Add to Queue", systemImage: "text.badge.plus")
            }
            Button {
                addToPlaylistTrack = track
            } label: {
                Label("Add to Playlist", systemImage: "music.note.list")
            }
            if let url = track.shareURL {
                ShareLink(item: url, subject: Text(track.title),
                          message: Text("\(track.title) — \(track.artist)")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            } else {
                ShareLink(item: "\(track.title) — \(track.artist)") {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                Haptics.warning()
                favoritesManager.remove(track)
            } label: {
                Label("Remove from Favorites", systemImage: "heart.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(tokens.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions for \(track.title)")
    }

    /// Same pattern as the full-screen player's sheet, but for an explicit
    /// track (not the currently playing one).
    private func addToPlaylistSheet(for track: Track) -> some View {
        NavigationStack {
            Group {
                if playlistsManager.playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Playlists")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Create a playlist first")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    List(playlistsManager.playlists) { playlist in
                        Button {
                            playlistsManager.addTrack(track, to: playlist)
                            recentlyPlayedManager.trackAdded(track)
                            addToPlaylistTrack = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                        .font(.body)
                                    Text("\(playlist.tracks.count) tracks")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundColor(themeManager.theme.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { addToPlaylistTrack = nil }
                }
            }
        }
    }
}
