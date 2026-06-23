import SwiftUI

struct ContentView: View {
    @StateObject private var playerManager = PlayerManager()
    @StateObject private var favoritesManager = FavoritesManager()
    @StateObject private var playlistsManager = PlaylistsManager()
    @StateObject private var recentlyPlayedManager = RecentlyPlayedManager()
    @StateObject private var settingsManager: SettingsManager
    @StateObject private var themeManager: ThemeManager

    @State private var selectedTab: AppTab = .favorites
    @State private var showFullPlayer = false
    @Namespace private var playerNamespace
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = SettingsManager()
        _settingsManager = StateObject(wrappedValue: settings)
        _themeManager = StateObject(wrappedValue: ThemeManager(settings: settings))

        let tabRaw = settings.defaultStartTab.rawValue
        switch tabRaw {
        case "Playlists": _selectedTab = State(initialValue: .playlists)
        case "Search":    _selectedTab = State(initialValue: .search)
        case "More":      _selectedTab = State(initialValue: .more)
        default:          _selectedTab = State(initialValue: .favorites)
        }
    }

    var body: some View {
        ZStack {
            themeManager.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                tabContent
                    .frame(maxHeight: .infinity)

                if playerManager.currentTrack != nil {
                    MiniPlayerView(
                        playerManager: playerManager,
                        namespace: playerNamespace,
                        onTap: { expandPlayer() }
                    )
                }

                customTabBar
            }
            .padding(.bottom, DS.Spacing.sm)

            if showFullPlayer {
                FullScreenPlayerView(
                    playerManager: playerManager,
                    favoritesManager: favoritesManager,
                    playlistsManager: playlistsManager,
                    recentlyPlayedManager: recentlyPlayedManager,
                    themeManager: themeManager,
                    namespace: playerNamespace,
                    onDismiss: { dismissPlayer() }
                )
                .zIndex(100)
            }
        }
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
        .onChange(of: settingsManager.defaultStartTab) { newValue in
            switch newValue {
            case .playlists: selectedTab = .playlists
            case .search:    selectedTab = .search
            case .more:      selectedTab = .more
            case .favorites: selectedTab = .favorites
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                favoritesManager.flushPendingWrites()
                playlistsManager.flushPendingWrites()
                recentlyPlayedManager.flushPendingWrites()
            }
        }
    }

    private func expandPlayer() {
        Haptics.light()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            showFullPlayer = true
        }
    }

    private func dismissPlayer() {
        Haptics.light()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            showFullPlayer = false
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .favorites:
            FavoritesView(
                playerManager: playerManager,
                favoritesManager: favoritesManager,
                recentlyPlayedManager: recentlyPlayedManager,
                themeManager: themeManager
            )
        case .playlists:
            PlaylistsView(
                playerManager: playerManager,
                playlistsManager: playlistsManager,
                recentlyPlayedManager: recentlyPlayedManager,
                favoritesManager: favoritesManager,
                themeManager: themeManager
            )
        case .search:
            SearchView(
                playerManager: playerManager,
                recentlyPlayedManager: recentlyPlayedManager,
                themeManager: themeManager,
                settingsManager: settingsManager,
                selectedTab: $selectedTab
            )
        case .more:
            MoreView(
                playerManager: playerManager,
                settingsManager: settingsManager,
                favoritesManager: favoritesManager,
                playlistsManager: playlistsManager,
                recentlyPlayedManager: recentlyPlayedManager,
                themeManager: themeManager
            )
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabBarButton(tab: .favorites, icon: "heart", label: "Favorites")
            tabBarButton(tab: .playlists, icon: "music.note.list", label: "Playlists")
            tabBarButton(tab: .search, icon: "magnifyingglass", label: "Search")
            tabBarButton(tab: .more, icon: "ellipsis", label: "More")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(themeManager.tokens.surface.opacity(0.4))
            }
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(themeManager.tokens.hairline, lineWidth: 0.5)
        )
        .clipShape(Capsule(style: .continuous))
        .padding(.horizontal, DS.Spacing.lg)
        .miniPlayerShadow()
    }

    private func tabBarButton(tab: AppTab, icon: String, label: String) -> some View {
        let isSelected = selectedTab == tab
        let fillableIcons: Set<String> = ["heart"]
        let symbolName = (isSelected && fillableIcons.contains(icon)) ? "\(icon).fill" : icon
        let accent = themeManager.tokens.accent

        return Button {
            guard !isSelected else { return }
            Haptics.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                selectedTab = tab
            }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(accent.opacity(0.20))
                            .matchedGeometryEffect(id: "tabIndicator", in: indicatorNamespace)
                            .frame(width: 56, height: 28)
                    }
                    Image(systemName: symbolName)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? accent : themeManager.tokens.textSecondary)
                        .frame(width: 56, height: 28)
                }
                Text(label)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? accent : themeManager.tokens.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @Namespace private var indicatorNamespace
}

enum AppTab: Hashable {
    case favorites, playlists, search, more
}
