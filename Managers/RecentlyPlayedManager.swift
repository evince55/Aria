import Foundation
import Combine

final class RecentlyPlayedManager: ObservableObject {
    private let maxTracks = 100

    @Published var recentlyPlayed: [Track] = []
    @Published var recentlyAdded: [Track] = []

    private let playedURL: URL
    private let addedURL: URL
    private var playedDebouncer: Debouncer!
    private var addedDebouncer: Debouncer!

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        playedURL = docs.appendingPathComponent("recently_played.json")
        addedURL = docs.appendingPathComponent("recently_added.json")
        playedDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSavePlayed() }
        addedDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSaveAdded() }
        load()
    }

    deinit {
        playedDebouncer?.flush()
        addedDebouncer?.flush()
    }

    /// Force any pending debounced saves to flush immediately.
    func flushPendingWrites() {
        playedDebouncer?.flush()
        addedDebouncer?.flush()
    }

    func trackPlayed(_ track: Track) {
        recentlyPlayed.removeAll { $0.id == track.id }
        recentlyPlayed.insert(track, at: 0)
        if recentlyPlayed.count > maxTracks {
            recentlyPlayed = Array(recentlyPlayed.prefix(maxTracks))
        }
        savePlayed()
    }

    func trackAdded(_ track: Track) {
        recentlyAdded.removeAll { $0.id == track.id }
        recentlyAdded.insert(track, at: 0)
        if recentlyAdded.count > maxTracks {
            recentlyAdded = Array(recentlyAdded.prefix(maxTracks))
        }
        saveAdded()
    }

    private func savePlayed() {
        playedDebouncer.call()
    }

    private func saveAdded() {
        addedDebouncer.call()
    }

    private func performSavePlayed() {
        guard let data = try? JSONEncoder().encode(recentlyPlayed) else { return }
        try? data.write(to: playedURL)
    }

    private func performSaveAdded() {
        guard let data = try? JSONEncoder().encode(recentlyAdded) else { return }
        try? data.write(to: addedURL)
    }

    private func load() {
        if let data = try? Data(contentsOf: playedURL),
           let saved = try? JSONDecoder().decode([Track].self, from: data) {
            recentlyPlayed = saved
        }
        if let data = try? Data(contentsOf: addedURL),
           let saved = try? JSONDecoder().decode([Track].self, from: data) {
            recentlyAdded = saved
        }
    }
}
