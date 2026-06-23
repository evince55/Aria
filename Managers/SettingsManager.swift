import Foundation
import Combine

enum DefaultStartTab: String, CaseIterable {
    case favorites = "Favorites"
    case playlists = "Playlists"
    case search = "Search"
    case more = "More"
}

enum SleepTimerDuration: String, CaseIterable {
    case off = "Off"
    case min15 = "15 min"
    case min30 = "30 min"
    case min45 = "45 min"
    case hour1 = "1 hour"
    case hour2 = "2 hours"
}

final class SettingsManager: ObservableObject {
    @Published var defaultStartTab: DefaultStartTab = .favorites
    @Published var isDarkMode: Bool = true
    @Published var selectedThemeID: String = "blue"
    @Published var sleepTimer: SleepTimerDuration = .off
    @Published private(set) var searchHistory: [String] = []

    private let maxHistoryItems = 20
    private let defaults = UserDefaults.standard

    init() { load() }

    func addSearchToHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        searchHistory.removeAll { $0 == trimmed }
        searchHistory.insert(trimmed, at: 0)
        if searchHistory.count > maxHistoryItems {
            searchHistory = Array(searchHistory.prefix(maxHistoryItems))
        }
        save()
    }

    func removeSearchHistoryItem(_ item: String) {
        searchHistory.removeAll { $0 == item }
        save()
    }

    func clearSearchHistory() {
        searchHistory.removeAll()
        save()
    }

    private func load() {
        if let raw = defaults.string(forKey: "default_start_tab"),
           let val = DefaultStartTab(rawValue: raw) { defaultStartTab = val }
        isDarkMode = defaults.object(forKey: "dark_mode") as? Bool ?? true
        selectedThemeID = defaults.string(forKey: "theme_id") ?? "blue"
        if let raw = defaults.string(forKey: "sleep_timer"),
           let val = SleepTimerDuration(rawValue: raw) { sleepTimer = val }
        if let history = defaults.stringArray(forKey: "search_history") {
            searchHistory = history
        }
    }

    func save() {
        defaults.set(defaultStartTab.rawValue, forKey: "default_start_tab")
        defaults.set(isDarkMode, forKey: "dark_mode")
        defaults.set(selectedThemeID, forKey: "theme_id")
        defaults.set(sleepTimer.rawValue, forKey: "sleep_timer")
        defaults.set(searchHistory, forKey: "search_history")
    }

    func setTheme(_ id: String) {
        selectedThemeID = id
        save()
    }
}
