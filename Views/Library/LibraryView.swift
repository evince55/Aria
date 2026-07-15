import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var libraryManager: LocalLibraryManager
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var nav: NavigationCoordinator
    @EnvironmentObject private var downloadManager: DownloadManager

    @State private var isImporting = false
    @State private var importError: String?
    @State private var addToPlaylistTrack: LocalTrack?
    @State private var selectedTab: LibraryTab = .offlineTracks
    @Namespace private var tabIndicator

    enum LibraryTab: String, CaseIterable {
        case offlineTracks = "Offline Tracks"
        case youtubeDownloads = "YouTube Downloads"
    }

    @AppStorage("librarySortOrder") private var sortOrderRaw: String = LibrarySortOrder.recentlyAdded.rawValue
    @AppStorage("libraryGroupBy") private var groupByRaw: String = LibraryGroupBy.none.rawValue

    @StateObject private var vm: LibraryViewModel

    private var tokens: DesignTokens { themeManager.tokens }

    init(library: LocalLibraryManager) {
        let savedSort = UserDefaults.standard.string(forKey: "librarySortOrder")
            ?? LibrarySortOrder.recentlyAdded.rawValue
        let savedGroup = UserDefaults.standard.string(forKey: "libraryGroupBy")
            ?? LibraryGroupBy.none.rawValue
        let initialSort = LibrarySortOrder(rawValue: savedSort) ?? .recentlyAdded
        let initialGroup = LibraryGroupBy(rawValue: savedGroup) ?? .none
        _vm = StateObject(
            wrappedValue: LibraryViewModel(
                library: library,
                initialSortOrder: initialSort,
                initialGroupBy: initialGroup
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    tabPicker
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.top, DS.Spacing.sm)

                    switch selectedTab {
                    case .offlineTracks: offlineTracksContent
                    case .youtubeDownloads: downloadsContent
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $vm.searchText, prompt: "Search library")
            .onChange(of: vm.sortOrder) { newValue in
                sortOrderRaw = newValue.rawValue
            }
            .onChange(of: vm.groupBy) { newValue in
                groupByRaw = newValue.rawValue
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        playActiveTab()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(activeTabIsEmpty)
                    .accessibilityLabel("Play all")
                }
                if selectedTab == .offlineTracks {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort by", selection: $vm.sortOrder) {
                                ForEach(LibrarySortOrder.allCases) { order in
                                    Text(order.displayName).tag(order)
                                }
                            }
                            Picker("Group by", selection: $vm.groupBy) {
                                ForEach(LibraryGroupBy.allCases) { group in
                                    Text(group.displayName).tag(group)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                        }
                        .accessibilityLabel("Sort and group options")
                    }
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
                    do {
                        _ = try libraryManager.repairMissing(trackID: track.id, newFileURL: url)
                    } catch {
                        importError = "Couldn't repair '\(track.fileName)': \(error.localizedDescription)"
                    }
                },
                onRemove: {
                    libraryManager.remove(track)
                },
                onDismiss: { nav.missingRepairTrack = nil }
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

    // MARK: - Tab picker (matches the Playlists Recently-Added/Played style)

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(LibraryTab.allCases, id: \.self) { tab in
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
                            Capsule().fill(Color.clear).frame(height: 3)
                            if selectedTab == tab {
                                Capsule()
                                    .fill(tokens.accent)
                                    .frame(height: 3)
                                    .matchedGeometryEffect(id: "libraryTabIndicator", in: tabIndicator)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Offline Tracks tab (imported local files)

    @ViewBuilder
    private var offlineTracksContent: some View {
        if vm.tracks.isEmpty {
            emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.filteredAndSortedTracks.isEmpty {
            noSearchResults.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(vm.sections) { section in
                        LibrarySectionView(
                            section: section,
                            showHeader: vm.groupBy != .none,
                            tokens: tokens,
                            isCurrentTrack: isCurrentTrack,
                            isPlaying: playerManager.isPlaying,
                            onPlay: { playOrRepair($0) },
                            onAddToPlaylist: { addToPlaylistTrack = $0 },
                            onDelete: { libraryManager.remove($0) }
                        )
                    }
                }
                .padding(.vertical)
            }
        }
    }

    // MARK: - YouTube Downloads tab

    /// Downloaded tracks, filtered by the shared search field (title/artist).
    private var filteredDownloads: [DownloadRecord] {
        let q = vm.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return downloadManager.records }
        return downloadManager.records.filter {
            $0.title.range(of: q, options: .caseInsensitive) != nil
                || $0.artist.range(of: q, options: .caseInsensitive) != nil
        }
    }

    @ViewBuilder
    private var downloadsContent: some View {
        if downloadManager.records.isEmpty {
            downloadsEmptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredDownloads.isEmpty {
            noSearchResults.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredDownloads) { rec in
                        downloadRow(rec)
                    }
                }
                .padding(.vertical)
            }
        }
    }

    @ViewBuilder
    private var downloadsEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(tokens.textSecondary)
            Text("No downloads yet")
                .font(.title3)
                .foregroundColor(tokens.textPrimary)
            Text("Tap the download button on a track to save it here for offline playback.")
                .font(.callout)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func downloadRow(_ rec: DownloadRecord) -> some View {
        Button {
            let tracks = filteredDownloads.map(\.asTrack)
            let idx = filteredDownloads.firstIndex { $0.videoID == rec.videoID } ?? 0
            playerManager.playSlice(tracks, startIndex: idx)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                TrackThumbnail(url: rec.thumbnailURL, size: 48, cornerRadius: DS.Radius.sm, tokens: tokens)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rec.title)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundColor(playerManager.currentTrack?.id == rec.videoID ? tokens.accent : tokens.textPrimary)
                    HStack(spacing: 6) {
                        Text(rec.artist).lineLimit(1)
                        Text("· \(Self.formatBytes(rec.sizeBytes))")
                    }
                    .font(.caption)
                    .foregroundColor(tokens.textSecondary)
                }
                Spacer()
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(tokens.textSecondary)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                downloadManager.remove(rec.videoID)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(tokens.textSecondary)
            Text("No matches")
                .font(.title3)
                .foregroundColor(tokens.textPrimary)
            Text("No tracks match \"\(vm.searchText)\".")
                .font(.callout)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Actions

    private func importURLs(_ urls: [URL]) async {
        // Collect every failure — overwriting one alert message per error
        // meant a multi-file import reported only the last problem.
        var failures: [String] = []
        for url in urls {
            do {
                _ = try await libraryManager.importFile(at: url)
            } catch let error as ImportError {
                failures.append(importErrorMessage(for: error, fileName: url.lastPathComponent))
            } catch {
                failures.append("Couldn't import \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !failures.isEmpty else { return }
        importError = failures.count == 1
            ? failures[0]
            : "\(failures.count) of \(urls.count) files failed to import:\n\n"
                + failures.joined(separator: "\n\n")
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

    private func playOrRepair(_ track: LocalTrack) {
        if track.isMissing {
            nav.missingRepairTrack = track
        } else {
            playTrack(track)
        }
    }

    private func playTrack(_ track: LocalTrack) {
        // Build the full library as Track objects, then start playback
        // at the tapped track. Subsequent Next/Previous cycles through
        // the library in the same order the user sees in the list.
        // Pre-filter missing tracks and re-locate the tapped track's
        // index in the filtered list — `playSlice` clamps its
        // `startIndex` to the playable array's bounds, so passing the
        // unfiltered index would silently skip to the wrong track when
        // missing entries precede the tapped one.
        let library = vm.tracks
        guard let result = Self.playableStartIndex(
            in: library,
            tappedTrack: track,
            fileURL: { libraryManager.fileURL(for: $0) }
        ) else { return }
        playerManager.playSlice(result.playable, startIndex: result.startIndex)
    }

    /// Pre-filters missing tracks from `library` and locates `tappedTrack`'s
    /// index in the resulting playable array. Returns `nil` if the tapped
    /// track is missing from the library.
    ///
    /// Exposed as a static, parameterised helper so unit tests can drive
    /// the same pre-filter + re-locate path that `playTrack` uses without
    /// having to instantiate a full `LibraryView` (which carries a dozen
    /// `@StateObject` / `@EnvironmentObject` dependencies).
    ///
    /// The pre-filter is load-bearing: `PlayerManager.playSlice` clamps its
    /// `startIndex` to the playable array's bounds, so passing the
    /// *unfiltered* index alongside the *unfiltered* library causes
    /// `playSlice`'s internal filter + clamp to land on the wrong track
    /// whenever a missing entry precedes the tapped one. See
    /// `test_playSlice_skippedMissingTracks_preservesStartIndex`.
    static func playableStartIndex(
        in library: [LocalTrack],
        tappedTrack: LocalTrack,
        fileURL: (LocalTrack) -> URL
    ) -> (playable: [Track], startIndex: Int)? {
        let playable = library
            .filter { !$0.isMissing }
            .map { $0.asPlayerTrack(fileURL: fileURL($0)) }
        guard let idx = playable.firstIndex(where: { $0.id == "local:\(tappedTrack.id.uuidString)" }) else {
            return nil
        }
        return (playable, idx)
    }

    private func playAll() {
        guard !vm.tracks.isEmpty else { return }
        let asTracks = vm.tracks.map {
            $0.asPlayerTrack(fileURL: libraryManager.fileURL(for: $0))
        }
        playerManager.playSlice(asTracks, startIndex: 0)
    }

    /// Play-all for whichever tab is showing.
    private func playActiveTab() {
        switch selectedTab {
        case .offlineTracks:
            playAll()
        case .youtubeDownloads:
            let tracks = filteredDownloads.map(\.asTrack)
            guard !tracks.isEmpty else { return }
            playerManager.playSlice(tracks, startIndex: 0)
        }
    }

    private var activeTabIsEmpty: Bool {
        selectedTab == .offlineTracks ? vm.tracks.isEmpty : downloadManager.records.isEmpty
    }

    private func isCurrentTrack(_ track: LocalTrack) -> Bool {
        playerManager.currentTrack?.id == "local:\(track.id.uuidString)"
    }
}
