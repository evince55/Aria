import AVFoundation
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "AriaApp")

@main
struct AriaApp: App {
    @StateObject private var playerManager: PlayerManager
    @StateObject private var favoritesManager = FavoritesManager()
    @StateObject private var playlistsManager = PlaylistsManager()
    @StateObject private var recentlyPlayedManager = RecentlyPlayedManager()
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var themeManager: ThemeManager
    @StateObject private var eqController: EQController
    @StateObject private var localLibraryManager: LocalLibraryManager
    @StateObject private var navigationCoordinator = NavigationCoordinator()

    init() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.mixWithOthers]
            )
        } catch {
            log.error("Failed to set audio session category: \(error.localizedDescription, privacy: .public)")
        }
        let settings = SettingsManager()
        let eq = EQController()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let libraryDir = docs.appendingPathComponent("AriaLibrary", isDirectory: true)
        let libraryManager = LocalLibraryManager(
            store: JSONFileStore(filename: "local_library.json"),
            libraryDirectory: libraryDir
        )
        _themeManager = StateObject(wrappedValue: ThemeManager(settings: settings))
        _settingsManager = StateObject(wrappedValue: settings)
        _eqController = StateObject(wrappedValue: eq)
        _localLibraryManager = StateObject(wrappedValue: libraryManager)
        _playerManager = StateObject(wrappedValue: PlayerManager(urlSession: Self.makeProductionSession(), eq: eq))
    }

    private static func makeProductionSession() -> URLSessionProtocol {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.urlCache = URLCache.shared
        let session = URLSession(
            configuration: config,
            delegate: TLSPinningDelegate(),
            delegateQueue: nil
        )
        return URLSessionAdapter(session: session)
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
                .environmentObject(eqController)
                .environmentObject(localLibraryManager)
                .environmentObject(navigationCoordinator)
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
