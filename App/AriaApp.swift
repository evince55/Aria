import AVFoundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "AriaApp")

@main
struct AriaApp: App {
    @StateObject private var playerManager = PlayerManager()
    @StateObject private var favoritesManager = FavoritesManager()
    @StateObject private var playlistsManager = PlaylistsManager()
    @StateObject private var recentlyPlayedManager = RecentlyPlayedManager()
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var themeManager: ThemeManager

    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers]
            )
        } catch {
            log.error("Failed to set audio session category: \(error.localizedDescription, privacy: .public)")
        }
        let settings = SettingsManager()
        _themeManager = StateObject(wrappedValue: ThemeManager(settings: settings))
        _settingsManager = StateObject(wrappedValue: settings)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(initialTab: initialTab)
                .environmentObject(playerManager)
                .environmentObject(favoritesManager)
                .environmentObject(playlistsManager)
                .environmentObject(recentlyPlayedManager)
                .environmentObject(settingsManager)
                .environmentObject(themeManager)
        }
    }

    private var initialTab: AppTab {
        switch settingsManager.defaultStartTab {
        case .playlists: return .playlists
        case .search:    return .search
        case .more:      return .more
        case .favorites: return .favorites
        }
    }
}
