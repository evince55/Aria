import SwiftUI

struct PlaylistDetailView: View {
    @ObservedObject var playerManager: PlayerManager
    @ObservedObject var playlistsManager: PlaylistsManager
    @ObservedObject var recentlyPlayedManager: RecentlyPlayedManager
    @ObservedObject var themeManager: ThemeManager

    let playlist: Playlist

    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false
    @State private var renameText = ""
    @Environment(\.dismiss) private var dismiss

    private var currentPlaylist: Playlist {
        playlistsManager.playlists.first(where: { $0.id == playlist.id }) ?? playlist
    }
    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                if currentPlaylist.tracks.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        heroHeader
                        actionRow
                        trackList
                    }
                }
            }
            .navigationTitle(currentPlaylist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            renameText = currentPlaylist.name
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Label("Delete Playlist", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18))
                            .foregroundColor(tokens.textPrimary)
                    }
                }
            }
            .alert("Rename Playlist", isPresented: $showRenameAlert) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    Haptics.success()
                    playlistsManager.rename(currentPlaylist, to: trimmed)
                }
            }
            .alert("Delete Playlist", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Haptics.warning()
                    playlistsManager.delete(currentPlaylist)
                    dismiss()
                }
            } message: {
                Text("This will permanently delete \"\(currentPlaylist.name)\". This action cannot be undone.")
            }
        }
    }

    private var heroHeader: some View {
        VStack(spacing: DS.Spacing.md) {
            Group {
                if let url = currentPlaylist.previewThumbnailURL {
                    AsyncCachedImage(url: url, cornerRadius: DS.Radius.lg) {
                        ShimmerView(cornerRadius: DS.Radius.lg)
                    }
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [tokens.accent.opacity(0.5), tokens.accent.opacity(0.15)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "music.note.list")
                            .font(.system(size: 60, weight: .light))
                            .foregroundColor(tokens.accent)
                    }
                }
            }
            .frame(width: 180, height: 180)
            .softShadow()

            VStack(spacing: 2) {
                Text(currentPlaylist.name)
                    .font(DS.Typography.titleLarge)
                    .foregroundColor(tokens.textPrimary)
                    .multilineTextAlignment(.center)
                Text("\(currentPlaylist.tracks.count) tracks")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            }
        }
        .padding(.top, DS.Spacing.lg)
        .padding(.horizontal, DS.Spacing.lg)
    }

    private var actionRow: some View {
        HStack(spacing: DS.Spacing.md) {
            actionPill(systemImage: "play.fill", label: "Play", filled: true) {
                Haptics.medium()
                if let first = currentPlaylist.tracks.first {
                    playerManager.play(first)
                    recentlyPlayedManager.trackPlayed(first)
                    playlistsManager.markPlayed(currentPlaylist)
                }
            }

            actionPill(systemImage: "shuffle", label: "Shuffle", filled: false) {
                Haptics.medium()
                if let random = currentPlaylist.tracks.randomElement() {
                    playerManager.play(random)
                    recentlyPlayedManager.trackPlayed(random)
                    playlistsManager.markPlayed(currentPlaylist)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.top, DS.Spacing.lg)
        .padding(.bottom, DS.Spacing.md)
    }

    private func actionPill(systemImage: String, label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                Text(label)
                    .font(DS.Typography.bodyEm)
            }
            .foregroundColor(filled ? .white : tokens.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.md)
            .background(
                Capsule()
                    .fill(filled
                          ? LinearGradient(colors: [tokens.accent, tokens.accent.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [tokens.surface, tokens.surface], startPoint: .leading, endPoint: .trailing))
            )
            .overlay(
                Capsule()
                    .stroke(tokens.hairline, lineWidth: filled ? 0 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 120, height: 120)
                Image(systemName: "music.note.list")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            .softShadow()
            VStack(spacing: DS.Spacing.sm) {
                Text("No Tracks")
                    .font(DS.Typography.titleLarge)
                    .foregroundColor(tokens.textPrimary)
                Text("Add songs to this playlist from search or now playing.")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Spacing.xl)
            Spacer()
        }
    }

    private var trackList: some View {
        List {
            ForEach(currentPlaylist.tracks) { track in
                Button {
                    Haptics.light()
                    playerManager.play(track)
                    recentlyPlayedManager.trackPlayed(track)
                    playlistsManager.markPlayed(currentPlaylist)
                } label: {
                    HStack(spacing: DS.Spacing.md) {
                        NowPlayingLeadingBar(isCurrent: playerManager.currentTrack?.id == track.id, accent: tokens.accent)
                        TrackThumbnail(url: track.thumbnailURL, size: 48, cornerRadius: DS.Radius.sm)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(DS.Typography.bodyEm)
                                .lineLimit(1)
                                .foregroundColor(playerManager.currentTrack?.id == track.id ? tokens.accent : tokens.textPrimary)
                            HStack(spacing: 6) {
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
                .addToQueueGesture(playerManager: playerManager, track: track)
                .listRowBackground(tokens.background)
                .listRowSeparatorTint(tokens.hairline)
                .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.lg, bottom: 4, trailing: DS.Spacing.lg))
            }
            .onDelete { offsets in
                for idx in offsets.sorted(by: >) {
                    playlistsManager.removeTrack(currentPlaylist.tracks[idx], from: currentPlaylist)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
