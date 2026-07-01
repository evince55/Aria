import Foundation
import Combine

final class RecentlyPlayedManager: ObservableObject {
    /// Bump when `Track`'s on-disk shape needs a migration. v1 = first
    /// versioned envelope (migrated from the legacy bare-array files).
    static let schemaVersion = 1

    private let maxTracks = 100

    @Published var recentlyPlayed: [Track] = []
    @Published var recentlyAdded: [Track] = []

    private let playedStore: KeyValueStore
    private let addedStore: KeyValueStore
    private var playedDebouncer: Debouncer!
    private var addedDebouncer: Debouncer!

    init(
        playedStore: KeyValueStore = JSONFileStore(filename: "recently_played.json"),
        addedStore: KeyValueStore = JSONFileStore(filename: "recently_added.json")
    ) {
        self.playedStore = playedStore
        self.addedStore = addedStore
        self.playedDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSavePlayed() }
        self.addedDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSaveAdded() }
        load()
    }

    deinit {
        // The debouncers' actions capture [weak self], already nil during deinit,
        // so flush() would silently drop a pending write. Persist synchronously.
        if playedDebouncer?.isPending == true {
            playedDebouncer?.cancel()
            performSavePlayed()
        }
        if addedDebouncer?.isPending == true {
            addedDebouncer?.cancel()
            performSaveAdded()
        }
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
        guard let data = try? SchemaStore.encode(recentlyPlayed, schemaVersion: Self.schemaVersion) else { return }
        try? playedStore.save(data)
    }

    private func performSaveAdded() {
        guard let data = try? SchemaStore.encode(recentlyAdded, schemaVersion: Self.schemaVersion) else { return }
        try? addedStore.save(data)
    }

    private func load() {
        if let saved = SchemaStore.loadItems(Track.self, from: playedStore, currentVersion: Self.schemaVersion) {
            recentlyPlayed = saved
        }
        if let saved = SchemaStore.loadItems(Track.self, from: addedStore, currentVersion: Self.schemaVersion) {
            recentlyAdded = saved
        }
    }
}
