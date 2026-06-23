import SwiftUI

struct FullScreenPlayerView: View {
    @ObservedObject var playerManager: PlayerManager
    @ObservedObject var favoritesManager: FavoritesManager
    @ObservedObject var playlistsManager: PlaylistsManager
    @ObservedObject var recentlyPlayedManager: RecentlyPlayedManager
    @ObservedObject var themeManager: ThemeManager

    var namespace: Namespace.ID
    var onDismiss: () -> Void

    @State private var showEQ = false
    @State private var showAddToPlaylist = false
    @State private var showQueue = false
    @State private var dragOffset: CGFloat = 0

    private let dragThreshold: CGFloat = 120

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        GeometryReader { geometry in
            let isPortrait = geometry.size.height >= geometry.size.width

            ZStack {
                ArtworkBackdrop(
                    artworkURL: playerManager.currentTrack?.thumbnailURL,
                    tokens: tokens
                )

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, DS.Spacing.xl)
                        .padding(.top, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.lg)

                    if let track = playerManager.currentTrack {
                        if isPortrait {
                            portraitLayout(track: track, size: geometry.size)
                        } else {
                            landscapeLayout(track: track, size: geometry.size)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding(.horizontal, isPortrait ? DS.Spacing.xl : DS.Spacing.lg)
            }
            .offset(y: dragOffset)
            .scaleEffect(scaleForDrag)
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = rubberBanded(value.translation.height)
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > dragThreshold {
                            onDismiss()
                        }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
            )
        }
        .background(Color.clear)
        .sheet(isPresented: $showEQ) {
            EqualizerView(playerManager: playerManager, themeManager: themeManager)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            addToPlaylistSheet
        }
        .sheet(isPresented: $showQueue) {
            QueueView(playerManager: playerManager, themeManager: themeManager)
        }
    }

    // MARK: - Layouts

    private func portraitLayout(track: Track, size: CGSize) -> some View {
        VStack(spacing: 0) {
            artworkView(track: track, side: artworkSideForPortrait(size: size))
                .padding(.bottom, DS.Spacing.lg)

            trackInfoSection(track: track)

            Spacer(minLength: DS.Spacing.sm)

            seekBarSection
            transportControls
            secondaryControls(track: track)
        }
    }

    private func landscapeLayout(track: Track, size: CGSize) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.lg) {
            artworkView(track: track, side: artworkSideForLandscape(size: size))

            VStack(spacing: 0) {
                trackInfoSection(track: track)
                Spacer(minLength: DS.Spacing.sm)
                seekBarSection
                transportControls
                secondaryControls(track: track)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Artwork sizing

    private func artworkSideForPortrait(size: CGSize) -> CGFloat {
        // Cap by the screen width (with some padding) and by ~50% of the
        // available height so the artwork dominates without crowding the
        // controls at the bottom.
        let byWidth = min(size.width, 420) - DS.Spacing.xl * 2
        let byHeight = size.height * 0.46
        return max(180, min(byWidth, byHeight, 380))
    }

    private func artworkSideForLandscape(size: CGSize) -> CGFloat {
        // In landscape, the artwork is a square sized primarily by the
        // screen height so it never overflows vertically.
        let byHeight = size.height * 0.78
        let byWidth = size.width * 0.42
        return max(160, min(byHeight, byWidth, 360))
    }

    // MARK: - Drag math

    private var scaleForDrag: CGFloat {
        let f = min(1, dragOffset / 600)
        return 1 - f * 0.04
    }

    private func rubberBanded(_ raw: CGFloat) -> CGFloat {
        let dim: CGFloat = 600
        let factor: CGFloat = 0.55
        if raw < 0 { return raw }
        if raw < dim {
            return raw * factor
        }
        let extra = raw - dim
        return dim * factor + extra * 0.25
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(tokens.textPrimary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss player")

            Spacer()

            Capsule()
                .fill(Color.primary.opacity(0.25))
                .frame(width: 36, height: 5)
                .padding(.bottom, 18)

            Spacer()

            queueButton
        }
    }

    private var queueButton: some View {
        Button {
            showQueue = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 14, weight: .semibold))
                if !playerManager.queue.isEmpty {
                    Text("\(playerManager.queue.count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .foregroundColor(tokens.textPrimary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(tokens.accentSubtle)
            )
            .overlay(
                Capsule()
                    .stroke(tokens.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up next queue")
    }

    // MARK: - Artwork

    private func artworkView(track: Track, side: CGFloat) -> some View {
        Group {
            if let url = track.thumbnailURL {
                AsyncCachedImage(url: url, cornerRadius: DS.Radius.lg) {
                    ShimmerView(cornerRadius: DS.Radius.lg)
                }
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .fill(tokens.dividerColor)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 60, weight: .light))
                            .foregroundColor(.secondary)
                    )
            }
        }
        .frame(width: side, height: side)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
        )
        .cardShadow()
        .matchedGeometryEffect(id: "playerArtwork", in: namespace)
    }

    // MARK: - Track Info

    private func trackInfoSection(track: Track) -> some View {
        VStack(spacing: 4) {
            Text(track.title)
                .font(DS.Typography.display)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundColor(tokens.textPrimary)
                .frame(maxWidth: .infinity)

            Text(track.artist)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textSecondary)
                .lineLimit(1)
        }
        .padding(.bottom, DS.Spacing.lg)
    }

    // MARK: - Seek Bar

    private var seekBarSection: some View {
        VStack(spacing: 6) {
            ThinSlider(
                value: Binding(
                    get: { playerManager.currentTime },
                    set: { playerManager.seek(to: $0) }
                ),
                in: 0...max(playerManager.duration, 1),
                accent: tokens.accent
            )
            .frame(height: 22)

            HStack {
                Text(formatTime(playerManager.currentTime))
                    .font(DS.Typography.mono)
                    .foregroundColor(tokens.textSecondary)
                Spacer()
                Text("-\(formatTime(max(0, playerManager.duration - playerManager.currentTime)))")
                    .font(DS.Typography.mono)
                    .foregroundColor(tokens.textSecondary)
            }
        }
        .padding(.bottom, DS.Spacing.lg)
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 28) {
            transportButton(systemImage: shuffleIcon(), isActive: playerManager.isShuffled) {
                Haptics.light()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    playerManager.toggleShuffle()
                }
            }
            .accessibilityLabel(playerManager.isShuffled ? "Shuffle on" : "Shuffle off")

            transportButton(systemImage: "backward.fill", font: .system(size: 28, weight: .regular)) {
                Haptics.light()
                playerManager.previousTrack()
            }
            .accessibilityLabel("Previous track")

            playButton

            transportButton(systemImage: "forward.fill", font: .system(size: 28, weight: .regular)) {
                Haptics.light()
                playerManager.nextTrack()
            }
            .accessibilityLabel("Next track")

            transportButton(systemImage: repeatIcon(), isActive: playerManager.repeatMode != .off) {
                Haptics.light()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    playerManager.cycleRepeatMode()
                }
            }
            .accessibilityLabel("Repeat mode: \(playerManager.repeatMode == .off ? "off" : playerManager.repeatMode == .one ? "one" : "all")")
        }
        .padding(.bottom, DS.Spacing.lg)
    }

    private func shuffleIcon() -> String { "shuffle" }

    private func repeatIcon() -> String {
        switch playerManager.repeatMode {
        case .off: return "repeat"
        case .one: return "repeat.1"
        case .all: return "repeat"
        }
    }

    private var playButton: some View {
        Button {
            Haptics.medium()
            playerManager.togglePlayPause()
        } label: {
            ZStack {
                Circle()
                    .fill(tokens.playButtonBackground)
                    .frame(width: 76, height: 76)

                if playerManager.playbackState == .loading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(tokens.textPrimary)
                        .scaleEffect(1.15)
                } else {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundColor(tokens.textPrimary)
                        .transition(.opacity)
                        .id(playerManager.isPlaying)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")
    }

    private func transportButton(
        systemImage: String,
        font: Font = .system(size: 18, weight: .semibold),
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if isActive {
                    Circle()
                        .fill(tokens.accentSubtle)
                        .frame(width: 40, height: 40)
                }
                Image(systemName: systemImage)
                    .font(font)
                    .foregroundColor(isActive ? tokens.accent : tokens.textPrimary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Secondary Controls

    private func secondaryControls(track: Track) -> some View {
        HStack(spacing: 32) {
            secondaryButton(systemImage: favoritesManager.isFavorite(track) ? "heart.fill" : "heart",
                            tint: favoritesManager.isFavorite(track) ? .red : tokens.textPrimary) {
                Haptics.medium()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    favoritesManager.toggle(track)
                }
                if favoritesManager.isFavorite(track) {
                    recentlyPlayedManager.trackAdded(track)
                }
            }
            .accessibilityLabel(favoritesManager.isFavorite(track) ? "Remove from favorites" : "Add to favorites")

            secondaryButton(systemImage: "text.badge.plus", tint: tokens.textPrimary) {
                Haptics.light()
                showAddToPlaylist = true
            }
            .accessibilityLabel("Add to playlist")

            secondaryButton(systemImage: "slider.horizontal.3", tint: tokens.textPrimary) {
                Haptics.light()
                showEQ = true
            }
            .accessibilityLabel("Open equalizer")

            if let url = playerManager.currentTrack?.thumbnailURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(tokens.textPrimary)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
            } else {
                secondaryButton(systemImage: "square.and.arrow.up", tint: tokens.textPrimary) {}
                    .opacity(0.3)
                    .disabled(true)
            }
        }
    }

    private func secondaryButton(
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 140, height: 140)
                Image(systemName: "music.note")
                    .font(.system(size: 56, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            .softShadow()
            Text("Nothing Playing")
                .font(DS.Typography.titleLarge)
                .foregroundColor(tokens.textPrimary)
            Text("Search for a track to start listening.")
                .font(DS.Typography.body)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Add to Playlist Sheet

    private var addToPlaylistSheet: some View {
        NavigationStack {
            Group {
                if playlistsManager.playlists.isEmpty {
                    VStack(spacing: DS.Spacing.lg) {
                        ZStack {
                            Circle()
                                .fill(tokens.accentSubtle)
                                .frame(width: 90, height: 90)
                            Image(systemName: "music.note.list")
                                .font(.system(size: 36))
                                .foregroundColor(tokens.accent)
                        }
                        Text("No Playlists")
                            .font(DS.Typography.titleLarge)
                            .foregroundColor(tokens.textPrimary)
                        Text("Create a playlist first in the Playlists tab")
                            .font(DS.Typography.body)
                            .foregroundColor(tokens.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(DS.Spacing.xl)
                } else {
                    List(playlistsManager.playlists) { playlist in
                        Button {
                            if let track = playerManager.currentTrack {
                                playlistsManager.addTrack(track, to: playlist)
                                recentlyPlayedManager.trackAdded(track)
                                showAddToPlaylist = false
                            }
                        } label: {
                            HStack(spacing: DS.Spacing.md) {
                                Group {
                                    if let url = playlist.previewThumbnailURL {
                                        AsyncCachedImage(url: url, cornerRadius: DS.Radius.sm) {
                                            ShimmerView(cornerRadius: DS.Radius.sm)
                                        }
                                    } else {
                                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                            .fill(tokens.accentSubtle)
                                            .overlay(
                                                Image(systemName: "music.note.list")
                                                    .font(.system(size: 16))
                                                    .foregroundColor(tokens.accent)
                                            )
                                    }
                                }
                                .frame(width: 44, height: 44)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(DS.Typography.bodyEm)
                                        .foregroundColor(tokens.textPrimary)
                                    Text("\(playlist.tracks.count) tracks")
                                        .font(DS.Typography.caption)
                                        .foregroundColor(tokens.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(tokens.accent)
                                    .font(.system(size: 22))
                            }
                            .contentShape(Rectangle())
                        }
                        .listRowBackground(tokens.background)
                        .listRowSeparatorTint(tokens.hairline)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(tokens.background)
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showAddToPlaylist = false }
                        .foregroundColor(tokens.accent)
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
