import SwiftUI

/// Create/edit sheet for a smart playlist: name, sources, filters, sort, and
/// limit, with a live "matches N tracks" count evaluated against the current
/// library as rules change.
struct SmartPlaylistEditorView: View {
    let draft: SmartPlaylist

    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var smartPlaylistsManager: SmartPlaylistsManager
    @EnvironmentObject private var localLibraryManager: LocalLibraryManager
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @Environment(\.dismiss) private var dismiss

    @State private var working: SmartPlaylist

    private var tokens: DesignTokens { themeManager.tokens }

    init(draft: SmartPlaylist) {
        self.draft = draft
        _working = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                tokens.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: DS.Spacing.lg) {
                        nameCard
                        sourcesCard
                        filtersCard
                        orderCard
                        matchCount
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.top, DS.Spacing.lg)
                    .padding(.bottom, DS.Spacing.xxl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(smartPlaylistsManager.playlists.contains { $0.id == working.id }
                             ? "Edit Smart Playlist" : "New Smart Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Haptics.success()
                        smartPlaylistsManager.upsert(working)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !working.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !working.rules.sources.isEmpty
    }

    // MARK: - Cards

    private var nameCard: some View {
        card {
            TextField("Name (e.g. “Fresh FLACs”)", text: $working.name)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textPrimary)
                .padding(DS.Spacing.md)
        }
    }

    private var sourcesCard: some View {
        card(title: "Include") {
            VStack(spacing: 0) {
                ForEach(Array(SmartSource.allCases.enumerated()), id: \.element) { index, source in
                    Toggle(isOn: sourceBinding(source)) {
                        Text(source.label)
                            .font(DS.Typography.body)
                            .foregroundColor(tokens.textPrimary)
                    }
                    .tint(tokens.accent)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.sm)
                    if index < SmartSource.allCases.count - 1 {
                        Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)
                    }
                }
            }
        }
    }

    private var filtersCard: some View {
        card(title: "Only keep tracks where…") {
            VStack(spacing: 0) {
                filterField("Title contains", text: $working.rules.titleContains)
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)
                filterField("Artist contains", text: $working.rules.artistContains)
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)
                filterField("Album contains", text: $working.rules.albumContains)
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)

                Toggle(isOn: $working.rules.losslessOnly) {
                    labelled("Lossless only", detail: "FLAC · ALAC · WAV · AIFF")
                }
                .tint(tokens.accent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)

                Toggle(isOn: $working.rules.favoritesOnly) {
                    labelled("Favorites only", detail: nil)
                }
                .tint(tokens.accent)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.sm)
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)

                menuRow("Played", selection: working.rules.recency.label) {
                    ForEach(SmartRecency.allCases, id: \.self) { r in
                        Button(r.label) { working.rules.recency = r }
                    }
                }
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)

                menuRow("Added", selection: addedLabel) {
                    Button("Any time") { working.rules.addedWithinDays = nil }
                    Button("Last 7 days") { working.rules.addedWithinDays = 7 }
                    Button("Last 30 days") { working.rules.addedWithinDays = 30 }
                    Button("Last 90 days") { working.rules.addedWithinDays = 90 }
                }
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)

                menuRow("Length", selection: lengthLabel) {
                    Button("Any") { working.rules.minMinutes = nil; working.rules.maxMinutes = nil }
                    Button("Under 5 min") { working.rules.minMinutes = nil; working.rules.maxMinutes = 5 }
                    Button("Over 5 min") { working.rules.minMinutes = 5; working.rules.maxMinutes = nil }
                    Button("Over 10 min") { working.rules.minMinutes = 10; working.rules.maxMinutes = nil }
                    Button("Over 20 min") { working.rules.minMinutes = 20; working.rules.maxMinutes = nil }
                }
            }
        }
    }

    private var orderCard: some View {
        card(title: "Order") {
            VStack(spacing: 0) {
                menuRow("Sort", selection: working.sort.label) {
                    ForEach(SmartSort.allCases, id: \.self) { s in
                        Button(s.label) { working.sort = s }
                    }
                }
                Divider().background(tokens.hairline).padding(.leading, DS.Spacing.md)
                menuRow("Limit", selection: working.limit.map { "\($0) tracks" } ?? "No limit") {
                    Button("No limit") { working.limit = nil }
                    Button("10 tracks") { working.limit = 10 }
                    Button("25 tracks") { working.limit = 25 }
                    Button("50 tracks") { working.limit = 50 }
                    Button("100 tracks") { working.limit = 100 }
                }
            }
        }
    }

    private var matchCount: some View {
        let count = SmartPlaylistEngine.evaluate(
            working,
            candidates: SmartPlaylistEngine.candidates(
                localTracks: localLibraryManager.tracks,
                fileURL: { localLibraryManager.fileURL(for: $0) },
                downloads: downloadManager.records,
                favorites: favoritesManager.tracks
            ),
            favoriteIDs: Set(favoritesManager.tracks.map(\.id)),
            recentlyPlayedIDs: Set(recentlyPlayedManager.recentlyPlayed.map(\.id))
        ).count
        return Text("Matches \(count) track\(count == 1 ? "" : "s") right now")
            .font(DS.Typography.caption)
            .foregroundColor(tokens.textSecondary)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Bits

    private func sourceBinding(_ source: SmartSource) -> Binding<Bool> {
        Binding(
            get: { working.rules.sources.contains(source) },
            set: { on in
                if on { working.rules.sources.insert(source) }
                else { working.rules.sources.remove(source) }
            }
        )
    }

    private var addedLabel: String {
        working.rules.addedWithinDays.map { "Last \($0) days" } ?? "Any time"
    }

    private var lengthLabel: String {
        switch (working.rules.minMinutes, working.rules.maxMinutes) {
        case (nil, nil): return "Any"
        case (nil, .some(let max)): return "Under \(Int(max)) min"
        case (.some(let min), nil): return "Over \(Int(min)) min"
        case (.some(let min), .some(let max)): return "\(Int(min))–\(Int(max)) min"
        }
    }

    private func filterField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(DS.Typography.body)
            .foregroundColor(tokens.textPrimary)
            .autocorrectionDisabled(true)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
    }

    private func labelled(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textPrimary)
            if let detail {
                Text(detail)
                    .font(DS.Typography.micro)
                    .foregroundColor(tokens.textSecondary)
            }
        }
    }

    private func menuRow<Content: View>(_ title: String, selection: String,
                                        @ViewBuilder options: () -> Content) -> some View {
        HStack {
            Text(title)
                .font(DS.Typography.body)
                .foregroundColor(tokens.textPrimary)
            Spacer()
            Menu {
                options()
            } label: {
                HStack(spacing: 4) {
                    Text(selection)
                        .font(DS.Typography.body)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(tokens.accent)
            }
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
    }

    private func card<Content: View>(title: String? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if let title {
                Text(title)
                    .font(DS.Typography.sectionHeader)
                    .foregroundColor(tokens.textSecondary)
                    .padding(.leading, DS.Spacing.xs)
            }
            VStack(spacing: 0, content: content)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(tokens.surface)
                )
        }
    }
}
