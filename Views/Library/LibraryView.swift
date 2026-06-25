import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var nav: NavigationCoordinator

    @State private var isImporting = false
    @State private var importError: String?
    @State private var importingTrackIDs: Set<UUID> = []
    @State private var addToPlaylistTrack: LocalTrack?

    private var tokens: DesignTokens { themeManager.tokens }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                if libraryManager.tracks.isEmpty {
                    emptyState
                } else {
                    trackList
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        playAll()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(libraryManager.tracks.isEmpty)
                    .accessibilityLabel("Play all tracks")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImporting = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import audio file")
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importURLs(urls) }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(
            "Import failed",
            isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(item: $addToPlaylistTrack) { track in
            addToPlaylistSheet(for: track)
        }
        .sheet(item: $nav.missingRepairTrack) { track in
            MissingTrackRepairSheet(
                track: track,
                onReimport: { url in
                    _ = try? libraryManager.repairMissing(trackID: track.id, newFileURL: url)
                },
                onRemove: {
                    libraryManager.remove(track)
                }
            )
        }
        .onAppear {
            libraryManager.auditMissingFlags()
        }
    }

    @ViewBuilder
    private func addToPlaylistSheet(for track: LocalTrack) -> some View {
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
                            .foregroundColor(tokens.textPrimary)
                        Text("Create a playlist from the Playlists tab first")
                            .font(.subheadline)
                            .foregroundColor(tokens.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                } else {
                    List {
                        ForEach(playlistsManager.playlists) { playlist in
                            Button {
                                let asTrack = track.asPlayerTrack(fileURL: libraryManager.fileURL(for: track))
                                playlistsManager.addTrack(asTrack, to: playlist)
                                addToPlaylistTrack = nil
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(playlist.name)
                                            .font(.body)
                                            .foregroundColor(tokens.textPrimary)
                                        Text("\(playlist.tracks.count) tracks")
                                            .font(.caption)
                                            .foregroundColor(tokens.textSecondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundColor(tokens.accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { addToPlaylistTrack = nil }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(tokens.textSecondary)
            Text("No files yet")
                .font(.title3)
                .foregroundColor(tokens.textPrimary)
            Text("Import FLAC, MP3, or other audio files from the Files app to play them with EQ.")
                .font(.callout)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                isImporting = true
            } label: {
                Label("Import", systemImage: "plus")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(tokens.accent)
            .padding(.top, 8)
        }
    }

    private var trackList: some View {
        List {
            ForEach(libraryManager.tracks) { track in
                trackRow(track)
                    .listRowBackground(tokens.cardSurface)
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            addToPlaylistTrack = track
                        } label: {
                            Label("Playlist", systemImage: "text.badge.plus")
                        }
                        .tint(tokens.accent)
                    }
                    .contextMenu {
                        Button {
                            if track.isMissing {
                                nav.missingRepairTrack = track
                            } else {
                                playTrack(track)
                            }
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        Button {
                            addToPlaylistTrack = track
                        } label: {
                            Label("Add to Playlist", systemImage: "text.badge.plus")
                        }
                        Divider()
                        Button(role: .destructive) {
                            libraryManager.remove(track)
                        } label: {
                            Label("Delete from Library", systemImage: "trash")
                        }
                    }
            }
            .onDelete(perform: deleteTracks)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tokens.background)
    }

    private func trackRow(_ track: LocalTrack) -> some View {
        Button {
            if track.isMissing {
                nav.missingRepairTrack = track
            } else {
                playTrack(track)
            }
        } label: {
            HStack(spacing: 12) {
                artworkView(for: track)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.body)
                            .foregroundColor(tokens.textPrimary)
                            .lineLimit(1)
                        if track.isMissing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .imageScale(.small)
                                .accessibilityLabel("File missing")
                        }
                    }
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

                if isCurrentTrack(track) {
                    Image(systemName: playerManager.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(tokens.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(track.isMissing ? 0.55 : 1.0)
    }

    @ViewBuilder
    private func artworkView(for track: LocalTrack) -> some View {
        if let url = track.artworkURL {
            // AsyncCachedImage handles in-memory caching so list
            // scrolling doesn't re-decode the JPEG every redraw.
            AsyncCachedImage(url: url) {
                placeholderArtwork
            }
        } else {
            placeholderArtwork
        }
    }

    private var placeholderArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tokens.dividerColor)
            Image(systemName: "music.note")
                .font(.title3)
                .foregroundColor(tokens.textSecondary)
        }
    }

    // MARK: - Actions

    private func importURLs(_ urls: [URL]) async {
        for url in urls {
            do {
                let track = try await libraryManager.importFile(at: url)
                importingTrackIDs.insert(track.id)
            } catch let error as ImportError {
                importError = importErrorMessage(for: error, fileName: url.lastPathComponent)
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func importErrorMessage(for error: ImportError, fileName: String) -> String {
        switch error {
        case .unsupportedFormat(let format):
            return "\(fileName) is in \(format.displayName) format, which isn't supported. Convert to MP3 or FLAC and try again."
        case .fileNotDownloaded:
            return "\(fileName) hasn't finished downloading from iCloud. Open it in the Files app, wait for the download to finish, then try again."
        case .zeroByteFile:
            return "\(fileName) is empty (0 bytes). Pick a different file."
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        let toRemove = offsets.map { libraryManager.tracks[$0] }
        for track in toRemove {
            libraryManager.remove(track)
        }
    }

    private func playTrack(_ track: LocalTrack) {
        // Build the full library as Track objects, then start playback
        // at the tapped track. Subsequent Next/Previous cycles through
        // the library in the same order the user sees in the list.
        let library = libraryManager.tracks
        let asTracks = library.map { $0.asPlayerTrack(fileURL: libraryManager.fileURL(for: $0)) }
        let idx = library.firstIndex(where: { $0.id == track.id }) ?? 0
        playerManager.playSlice(asTracks, startIndex: idx)
    }

    private func playAll() {
        guard !libraryManager.tracks.isEmpty else { return }
        let asTracks = libraryManager.tracks.map {
            $0.asPlayerTrack(fileURL: libraryManager.fileURL(for: $0))
        }
        playerManager.playSlice(asTracks, startIndex: 0)
    }

    private func isCurrentTrack(_ track: LocalTrack) -> Bool {
        playerManager.currentTrack?.id == "local:\(track.id.uuidString)"
    }

    // MARK: - Formatting

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
