import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var isImporting = false
    @State private var importError: String?
    @State private var importingTrackIDs: Set<UUID> = []

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
            }
            .onDelete(perform: deleteTracks)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(tokens.background)
    }

    private func trackRow(_ track: LocalTrack) -> some View {
        Button {
            playTrack(track)
        } label: {
            HStack(spacing: 12) {
                artworkView(for: track)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .foregroundColor(tokens.textPrimary)
                        .lineLimit(1)
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
            } catch {
                importError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        let toRemove = offsets.map { libraryManager.tracks[$0] }
        for track in toRemove {
            libraryManager.remove(track)
        }
    }

    private func playTrack(_ track: LocalTrack) {
        let url = libraryManager.fileURL(for: track)
        playerManager.play(localTrack: track, fileURL: url)
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
