import SwiftUI

/// Live view of a smart playlist: rules re-evaluate against the current
/// library every render, so the list is always fresh — nothing is snapshotted.
struct SmartPlaylistDetailView: View {
    let playlistID: String

    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var smartPlaylistsManager: SmartPlaylistsManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var localLibraryManager: LocalLibraryManager
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var proStore: ProStore
    @Environment(\.dismiss) private var dismiss

    @State private var editorDraft: SmartPlaylist?
    @State private var showPaywall = false

    private var tokens: DesignTokens { themeManager.tokens }

    private var playlist: SmartPlaylist? {
        smartPlaylistsManager.playlists.first { $0.id == playlistID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()
                if let playlist {
                    content(playlist)
                } else {
                    // Deleted while open — nothing to show.
                    Text("Smart playlist deleted")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                }
            }
            .navigationTitle(playlist?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.light()
                        if proStore.isPro, let playlist {
                            editorDraft = playlist
                        } else {
                            showPaywall = true
                        }
                    } label: {
                        Text("Edit")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(item: $editorDraft) { draft in
            SmartPlaylistEditorView(draft: draft)
        }
        .sheet(isPresented: $showPaywall) {
            AriaProView()
        }
    }

    @ViewBuilder
    private func content(_ playlist: SmartPlaylist) -> some View {
        let tracks = evaluated(playlist)
        VStack(spacing: 0) {
            header(playlist, tracks: tracks)
            if tracks.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(tokens.textSecondary)
                    Text("No matches yet")
                        .font(DS.Typography.titleMedium)
                        .foregroundColor(tokens.textPrimary)
                    Text("Tracks that satisfy the rules will appear here automatically.")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.xl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            row(track, index: index, all: tracks)
                        }
                    }
                    .padding(.vertical, DS.Spacing.sm)
                    .padding(.bottom, 100)
                }
            }
        }
    }

    private func header(_ playlist: SmartPlaylist, tracks: [Track]) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s") · live")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)

            HStack(spacing: DS.Spacing.md) {
                Button {
                    Haptics.medium()
                    playerManager.playSlice(tracks, startIndex: 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(DS.Typography.bodyEm)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(tokens.accent)
                        .foregroundColor(.white)
                        .cornerRadius(DS.Radius.md)
                }
                Button {
                    Haptics.medium()
                    playerManager.playSlice(tracks.shuffled(), startIndex: 0)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(DS.Typography.bodyEm)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(tokens.surface)
                        .foregroundColor(tokens.accent)
                        .cornerRadius(DS.Radius.md)
                }
            }
            .disabled(tracks.isEmpty)
            .padding(.horizontal, DS.Spacing.lg)
        }
        .padding(.top, DS.Spacing.sm)
        .padding(.bottom, DS.Spacing.sm)
    }

    private func row(_ track: Track, index: Int, all: [Track]) -> some View {
        let isCurrent = playerManager.currentTrack?.id == track.id
        return Button {
            Haptics.light()
            playerManager.playSlice(all, startIndex: index)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: 48, cornerRadius: DS.Radius.sm, tokens: tokens)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(DS.Typography.bodyEm)
                        .lineLimit(1)
                        .foregroundColor(isCurrent ? tokens.accent : tokens.textPrimary)
                    HStack(spacing: 4) {
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
                if let fileName = track.localFileURL?.lastPathComponent {
                    QualityBadge(AudioQuality.forFile(fileName: fileName, sizeBytes: 0,
                                                      durationSeconds: nil),
                                 tokens: tokens)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addToQueueGesture(playerManager: playerManager, track: track)
    }

    private func evaluated(_ playlist: SmartPlaylist) -> [Track] {
        SmartPlaylistEngine.evaluate(
            playlist,
            candidates: SmartPlaylistEngine.candidates(
                localTracks: localLibraryManager.tracks,
                fileURL: { localLibraryManager.fileURL(for: $0) },
                downloads: downloadManager.records,
                favorites: favoritesManager.tracks
            ),
            favoriteIDs: Set(favoritesManager.tracks.map(\.id)),
            recentlyPlayedIDs: Set(recentlyPlayedManager.recentlyPlayed.map(\.id))
        )
    }
}
