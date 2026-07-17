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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close player")

                    Spacer()

                    Button {
                        nav.presentedSheet = .queue
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.title3)
                            .foregroundColor(playerManager.queue.isEmpty
                                             ? themeManager.textSecondary
                                             : themeManager.textPrimary)
                            .frame(width: 44, height: 44)
                            // A real count badge: anchored to the frame's top-
                            // trailing corner and inset, so multi-digit counts
                            // grow leftward and stay inside the 44pt tap target
                            // instead of spilling into the neighbouring control.
                            .overlay(alignment: .topTrailing) {
                                if !playerManager.queue.isEmpty {
                                    Text(playerManager.queue.count > 99 ? "99+" : "\(playerManager.queue.count)")
                                        .scaledFont(size: 9, weight: .bold, relativeTo: .caption2)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(Capsule().fill(themeManager.theme.accentColor))
                                        .padding([.top, .trailing], 2)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(playerManager.queue.isEmpty ? "Show queue" : "Show queue, \(playerManager.queue.count) up next")
                }
                .padding(.top, DS.Spacing.sm)
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
                        .foregroundColor(themeManager.textSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, DS.Spacing.xl)
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
                    ArtworkPlaceholder(tokens: themeManager.tokens, cornerRadius: DS.Radius.md)
                }
                .aspectRatio(contentMode: .fit)
                .frame(width: side, height: side)
                .cornerRadius(DS.Radius.md)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 4)
            } else {
                ArtworkPlaceholder(tokens: themeManager.tokens, cornerRadius: DS.Radius.md)
                    .frame(width: side, height: side)
                    .cornerRadius(DS.Radius.md)
            }
        }
        .padding(.bottom, DS.Spacing.xl)
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
        .padding(.bottom, DS.Spacing.lg)
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
            // Native Slider announces a bare percentage; give VoiceOver a
            // meaningful position ("1:05 of 3:20") and an adjustable label.
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatTime(clock.currentTime)) of \(formatTime(clock.duration))")

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
        HStack(spacing: DS.Spacing.xxl) {
            Button { playerManager.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundColor(playerManager.isShuffled ? themeManager.theme.accentColor : themeManager.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(playerManager.isShuffled ? "Shuffle on" : "Shuffle off")

            Button { playerManager.previousTrack() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundColor(themeManager.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
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
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next track")

            Button { playerManager.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon)
                    .font(.title3)
                    .foregroundColor(playerManager.repeatMode != .off ? themeManager.theme.accentColor : themeManager.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Repeat mode: \(playerManager.repeatMode == .off ? "off" : playerManager.repeatMode == .one ? "one" : "all")")
        }
        .padding(.bottom, DS.Spacing.xl)
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
        HStack(spacing: 28) {
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
            .accessibilityLabel(favoritesManager.isFavorite(track) ? "Remove from favorites" : "Add to favorites")

            DownloadButton(track: track)

            Button { nav.presentedSheet = .addToPlaylist } label: {
                Image(systemName: "text.badge.plus")
                    .font(.title3)
                    .foregroundColor(themeManager.textPrimary)
            }
            .accessibilityLabel("Add to playlist")

            Button { nav.presentedSheet = .equalizer } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.title3)
                    .foregroundColor(themeManager.textPrimary)
            }
            .accessibilityLabel("Equalizer")

            Menu {
                ForEach(PlayerManager.playbackRatePresets, id: \.self) { rate in
                    Button {
                        playerManager.setPlaybackRate(rate)
                    } label: {
                        if playerManager.playbackRate == rate {
                            Label(speedLabel(rate), systemImage: "checkmark")
                        } else {
                            Text(speedLabel(rate))
                        }
                    }
                }
            } label: {
                Text(speedLabel(playerManager.playbackRate))
                    .scaledFont(size: 15, weight: .semibold, relativeTo: .subheadline)
                    .monospacedDigit()
                    .frame(minWidth: 34)
                    .foregroundColor(playerManager.playbackRate == 1.0
                                     ? themeManager.textPrimary
                                     : themeManager.theme.accentColor)
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(speedLabel(playerManager.playbackRate))

            // Share the actual song (watch URL), not the thumbnail image;
            // local files fall back to a "title — artist" text share.
            if let url = track.shareURL {
                ShareLink(
                    item: url,
                    subject: Text(track.title),
                    message: Text("\(track.title) — \(track.artist)")
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(themeManager.textPrimary)
                }
            } else {
                ShareLink(item: "\(track.title) — \(track.artist)") {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                        .foregroundColor(themeManager.textPrimary)
                }
            }
        }
        .padding(.bottom, DS.Spacing.xxl)
    }

    /// "1×", "0.5×", "1.25×" — `%g` trims trailing zeros.
    private func speedLabel(_ rate: Float) -> String {
        "\(String(format: "%g", Double(rate)))×"
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
