import SwiftUI

struct SearchView: View {
    @ObservedObject var playerManager: PlayerManager
    @ObservedObject var recentlyPlayedManager: RecentlyPlayedManager
    @ObservedObject var themeManager: ThemeManager
    @ObservedObject var settingsManager: SettingsManager
    @Binding var selectedTab: AppTab

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var hasSearched = false

    private let searchService: YouTubeSearchService
    private var tokens: DesignTokens { themeManager.tokens }

    init(playerManager: PlayerManager, recentlyPlayedManager: RecentlyPlayedManager, themeManager: ThemeManager, settingsManager: SettingsManager, selectedTab: Binding<AppTab>) {
        self.playerManager = playerManager
        self.recentlyPlayedManager = recentlyPlayedManager
        self.themeManager = themeManager
        self.settingsManager = settingsManager
        self._selectedTab = selectedTab
        self.searchService = YouTubeSearchService(backendURL: playerManager.backendURL)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                if hasSearched || !query.isEmpty {
                    searchResultsList
                } else {
                    browseContent
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Songs, artists, videos")
            .onChange(of: query) { newQuery in
                errorMessage = nil
                searchTask?.cancel()
                searchService.cancel()

                let trimmed = newQuery.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 3 else {
                    results = []
                    hasSearched = false
                    errorMessage = nil
                    return
                }

                hasSearched = true
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    await performSearch(query: trimmed)
                }
            }
            .overlay {
                if isSearching && results.isEmpty {
                    ProgressView()
                        .tint(tokens.accent)
                        .scaleEffect(1.1)
                }
            }
        }
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
                    settingsManager.searchHistory.removeAll { $0 == item }
                    settingsManager.save()
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

    private var searchResultsList: some View {
        List {
            if let errorMessage {
                errorPill(errorMessage)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.lg, bottom: DS.Spacing.sm, trailing: DS.Spacing.lg))
            }

            if isSearching && results.isEmpty {
                ForEach(0..<6, id: \.self) { _ in
                    skeletonRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.lg, bottom: 4, trailing: DS.Spacing.lg))
                }
            } else if results.isEmpty && !isSearching {
                emptyResultsView
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(results) { track in
                    let isCurrent = playerManager.currentTrack?.id == track.id
                    Button {
                        Haptics.light()
                        playerManager.play(track)
                        recentlyPlayedManager.trackPlayed(track)
                        selectedTab = .favorites
                    } label: {
                        TrackRow(track: track, themeManager: themeManager, playerManager: playerManager)
                            .padding(.horizontal, 4)
                    }
                    .addToQueueGesture(playerManager: playerManager, track: track)
                    .listRowBackground(tokens.background)
                    .listRowSeparatorTint(tokens.hairline)
                    .listRowInsets(EdgeInsets(top: 4, leading: DS.Spacing.lg, bottom: 4, trailing: DS.Spacing.lg))
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
                .frame(width: 48, height: 48)
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
            playerManager.play(track)
            recentlyPlayedManager.trackPlayed(track)
            selectedTab = .favorites
        } label: {
            HStack(spacing: DS.Spacing.md) {
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
            playerManager.play(track)
            recentlyPlayedManager.trackPlayed(track)
            selectedTab = .favorites
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                TrackThumbnail(url: track.thumbnailURL, size: nil, cornerRadius: DS.Radius.md)
                    .aspectRatio(1, contentMode: .fit)
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

    private func performSearch(query: String) async {
        guard !query.isEmpty else {
            results = []
            errorMessage = nil
            return
        }

        isSearching = true
        errorMessage = nil
        defer { isSearching = false }

        do {
            results = try await searchService.search(query: query)
            settingsManager.addSearchToHistory(query)
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
            results = []
        }
    }
}
