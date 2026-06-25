import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var localLibraryManager: LocalLibraryManager

    @State private var selectedTab: AppTab
    @State private var showFullPlayer = false
    @Environment(\.scenePhase) private var scenePhase

    init(initialTab: AppTab = .favorites) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        ZStack {
            themeManager.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                tabContent
                    .frame(maxHeight: .infinity)

                if playerManager.currentTrack != nil {
                    MiniPlayerView {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            showFullPlayer = true
                        }
                    }
                }

                customTabBar
            }

            if showFullPlayer {
                FullScreenPlayerView(onDismiss: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        showFullPlayer = false
                    }
                })
                .transition(.move(edge: .bottom))
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
                localLibraryManager.flushPendingWrites()
            } else if newPhase == .active {
                localLibraryManager.cleanupOrphans()
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--debug-fake-track")
                || UserDefaults.standard.bool(forKey: "debug_fake_track") {
                playerManager.loadDebugFakeTrack()
                showFullPlayer = true
            }
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .favorites:
            FavoritesView()
        case .playlists:
            PlaylistsView()
        case .library:
            LibraryView()
        case .search:
            SearchView(selectedTab: $selectedTab)
        case .more:
            MoreView()
        }
    }

    // MARK: - Custom Tab Bar

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabBarButton(tab: .favorites, icon: "heart", label: "Favorites")
            tabBarButton(tab: .playlists, icon: "music.note.list", label: "Playlists")
            tabBarButton(tab: .library, icon: "folder", label: "Library")
            tabBarButton(tab: .search, icon: "magnifyingglass", label: "Search")
            tabBarButton(tab: .more, icon: "ellipsis", label: "More")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(themeManager.surface)
    }

    private var allowedFillIcons: Set<String> { ["heart"] }

    private func tabBarButton(tab: AppTab, icon: String, label: String) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                let selectedIcon = allowedFillIcons.contains(icon)
                    ? "\(icon).fill"
                    : icon
                Image(systemName: selectedTab == tab ? selectedIcon : icon)
                    .font(.system(size: 18, weight: selectedTab == tab ? .semibold : .regular))
                    .frame(height: 22)
                Text(label)
                    .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
            }
            .foregroundColor(selectedTab == tab ? themeManager.theme.accentColor : themeManager.textSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

enum AppTab {
    case favorites, playlists, library, search, more
}
