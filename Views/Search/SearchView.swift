import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @Binding var selectedTab: AppTab

    @State private var query = ""
    @State private var results: Loadable<[Track]> = .idle
    @FocusState private var isSearchFocused: Bool

    private let searchService: YouTubeSearchService
    private var tokens: DesignTokens { themeManager.tokens }

    init(selectedTab: Binding<AppTab>) {
        self._selectedTab = selectedTab
        self.searchService = YouTubeSearchService(backendURL: PlayerManager.backendURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                content
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Songs, artists, videos")
            .focused($isSearchFocused)
            .task(id: query) {
                await runSearch(for: query)
            }
            .onAppear { isSearchFocused = false }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isSearchFocused && query.isEmpty {
            idleHint
        } else {
            switch results {
            case .idle:
                browseContent
            case .loading:
                if let cached = results.value, !cached.isEmpty {
                    resultsList(cached)
                } else {
                    browseContent
                }
            case .loaded(let tracks):
                resultsList(tracks)
            case .failed(let error):
                resultsList([])
                    .overlay(alignment: .top) {
                        errorPill(error.localizedDescription)
                            .padding(DS.Spacing.lg)
                    }
            }
        }
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
                        Haptics.light()
                        // Start an endless "similar songs" radio seeded from the
                        // tapped result instead of queuing the raw search list.
                        playerManager.playRadio(seed: track)
                        recentlyPlayedManager.trackPlayed(track)
                        selectedTab = .favorites
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            TrackThumbnail(url: track.thumbnailURL, size: 52, cornerRadius: DS.Radius.sm)

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
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .addToQueueGesture(playerManager: playerManager, track: track)
                    .listRowBackground(tokens.background)
                    .listRowSeparatorTint(tokens.hairline)
                    .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.md, bottom: 4, trailing: DS.Spacing.md))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func errorPill(_ message: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(DS.Typography.caption)
                .foregroundColor(tokens.textPrimary)
            Spacer()
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
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
        .frame(maxWidth: .infinity)
    }

    // MARK: - Track Cards

    private func trackCard(_ track: Track) -> some View {
        Button {
            Haptics.light()
            playerManager.playRadio(seed: track)
            recentlyPlayedManager.trackPlayed(track)
            selectedTab = .favorites
        } label: {
            HStack(spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: 56, cornerRadius: DS.Radius.sm)
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
            Haptics.light()
            playerManager.playRadio(seed: track)
            recentlyPlayedManager.trackPlayed(track)
            selectedTab = .favorites
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: nil, cornerRadius: DS.Radius.md)
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
        guard trimmed.count >= 3 else {
            results = .idle
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
            let tracks = try await searchService.search(query: trimmed)
            try Task.checkCancellation()
            results = .loaded(tracks)
            settingsManager.addSearchToHistory(trimmed)
        } catch is CancellationError {
            // Superseded by a newer query; do not flip the state.
        } catch {
            results = .failed(error)
        }
    }
}
