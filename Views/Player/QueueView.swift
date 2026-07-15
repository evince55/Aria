import SwiftUI

struct QueueView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @Environment(\.dismiss) private var dismiss

    @State private var showSaveDialog = false
    @State private var newPlaylistName = ""

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                if playerManager.queue.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        trackCount
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.sm)

                        queueList
                    }
                }
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(tokens.accent)
                }
                if !playerManager.queue.isEmpty {
                    ToolbarItemGroup(placement: .primaryAction) {
                        EditButton()
                            .foregroundColor(tokens.accent)
                        Menu {
                            Button {
                                newPlaylistName = ""
                                showSaveDialog = true
                            } label: {
                                Label("Save as Playlist", systemImage: "square.and.arrow.down")
                            }
                            Button(role: .destructive) {
                                Haptics.warning()
                                playerManager.clearQueue()
                            } label: {
                                Label("Clear Queue", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(tokens.accent)
                        }
                    }
                }
            }
            .alert("Save as Playlist", isPresented: $showSaveDialog) {
                TextField("Playlist name", text: $newPlaylistName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { saveQueueAsPlaylist() }
            } message: {
                Text("Saves the current track and everything up next.")
            }
        }
    }

    /// Snapshot the current track + up-next queue into a new playlist.
    private func saveQueueAsPlaylist() {
        let tracks = ([playerManager.currentTrack].compactMap { $0 }) + playerManager.queue
        guard !tracks.isEmpty else { return }
        let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "New Playlist" : trimmed
        playlistsManager.create(name: name, tracks: tracks)
        Haptics.success()
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [tokens.accent.opacity(0.30), tokens.accent.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 50, weight: .light))
                    .foregroundColor(tokens.accent)
            }
            .softShadow()
            VStack(spacing: DS.Spacing.sm) {
                Text("Queue is Empty")
                    .font(DS.Typography.titleLarge)
                    .foregroundColor(tokens.textPrimary)
                Text("Long press on a song to add it to the queue")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, DS.Spacing.xl)
            Spacer()
        }
    }

    private var trackCount: some View {
        HStack {
            Text("\(playerManager.queue.count) track\(playerManager.queue.count == 1 ? "" : "s")")
                .font(DS.Typography.captionStrong)
                .foregroundColor(tokens.textSecondary)
            Spacer()
        }
    }

    private var queueList: some View {
        List {
            ForEach(Array(playerManager.queue.enumerated()), id: \.element.id) { index, track in
                Button {
                    Haptics.light()
                    playerManager.playFromQueue(at: index)
                    if playerManager.queue.isEmpty {
                        dismiss()
                    }
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        Text("\(index + 1)")
                            .font(DS.Typography.captionStrong)
                            .foregroundColor(tokens.textSecondary)
                            .frame(width: 24)

                        TrackThumbnail(url: track.thumbnailURL, size: 44, cornerRadius: DS.Radius.sm, tokens: tokens)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(DS.Typography.bodyEm)
                                .lineLimit(1)
                                .foregroundColor(tokens.textPrimary)
                            Text(track.artist)
                                .font(DS.Typography.caption)
                                .lineLimit(1)
                                .foregroundColor(tokens.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(tokens.background)
                .listRowSeparatorTint(tokens.hairline)
                .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.lg, bottom: 4, trailing: DS.Spacing.lg))
            }
            .onDelete { offsets in
                for idx in offsets.sorted(by: >) {
                    playerManager.removeFromQueue(at: idx)
                }
            }
            .onMove { offsets, destination in
                playerManager.moveInQueue(from: offsets, to: destination)
            }

            Section {
                Color.clear.frame(height: 60)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
