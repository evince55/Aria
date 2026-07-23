import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var playerManager: PlayerManager
    @EnvironmentObject private var favoritesManager: FavoritesManager
    @EnvironmentObject private var playlistsManager: PlaylistsManager
    @EnvironmentObject private var recentlyPlayedManager: RecentlyPlayedManager
    @EnvironmentObject private var settingsManager: SettingsManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var localLibraryManager: LocalLibraryManager
    @EnvironmentObject private var downloadManager: DownloadManager
    @EnvironmentObject private var eqController: EQController

    @State private var selectedTab: AppTab
    @State private var showFullPlayer = false
    @State private var errorBanner: String?
    /// Single in-flight auto-dismiss timer for the error banner. Held so a
    /// newer error can cancel the previous timer before arming its own —
    /// otherwise an older 4s timer would clear the newer banner early.
    @State private var bannerDismiss: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Show/hide the full-screen player, skipping the slide spring when Reduce
    /// Motion is on (the view still cross-fades via its transition).
    private func setFullPlayer(_ shown: Bool) {
        if reduceMotion {
            showFullPlayer = shown
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                showFullPlayer = shown
            }
        }
    }

    /// Search (YouTube streaming) needs a configured backend; without one the
    /// app runs as a local-files player and the Search tab hides entirely.
    private var searchAvailable: Bool { BackendConfig.isConfigured }

    init(initialTab: AppTab = .favorites) {
        // A start tab pointing at the (hidden) Search tab falls back to
        // Library when no backend is configured.
        let tab = (initialTab == .search && !BackendConfig.isConfigured) ? AppTab.library : initialTab
        _selectedTab = State(initialValue: tab)
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
                        setFullPlayer(true)
                    }
                }

                customTabBar
            }

            if showFullPlayer {
                FullScreenPlayerView(onDismiss: { setFullPlayer(false) })
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .overlay(alignment: .top) {
            if let msg = errorBanner {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(msg)
                        .scaledFont(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundColor(.white)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.85))
                )
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.top, DS.Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(200)
            }
        }
        .onChange(of: playerManager.playerError) { error in
            let message: String?
            switch error {
            case .streamFailed(let msg): message = msg
            case .trackMissing: message = "That file is missing — re-import it from the Library tab."
            case nil: message = nil
            }
            guard let msg = message else { return }
            withAnimation(.spring(response: 0.3)) { errorBanner = msg }
            bannerDismiss?.cancel()
            bannerDismiss = Task { await dismissBanner() }
        }
        .onChange(of: downloadManager.lastError) { msg in
            guard let msg else { return }
            withAnimation(.spring(response: 0.3)) { errorBanner = msg }
            bannerDismiss?.cancel()
            bannerDismiss = Task { await dismissBanner() }
        }
        .preferredColorScheme(themeManager.isDarkMode ? .dark : .light)
        .onChange(of: settingsManager.defaultStartTab) { newValue in
            switch newValue {
            case .playlists: selectedTab = .playlists
            case .search:    selectedTab = searchAvailable ? .search : .library
            case .more:      selectedTab = .more
            case .favorites: selectedTab = .favorites
            }
        }
        .onChange(of: settingsManager.backendURLOverride) { _ in
            // Clearing the server while on Search would strand a hidden tab.
            if !searchAvailable, selectedTab == .search { selectedTab = .library }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .background || newPhase == .inactive {
                flushAllStores()
            } else if newPhase == .active {
                localLibraryManager.cleanupOrphans()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification
        )) { _ in
            // scenePhase doesn't reliably fire .background before a terminate,
            // so flush here too to shrink the crash/kill data-loss window.
            flushAllStores()
        }
        .onAppear {
            // Connect favorites so the lock-screen Like command works.
            playerManager.configureFavorites(favoritesManager)
            playerManager.configureDownloads(downloadManager)
            if ProcessInfo.processInfo.arguments.contains("--debug-fake-track")
                || UserDefaults.standard.bool(forKey: "debug_fake_track") {
                playerManager.loadDebugFakeTrack()
                showFullPlayer = true
            }
        }
    }

    // MARK: - Persistence

    /// Flush every debounced store so in-flight user data is durable before the
    /// app is suspended or killed.
    private func flushAllStores() {
        favoritesManager.flushPendingWrites()
        playlistsManager.flushPendingWrites()
        recentlyPlayedManager.flushPendingWrites()
        localLibraryManager.flushPendingWrites()
        downloadManager.flushPendingWrites()
        playerManager.flushPendingWrites()
        eqController.flushPendingWrites()
    }

    /// Hides the error banner after a delay, then clears BOTH error sources.
    /// The banner shows one error at a time, so a source that was superseded by
    /// a newer error must still be cleared here — otherwise its property stays
    /// set and an identical repeat error wouldn't re-fire `onChange`.
    private func dismissBanner() async {
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard !Task.isCancelled else { return }
        withAnimation { errorBanner = nil }
        playerManager.playerError = nil
        downloadManager.lastError = nil
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
            LibraryView(library: localLibraryManager)
        case .search:
            SearchView()
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
            if searchAvailable {
                tabBarButton(tab: .search, icon: "magnifyingglass", label: "Search")
            }
            tabBarButton(tab: .more, icon: "ellipsis", label: "More")
        }
        .padding(.horizontal, DS.Spacing.xs)
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
                    .scaledFont(size: 10, weight: selectedTab == tab ? .semibold : .regular, relativeTo: .caption2)
            }
            // Fixed-height tab bar: scale the label through the standard sizes,
            // but clamp before the accessibility sizes break the bar layout.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundColor(selectedTab == tab ? themeManager.theme.accentColor : themeManager.textSecondary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
    }
}

enum AppTab {
    case favorites, playlists, library, search, more
}
