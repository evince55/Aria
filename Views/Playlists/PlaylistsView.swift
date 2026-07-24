import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var smartPlaylistsManager: SmartPlaylistsManager
    @EnvironmentObject private var proStore: ProStore

    @State private var selectedTab: PlaylistTab = .recentlyAdded
    @State private var smartEditorDraft: SmartPlaylist?
    @State private var selectedSmart: SmartPlaylist?
    @State private var showSmartPaywall = false
    @State private var smartDeleteTarget: SmartPlaylist?
    @State private var showSmartDeleteAlert = false
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var selectedPlaylist: Playlist?
    @State private var renameTarget: Playlist?
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var deleteTarget: Playlist?
    @State private var showDeleteAlert = false

    @Namespace private var tabIndicator

    private var tokens: DesignTokens { themeManager.tokens }

    enum PlaylistTab: String, CaseIterable {
        case recentlyAdded = "Recently Added"
        case recentlyPlayed = "Recently Played"
    }

    var body: some View {
        ZStack {
            tokens.background.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerBar
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.md)

                    recentPlaylistsSection

                    tabPicker
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.lg)

                    tabContent
                        .padding(.top, DS.Spacing.sm)

                    smartPlaylistsSection
                        .padding(.top, DS.Spacing.xl)

                    yourPlaylistsSection
                        .padding(.top, DS.Spacing.xl)
                }
                .padding(.bottom, 100)
            }
        }
        .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") {
                let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                Haptics.success()
                _ = playlistsManager.create(name: trimmed)
                newPlaylistName = ""
            }
        }
        .sheet(item: $selectedPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .sheet(item: $smartEditorDraft) { draft in
            SmartPlaylistEditorView(draft: draft)
        }
        .sheet(item: $selectedSmart) { playlist in
            SmartPlaylistDetailView(playlistID: playlist.id)
        }
        .sheet(isPresented: $showSmartPaywall) {
            AriaProView()
        }
        .alert("Delete Smart Playlist", isPresented: $showSmartDeleteAlert) {
            Button("Cancel", role: .cancel) { smartDeleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = smartDeleteTarget {
                    Haptics.warning()
                    smartPlaylistsManager.delete(target)
                }
                smartDeleteTarget = nil
            }
        } message: {
            Text("This deletes the rules for “\(smartDeleteTarget?.name ?? "")”. Your tracks are not affected.")
        }
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Playlist name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let target = renameTarget, !trimmed.isEmpty {
                    Haptics.success()
                    playlistsManager.rename(target, to: trimmed)
                }
                renameTarget = nil
            }
        }
        .alert("Delete Playlist", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    Haptics.warning()
                    playlistsManager.delete(target)
                }
                deleteTarget = nil
            }
        } message: {
            Text("This permanently deletes “\(deleteTarget?.name ?? "")”. This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Playlists")
                    .font(DS.Typography.display)
                    .foregroundColor(tokens.textPrimary)
                Text("\(playlistsManager.playlists.count) created")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
            }
            Spacer()
            Menu {
                ForEach(PlaylistSortOrder.allCases, id: \.self) { order in
                    Button {
                        Haptics.selection()
                        playlistsManager.sortOrder = order
                    } label: {
                        HStack {
                            Text(order.rawValue)
                            if playlistsManager.sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(tokens.textPrimary)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(tokens.surface)
                    )
            }
            .accessibilityLabel("Sort playlists")

            Button {
                Haptics.light()
                showNewPlaylistAlert = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(tokens.accent)
                    )
            }
            .accessibilityLabel("New playlist")
        }
    }

    // MARK: - Recent Playlists

    private var recentPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if !playlistsManager.recentlyPlayedPlaylists.isEmpty {
                SectionLabel(title: "Recently played", tokens: tokens)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.lg)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DS.Spacing.md) {
                        ForEach(playlistsManager.recentlyPlayedPlaylists) { playlist in
                            playlistCard(playlist)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                }
            }
        }
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        Button {
            Haptics.light()
            playlistsManager.markPlayed(playlist)
            selectedPlaylist = playlist
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Group {
                    if let url = playlist.previewThumbnailURL {
                        AsyncCachedImage(url: url, cornerRadius: DS.Radius.md, targetSize: 130) {
                            ArtworkPlaceholder(tokens: tokens, cornerRadius: DS.Radius.md)
                        }
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [tokens.accent.opacity(0.4), tokens.accent.opacity(0.15)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "music.note.list")
                                .font(.system(size: 32, weight: .light))
                                .foregroundColor(tokens.accent)
                        }
                    }
                }
                .frame(width: 130, height: 130)
                .overlay(
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.4)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                )
                .softShadow()

                Text(playlist.name)
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(tokens.textPrimary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)

                Text("\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")")
                    .font(DS.Typography.caption)
                    .foregroundColor(tokens.textSecondary)
                    .frame(width: 130, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab Picker

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(PlaylistTab.allCases, id: \.self) { tab in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(DS.Typography.bodyEm)
                            .foregroundColor(selectedTab == tab ? tokens.textPrimary : tokens.textSecondary)
                        ZStack {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 3)
                            if selectedTab == tab {
                                Capsule()
                                    .fill(tokens.accent)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "playlistTabIndicator", in: tabIndicator)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        let tracks = selectedTab == .recentlyAdded
            ? recentlyPlayedManager.recentlyAdded
            : recentlyPlayedManager.recentlyPlayed

        if tracks.isEmpty {
            VStack(spacing: DS.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(tokens.surface)
                        .frame(width: 72, height: 72)
                    Image(systemName: selectedTab == .recentlyAdded ? "plus.circle" : "clock")
                        .font(.system(size: 28, weight: .light))
                        .foregroundColor(tokens.textSecondary)
                }
                Text("No tracks yet")
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.xl)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(tracks.prefix(100)) { track in
                    trackRow(track)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.vertical, DS.Spacing.sm)
                }
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            Haptics.light()
            playerManager.play(track)
            recentlyPlayedManager.trackPlayed(track)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: 44, cornerRadius: DS.Radius.sm, tokens: tokens)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .addToQueueGesture(playerManager: playerManager, track: track)
        .trackRowAccessibility(
            title: track.title, artist: track.artist,
            isCurrent: playerManager.currentTrack?.id == track.id,
            isPlaying: playerManager.isPlaying
        )
    }

    // MARK: - Your Playlists

    // MARK: - Smart playlists (Pro)

    /// Rule-based playlists that re-evaluate live. Creating/editing is a Pro
    /// feature; viewing and playing existing ones is never locked.
    private var smartPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(title: "Smart playlists", tokens: tokens)
                .padding(.horizontal, DS.Spacing.lg)

            VStack(spacing: 0) {
                ForEach(smartPlaylistsManager.playlists) { playlist in
                    Button {
                        Haptics.light()
                        selectedSmart = playlist
                    } label: {
                        HStack(spacing: DS.Spacing.md) {
                            Image(systemName: "wand.and.stars")
                                .foregroundColor(tokens.accent)
                                .frame(width: 32, height: 32)
                            Text(playlist.name)
                                .font(DS.Typography.bodyEm)
                                .foregroundColor(tokens.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(tokens.textSecondary)
                        }
                        .padding(.horizontal, DS.Spacing.md)
                        .padding(.vertical, DS.Spacing.sm)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            if proStore.isPro {
                                smartEditorDraft = playlist
                            } else {
                                showSmartPaywall = true
                            }
                        } label: {
                            Label("Edit Rules", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) {
                            smartDeleteTarget = playlist
                            showSmartDeleteAlert = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    Divider().background(tokens.hairline).padding(.leading, 56)
                }

                Button {
                    Haptics.light()
                    if proStore.isPro {
                        smartEditorDraft = SmartPlaylist(name: "")
                    } else {
                        showSmartPaywall = true
                    }
                } label: {
                    HStack(spacing: DS.Spacing.md) {
                        Image(systemName: proStore.isPro ? "plus.circle.fill" : "lock.fill")
                            .foregroundColor(tokens.accent)
                            .frame(width: 32, height: 32)
                        Text("New Smart Playlist")
                            .font(DS.Typography.bodyEm)
                            .foregroundColor(tokens.textPrimary)
                        if !proStore.isPro {
                            Text("PRO")
                                .font(DS.Typography.micro)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(tokens.accent))
                                .foregroundColor(.white)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(proStore.isPro
                                    ? "New smart playlist"
                                    : "New smart playlist, requires Aria Pro")
            }
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(tokens.surface)
            )
            .padding(.horizontal, DS.Spacing.lg)
        }
    }

    private var yourPlaylistsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(title: "Your playlists", tokens: tokens)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.sm)

            if playlistsManager.playlists.isEmpty {
                VStack(spacing: DS.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(tokens.surface)
                            .frame(width: 80, height: 80)
                        Image(systemName: "music.note.list")
                            .font(.system(size: 30, weight: .light))
                            .foregroundColor(tokens.textSecondary)
                    }
                    Text("Create your first playlist")
                        .font(DS.Typography.body)
                        .foregroundColor(tokens.textSecondary)
                    Button {
                        Haptics.light()
                        showNewPlaylistAlert = true
                    } label: {
                        Text("Create Playlist")
                            .font(DS.Typography.bodyEm)
                            .foregroundColor(.white)
                            .padding(.horizontal, DS.Spacing.lg)
                            .padding(.vertical, DS.Spacing.sm)
                            .background(Capsule().fill(tokens.accent))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.xl)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(playlistsManager.sortedPlaylists) { playlist in
                        playlistRow(playlist)
                        if playlist != playlistsManager.sortedPlaylists.last {
                            Divider()
                                .background(tokens.hairline)
                                .padding(.leading, 76)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(tokens.surface)
                )
                .padding(.horizontal, DS.Spacing.lg)
            }
        }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        Button {
            Haptics.light()
            selectedPlaylist = playlist
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Group {
                    if let url = playlist.previewThumbnailURL {
                        AsyncCachedImage(url: url, cornerRadius: DS.Radius.sm, targetSize: 52) {
                            ArtworkPlaceholder(tokens: tokens, cornerRadius: DS.Radius.sm)
                        }
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(tokens.accentSubtle)
                            .overlay(
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 18))
                                    .foregroundColor(tokens.accent)
                            )
                    }
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.textPrimary)
                    Text("\(playlist.tracks.count) track\(playlist.tracks.count == 1 ? "" : "s")")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tokens.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Haptics.medium()
                let tracks = playlist.tracks
                guard !tracks.isEmpty else { return }
                playerManager.playSlice(tracks, startIndex: 0)
                recentlyPlayedManager.trackPlayed(tracks[0])
                playlistsManager.markPlayed(playlist)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            Button {
                renameTarget = playlist
                renameText = playlist.name
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                deleteTarget = playlist
                showDeleteAlert = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
