import SwiftUI

struct FullScreenPlayerView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var clock: PlaybackClock
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var nav: NavigationCoordinator

    var onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    private let dragThreshold: CGFloat = 120

    var body: some View {
        ZStack {
            themeManager.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3)
                            .foregroundColor(themeManager.textPrimary)
                    }
                    .accessibilityLabel("Close player")

                    Spacer()

                    Button {
                        nav.presentedSheet = .queue
                    } label: {
                        if !playerManager.queue.isEmpty {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "list.bullet")
                                    .font(.title3)
                                    .foregroundColor(themeManager.textPrimary)
                                Text("\(playerManager.queue.count)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(themeManager.theme.accentColor)
                                    .offset(x: 10, y: -2)
                            }
                        } else {
                            Image(systemName: "list.bullet")
                                .font(.title3)
                                .foregroundColor(themeManager.textSecondary)
                        }
                    }
                    .accessibilityLabel("Show queue")
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 20)

                if let track = playerManager.currentTrack {
                    artworkSection(track: track)
                    trackInfoSection(track: track)
                    seekBarSection
                    transportControls
                    secondaryControls(track: track)
                    if playerManager.playbackState == .loading {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(themeManager.theme.accentColor)
                            .padding(.top, 8)
                    }
                } else {
                    Spacer()
                    Text("No track playing")
                        .foregroundColor(.secondary)
                    Spacer()
                }

                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .offset(y: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height > 0 {
                        dragOffset = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height > dragThreshold {
                        onDismiss()
                    }
                    withAnimation(.spring(response: 0.3)) {
                        dragOffset = 0
                    }
                }
        )
        .sheet(item: $nav.presentedSheet) { sheet in
            switch sheet {
            case .equalizer:
                EqualizerView()
            case .addToPlaylist:
                addToPlaylistSheet
            case .queue:
                QueueView()
            case .missingTrackRepair:
                EmptyView()
            }
        }
    }

    // MARK: - Artwork

    private func artworkSection(track: Track) -> some View {
        let side: CGFloat = 290

        return Group {
            if let url = playerManager.currentArtworkURL {
                AsyncCachedImage(url: url, targetSize: side) {
                    Rectangle()
                        .fill(themeManager.dividerColor)
                }
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
            } else {
                Rectangle()
                    .fill(themeManager.dividerColor)
                    .frame(width: side, height: side)
                    .cornerRadius(12)
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - Track Info

    private func trackInfoSection(track: Track) -> some View {
        VStack(spacing: 4) {
            Text(track.title)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(themeManager.textPrimary)

            Text(track.artist)
                .font(.body)
                .foregroundColor(themeManager.textSecondary)
        }
        .padding(.bottom, 16)
    }

    // MARK: - Seek Bar

    private var seekBarSection: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { clock.currentTime },
                    set: { playerManager.seek(to: $0) }
                ),
                in: 0...max(clock.duration, 1)
            ) {
                Text("Seek")
            }
            .tint(themeManager.theme.accentColor)

            HStack {
                Text(formatTime(clock.currentTime))
                    .font(.caption2)
                    .foregroundColor(themeManager.textSecondary)
                Spacer()
                if playerManager.isRebuffering {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Buffering…")
                            .font(.caption2)
                            .foregroundColor(themeManager.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Buffering")
                    Spacer()
                }
                Text("-\(formatTime(max(0, clock.duration - clock.currentTime)))")
                    .font(.caption2)
                    .foregroundColor(themeManager.textSecondary)
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 32) {
            Button { playerManager.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(playerManager.isShuffled ? themeManager.theme.accentColor : themeManager.textPrimary)
            }
            .accessibilityLabel(playerManager.isShuffled ? "Shuffle on" : "Shuffle off")

            Button { playerManager.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundColor(themeManager.textPrimary)
            }
            .accessibilityLabel("Previous track")

            Button { playerManager.togglePlayPause() } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .foregroundColor(themeManager.textPrimary)
            }
            .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")

            Button { playerManager.nextTrack() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundColor(themeManager.textPrimary)
            }
            .accessibilityLabel("Next track")

            Button { playerManager.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon)
                    .font(.title3)
                    .foregroundColor(playerManager.repeatMode != .off ? themeManager.theme.accentColor : themeManager.textPrimary)
            }
            .accessibilityLabel("Repeat mode: \(playerManager.repeatMode == .off ? "off" : playerManager.repeatMode == .one ? "one" : "all")")
        }
        .padding(.bottom, 24)
    }

    private var repeatIcon: String {
        switch playerManager.repeatMode {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }

    // MARK: - Secondary Controls

    private func secondaryControls(track: Track) -> some View {
        HStack(spacing: 40) {
            Button {
                favoritesManager.toggle(track)
                if favoritesManager.isFavorite(track) {
                    recentlyPlayedManager.trackAdded(track)
                }
            } label: {
                Image(systemName: favoritesManager.isFavorite(track) ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundColor(favoritesManager.isFavorite(track) ? .red : themeManager.textPrimary)
            }

            Button { nav.presentedSheet = .addToPlaylist } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
                    .foregroundColor(themeManager.textPrimary)
            }

            Button { nav.presentedSheet = .equalizer } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundColor(themeManager.textPrimary)
            }

            if let url = playerManager.currentTrack?.thumbnailURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(themeManager.textPrimary)
                }
            }
        }
        .padding(.bottom, 32)
    }

    // MARK: - Add to Playlist Sheet

    private var addToPlaylistSheet: some View {
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
                            if let track = playerManager.currentTrack {
                                playlistsManager.addTrack(track, to: playlist)
                                recentlyPlayedManager.trackAdded(track)
                                nav.presentedSheet = nil
                            }
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
                    Button("Done") { nav.presentedSheet = nil }
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let t = Int(max(0, time))
        let m = t / 60
        let s = t % 60
        return String(format: "%d:%02d", m, s)
    }
}
