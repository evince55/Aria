import SwiftUI

/// Which index a search query runs against: everything the configured server
/// can find (`/api/search`) or the user's own synced library
/// (`/api/library/query`). The Library scope only appears when
/// `LibrarySearchManager.scopeAvailable` says the backend supports it (see the
/// gating rules on that manager).
///
/// The raw values are user-facing segment labels, so they name neither the
/// backend nor its upstream source — the same picker serves Aria's backend and
/// a Subsonic server.
enum SearchScope: String, CaseIterable {
    case catalog = "Catalog"
    case library = "Library"
}

struct SearchView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var librarySearchManager: LibrarySearchManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager

    @State private var query = ""
    @State private var results: Loadable<[Track]> = .idle
    @State private var scope: SearchScope = .catalog
    /// The query whose library results are on screen — the default name for
    /// "Save as playlist".
    @State private var activeLibraryQuery = ""
    @State private var savedPlaylistName: String?
    @FocusState private var isSearchFocused: Bool

    /// Identity for the debounced search task: retrigger on either edit.
    private struct SearchTaskID: Equatable {
        let query: String
        let scope: SearchScope
    }

    // Pagination state for infinite scroll.
    @State private var activeQuery = ""
    @State private var nextOffset = 0
    @State private var canLoadMore = false
    @State private var isLoadingMore = false
    private let pageSize = 25

    private let searchService: YouTubeSearchService
    private var tokens: DesignTokens { themeManager.tokens }

    init() {
        self.searchService = YouTubeSearchService(backendURL: PlayerManager.backendURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    if librarySearchManager.scopeAvailable {
                        scopePicker
                    }
                    content
                        .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: scope == .library
                            ? "Ask your library"
                            : "Songs, artists, videos")
            .focused($isSearchFocused)
            .task(id: SearchTaskID(query: query, scope: scope)) {
                await runSearch(for: query)
            }
            .onAppear { isSearchFocused = false }
            .onChange(of: librarySearchManager.scopeAvailable) { available in
                // The scope can disappear mid-session (URL cleared, backend
                // downgraded); never strand the picker on a hidden scope.
                if !available, scope == .library { scope = .catalog }
            }
            .toolbar {
                if scope == .library,
                   let tracks = librarySearchManager.results.value,
                   !tracks.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            Haptics.success()
                            let name = activeLibraryQuery.isEmpty ? "Library Search" : activeLibraryQuery
                            playlistsManager.create(name: name, tracks: tracks)
                            savedPlaylistName = name
                        } label: {
                            Label("Save as playlist", systemImage: "text.badge.plus")
                        }
                    }
                }
            }
            .alert(
                "Saved as playlist",
                isPresented: Binding(
                    get: { savedPlaylistName != nil },
                    set: { if !$0 { savedPlaylistName = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\u{201C}\(savedPlaylistName ?? "")\u{201D} was added to your playlists.")
            }
        }
    }

    private var scopePicker: some View {
        Picker("Search scope", selection: $scope) {
            ForEach(SearchScope.allCases, id: \.self) { s in
                Text(s.rawValue).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        if scope == .library {
            libraryContent
        } else if !isSearchFocused && query.isEmpty {
            idleHint
        } else {
            switch results {
            case .idle:
                browseContent
            case .loading:
                if let cached = results.value, !cached.isEmpty {
                    resultsList(cached)
                } else {
                    searchLoadingView
                }
            case .loaded(let tracks):
                resultsList(tracks)
            case .failed(let error):
                searchErrorView(error)
            }
        }
    }

    // MARK: - Library scope

    @ViewBuilder
    private var libraryContent: some View {
        switch librarySearchManager.results {
        case .idle:
            libraryIdleHint
        case .loading:
            if let cached = librarySearchManager.results.value, !cached.isEmpty {
                libraryResultsList(cached)
            } else {
                searchLoadingView
            }
        case .loaded(let tracks):
            if tracks.isEmpty {
                libraryEmptyResultsView
            } else {
                libraryResultsList(tracks)
            }
        case .failed(let error):
            searchErrorView(error)
        }
    }

    // NOTE: gate/empty-state copy below needs owner review before ship
    // (per spec §5 — gate copy has shipped broken with green tests before).
    private var libraryIdleHint: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 96, height: 96)
                Image(systemName: "books.vertical")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            Text("Ask your library")
                .font(DS.Typography.titleMedium)
                .foregroundColor(tokens.textPrimary)
            Text("Search your favorites, playlists, and imports in your own words — try \u{201C}mellow late-night guitar\u{201D}")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.lg)
    }

    private var libraryEmptyResultsView: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 96, height: 96)
                Image(systemName: "books.vertical")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            Text("No matches in your library")
                .font(DS.Typography.titleMedium)
                .foregroundColor(tokens.textPrimary)
            Text("Your library syncs shortly after you favorite, import, or play tracks. Try different words, or check back in a minute.")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.lg)
    }

    private func libraryResultsList(_ tracks: [Track]) -> some View {
        List {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                let isCurrent = playerManager.currentTrack?.id == track.id
                Button {
                    dismissKeyboard()
                    Haptics.light()
                    // Library results play as a queue slice (these are the
                    // user's own tracks), unlike YouTube results which seed
                    // a radio.
                    playerManager.playSlice(tracks, startIndex: index)
                    recentlyPlayedManager.trackPlayed(track)
                } label: {
                    HStack(spacing: DS.Spacing.sm) {
                        TrackThumbnail(url: track.thumbnailURL, size: 52, cornerRadius: DS.Radius.sm, tokens: tokens)

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

                        if let secs = track.duration {
                            Text(formatDuration(secs))
                                .font(DS.Typography.caption)
                                .monospacedDigit()
                                .foregroundColor(tokens.textSecondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .addToQueueGesture(playerManager: playerManager, track: track)
                .trackRowAccessibility(
                    title: track.title, artist: track.artist,
                    isCurrent: isCurrent,
                    isPlaying: playerManager.isPlaying
                )
                .listRowBackground(tokens.background)
                .listRowSeparatorTint(tokens.hairline)
                .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.md, bottom: 4, trailing: DS.Spacing.md))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Drops the search keyboard so it doesn't cover the mini player after a
    /// song is tapped without first pressing Search. The `.searchable` field
    /// doesn't reliably honor the focus binding on iOS 16, so resign first
    /// responder as well.
    private func dismissKeyboard() {
        isSearchFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var idleHint: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 96, height: 96)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            Text("Search Aria")
                .font(DS.Typography.titleMedium)
                .foregroundColor(tokens.textPrimary)
            Text("Tap the search bar to find songs, artists, and videos")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.lg)
    }

    /// Shown while a fresh search is in flight (no prior results to keep on
    /// screen). Without this the `.loading` state fell through to an empty
    /// browse view — a blank screen with no feedback.
    private var searchLoadingView: some View {
        VStack(spacing: DS.Spacing.md) {
            ProgressView()
                .controlSize(.large)
                .tint(tokens.accent)
            Text("Searching…")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Browse

    private var browseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                searchHistorySection
                recentlyPlayedSection
                trendingSection
            }
            .padding(.bottom, DS.Spacing.xxl)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchHistorySection: some View {
        Group {
            if !settingsManager.searchHistory.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    HStack {
                        SectionLabel(title: "Recent searches", tokens: tokens)
                        Spacer()
                        Button {
                            Haptics.light()
                            settingsManager.clearSearchHistory()
                        } label: {
                            Text("Clear")
                                .font(DS.Typography.captionStrong)
                                .foregroundColor(tokens.accent)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)

                    VStack(spacing: 0) {
                        ForEach(settingsManager.searchHistory, id: \.self) { item in
                            searchHistoryRow(item)
                            if item != settingsManager.searchHistory.last {
                                Divider().background(tokens.hairline).padding(.leading, 56)
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
    }

    private func searchHistoryRow(_ item: String) -> some View {
        Button {
            Haptics.selection()
            query = item
        } label: {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(tokens.textSecondary)
                    .frame(width: 22)
                Text(item)
                    .font(DS.Typography.body)
                    .foregroundColor(tokens.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button {
                    Haptics.light()
                    settingsManager.removeSearchHistoryItem(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(tokens.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var recentlyPlayedSection: some View {
        Group {
            if !recentlyPlayedManager.recentlyPlayed.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    SectionLabel(title: "Based on your listening", tokens: tokens)
                        .padding(.horizontal, DS.Spacing.lg)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.md), count: 2), spacing: DS.Spacing.md) {
                        ForEach(recentlyPlayedManager.recentlyPlayed.prefix(8)) { track in
                            trackCard(track)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                }
            }
        }
    }

    private var trendingSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            SectionLabel(title: "Trending", tokens: tokens)
                .padding(.horizontal, DS.Spacing.lg)

            if recentlyPlayedManager.recentlyPlayed.isEmpty {
                VStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 28))
                        .foregroundColor(tokens.textSecondary)
                    Text("Start searching and listening to see trends")
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.lg)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: DS.Spacing.md), count: 3), spacing: DS.Spacing.md) {
                    ForEach(recentlyPlayedManager.recentlyPlayed.prefix(20)) { track in
                        tileCard(track)
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
            }
        }
    }

    // MARK: - Search Results

    private func resultsList(_ tracks: [Track]) -> some View {
        List {
            if results.isLoading && tracks.isEmpty {
                ForEach(0..<6, id: \.self) { _ in
                    skeletonRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.md, bottom: 4, trailing: DS.Spacing.md))
                }
            } else if tracks.isEmpty {
                emptyResultsView
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(tracks) { track in
                    let isCurrent = playerManager.currentTrack?.id == track.id
                    Button {
                        dismissKeyboard()
                        Haptics.light()
                        // Start an endless "similar songs" radio seeded from the
                        // tapped result instead of queuing the raw search list.
                        // Stay on Search: the results (and the mini player) keep
                        // the user in the flow of trying the next result.
                        playerManager.playRadio(seed: track)
                        recentlyPlayedManager.trackPlayed(track)
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            TrackThumbnail(url: track.thumbnailURL, size: 52, cornerRadius: DS.Radius.sm, tokens: tokens)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(DS.Typography.bodyEm)
                                    .lineLimit(1)
                                    .foregroundColor(isCurrent ? tokens.accent : tokens.textPrimary)
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

                            if let secs = track.duration {
                                Text(formatDuration(secs))
                                    .font(DS.Typography.caption)
                                    .monospacedDigit()
                                    .foregroundColor(tokens.textSecondary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .addToQueueGesture(playerManager: playerManager, track: track)
                    .trackRowAccessibility(
                        title: track.title, artist: track.artist,
                        isCurrent: isCurrent,
                        isPlaying: playerManager.isPlaying
                    )
                    .listRowBackground(tokens.background)
                    .listRowSeparatorTint(tokens.hairline)
                    .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.md, bottom: 4, trailing: DS.Spacing.md))
                    .onAppear {
                        // Infinite scroll: trigger the next page when the last
                        // row appears. This re-fires reliably on every page as
                        // each new last row scrolls in (a footer .onAppear, by
                        // contrast, fires only once for a persistent element).
                        if track.id == tracks.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }

                // Persistent spinner shown while more pages may exist. Keyed on
                // canLoadMore (true across pages until the end), NOT the transient
                // isLoadingMore. Uses a self-animating spinner rather than
                // ProgressView: SwiftUI reuses the persistent footer and its
                // wrapped UIActivityIndicatorView stops animating after page 1,
                // and a *stopped* indicator is hidden (hidesWhenStopped) — which
                // showed as an empty gap with no visible spinner on later pages.
                if canLoadMore {
                    HStack {
                        Spacer()
                        InlineSpinner(color: tokens.textSecondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Spacing.md)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Failed-search state: a distinct connectivity icon, the error message,
    /// and a Retry button that re-runs the current query. Replaces the old
    /// overlay-a-pill-over-"No matches" treatment, which showed two
    /// contradictory messages at once.
    private func searchErrorView(_ error: Error) -> some View {
        VStack(spacing: DS.Spacing.md) {
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 96, height: 96)
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            Text("Something went wrong")
                .font(DS.Typography.titleMedium)
                .foregroundColor(tokens.textPrimary)
            Text(error.localizedDescription)
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.light()
                Task { await runSearch(for: query) }
            } label: {
                Text("Retry")
                    .font(DS.Typography.bodyEm)
                    .foregroundColor(.white)
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.sm)
                    .background(Capsule().fill(tokens.accent))
            }
            .buttonStyle(.plain)
            .padding(.top, DS.Spacing.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.Spacing.lg)
    }

    private var skeletonRow: some View {
        HStack(spacing: DS.Spacing.md) {
            ShimmerView(cornerRadius: DS.Radius.sm)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 6) {
                ShimmerView(cornerRadius: 4)
                    .frame(height: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ShimmerView(cornerRadius: 4)
                    .frame(width: 120, height: 10)
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyResultsView: some View {
        VStack(spacing: DS.Spacing.md) {
            Spacer(minLength: 40)
            ZStack {
                Circle()
                    .fill(tokens.surface)
                    .frame(width: 96, height: 96)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(tokens.textSecondary)
            }
            Text("No matches")
                .font(DS.Typography.titleMedium)
                .foregroundColor(tokens.textPrimary)
            Text("Try a different search term")
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textSecondary)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    // MARK: - Track Cards

    private func trackCard(_ track: Track) -> some View {
        Button {
            dismissKeyboard()
            Haptics.light()
            playerManager.playRadio(seed: track)
            recentlyPlayedManager.trackPlayed(track)
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: 56, cornerRadius: DS.Radius.sm, tokens: tokens)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(DS.Typography.bodyEm)
                        .foregroundColor(tokens.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(track.artist)
                        .font(DS.Typography.caption)
                        .foregroundColor(tokens.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(tokens.surface)
            )
        }
        .buttonStyle(.plain)
        .addToQueueGesture(playerManager: playerManager, track: track)
    }

    private func tileCard(_ track: Track) -> some View {
        Button {
            dismissKeyboard()
            Haptics.light()
            playerManager.playRadio(seed: track)
            recentlyPlayedManager.trackPlayed(track)
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: nil, cornerRadius: DS.Radius.md, tokens: tokens)
                Text(track.title)
                    .font(DS.Typography.captionStrong)
                    .foregroundColor(tokens.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(track.artist)
                    .font(DS.Typography.micro)
                    .foregroundColor(tokens.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .addToQueueGesture(playerManager: playerManager, track: track)
    }

    // MARK: - Search

    private func runSearch(for raw: String) async {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        if scope == .library {
            guard trimmed.count >= 3 else {
                librarySearchManager.clearResults()
                return
            }
            // Same debounce discipline as the YouTube path; the manager owns
            // the Loadable transitions and in-flight cancellation.
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
            } catch {
                return
            }
            activeLibraryQuery = trimmed
            librarySearchManager.search(query: trimmed)
            return
        }

        guard trimmed.count >= 3 else {
            results = .idle
            canLoadMore = false
            nextOffset = 0
            return
        }

        // Debounce: wait 600ms before hitting the network, then re-check
        // whether the user kept typing. `.task(id: query)` cancels the
        // prior task automatically when the query changes, so the inner
        // sleep + re-check is just an optimization for back-to-back edits.
        do {
            try await Task.sleep(nanoseconds: 600_000_000)
        } catch {
            return
        }
        try? Task.checkCancellation()

        results = .loading

        do {
            let tracks = try await searchService.search(query: trimmed, limit: pageSize, offset: 0)
            try Task.checkCancellation()
            results = .loaded(tracks)
            activeQuery = trimmed
            nextOffset = tracks.count
            // yt-dlp often returns slightly fewer than `pageSize`, so don't gate
            // on an exact count — try another page whenever the first one was
            // non-empty. loadMore() stops as soon as a page brings nothing new.
            canLoadMore = !tracks.isEmpty
            settingsManager.addSearchToHistory(trimmed)
        } catch is CancellationError {
            // Superseded by a newer query; do not flip the state.
        } catch {
            results = .failed(error)
        }
    }

    /// Appends the next page when the user scrolls to the bottom. No-ops if the
    /// last page was short (end reached), one is already in flight, or the query
    /// changed mid-flight.
    private func loadMore() async {
        guard canLoadMore, !isLoadingMore, results.value != nil else { return }
        let q = activeQuery
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let more = try await searchService.search(query: q, limit: pageSize, offset: nextOffset)
            guard q == activeQuery, let current = results.value else { return }
            let existing = Set(current.map(\.id))
            let fresh = more.filter { !existing.contains($0.id) }
            if !fresh.isEmpty { results = .loaded(current + fresh) }
            nextOffset += more.count
            // Stop when the backend returns nothing OR nothing new (the latter
            // also cleanly ends pagination against a backend that ignores
            // `offset` and keeps re-returning the same page).
            canLoadMore = !fresh.isEmpty
        } catch {
            // Stop paginating on error but keep the results already shown.
            canLoadMore = false
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A self-animating loading spinner that keeps spinning for as long as it is on
/// screen. Unlike SwiftUI's `ProgressView` (which wraps a `UIActivityIndicatorView`
/// that stops — and thus hides — when reused inside a persistent `List` footer),
/// this drives its own repeating `rotationEffect`, so it stays visible on every
/// page of infinite scroll, not just the first.
private struct InlineSpinner: View {
    var color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 20, height: 20)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                spinning = false
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
            .accessibilityLabel("Loading more results")
    }
}
