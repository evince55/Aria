import SwiftUI

/// Type-safe environment keys for the app's cross-cutting state holders.
///
/// Each manager is owned by `AriaApp` as a `@StateObject` and injected once
/// at the root via `.environmentObject(...)`. Child views read them with
/// `@EnvironmentObject` so they no longer need to be threaded through every
/// initializer.
///
/// These keys are used by callers that want a non-optional default (e.g.,
/// previews). The standard `@EnvironmentObject` declaration in views reads
/// directly from the runtime environment, not from these keys.

private struct PlayerManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: PlayerManager { PlayerManager() }
}

private struct FavoritesManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: FavoritesManager { FavoritesManager() }
}

private struct PlaylistsManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: PlaylistsManager { PlaylistsManager() }
}

private struct RecentlyPlayedManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: RecentlyPlayedManager { RecentlyPlayedManager() }
}

private struct SettingsManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: SettingsManager { SettingsManager() }
}

private struct ThemeManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: ThemeManager { ThemeManager(settings: SettingsManager()) }
}

private struct EQControllerKey: EnvironmentKey {
    @MainActor static var defaultValue: EQController { EQController() }
}

private struct LocalLibraryManagerKey: EnvironmentKey {
    @MainActor static var defaultValue: LocalLibraryManager {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("AriaLibrary", isDirectory: true)
        return LocalLibraryManager(
            store: JSONFileStore(filename: "local_library.json"),
            libraryDirectory: dir
        )
    }
}

private struct NavigationCoordinatorKey: EnvironmentKey {
    @MainActor static var defaultValue: NavigationCoordinator { NavigationCoordinator() }
}

extension EnvironmentValues {
    var playerManager: PlayerManager {
        get { self[PlayerManagerKey.self] }
        set { self[PlayerManagerKey.self] = newValue }
    }
    var favoritesManager: FavoritesManager {
        get { self[FavoritesManagerKey.self] }
        set { self[FavoritesManagerKey.self] = newValue }
    }
    var playlistsManager: PlaylistsManager {
        get { self[PlaylistsManagerKey.self] }
        set { self[PlaylistsManagerKey.self] = newValue }
    }
    var recentlyPlayedManager: RecentlyPlayedManager {
        get { self[RecentlyPlayedManagerKey.self] }
        set { self[RecentlyPlayedManagerKey.self] = newValue }
    }
    var settingsManager: SettingsManager {
        get { self[SettingsManagerKey.self] }
        set { self[SettingsManagerKey.self] = newValue }
    }
    var themeManager: ThemeManager {
        get { self[ThemeManagerKey.self] }
        set { self[ThemeManagerKey.self] = newValue }
    }
    var eqController: EQController {
        get { self[EQControllerKey.self] }
        set { self[EQControllerKey.self] = newValue }
    }
    var localLibraryManager: LocalLibraryManager {
        get { self[LocalLibraryManagerKey.self] }
        set { self[LocalLibraryManagerKey.self] = newValue }
    }
    var navigationCoordinator: NavigationCoordinator {
        get { self[NavigationCoordinatorKey.self] }
        set { self[NavigationCoordinatorKey.self] = newValue }
    }
}
