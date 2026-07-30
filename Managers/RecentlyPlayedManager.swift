import Foundation
import Combine

final class RecentlyPlayedManager: ObservableObject {
    /// Bump when `Track`'s on-disk shape needs a migration. v1 = first
    /// versioned envelope (migrated from the legacy bare-array files).
    static let schemaVersion = 1

    /// Per-track play statistics kept for the library search index's
    /// affinity flags ("recent" / "frequent" / "dormant" — see
    /// `LibrarySyncService`). The MRU `recentlyPlayed` list has no
    /// timestamps or counts, so this map is the only durable record of
    /// *when* and *how often* a track was played.
    struct PlayStat: Codable, Equatable {
        var lastPlayedAt: Date
        var playCount: Int
    }

    /// On-disk envelope for `playStats` (a single dictionary, not an
    /// array, so it goes through `SchemaStore.encodeValue`/`loadValue`).
    private struct PlayStatsEnvelope: Codable {
        var schemaVersion: Int
        var stats: [String: PlayStat]
    }

    private let maxTracks = 100
    /// Cap the stats map so it can't grow unbounded over years of use;
    /// pruning drops the entries with the oldest `lastPlayedAt` (those
    /// are already deep-dormant, so the affinity signal barely changes).
    private let maxStatsEntries = 2000

    @Published var recentlyPlayed: [Track] = []
    @Published var recentlyAdded: [Track] = []
    @Published private(set) var playStats: [String: PlayStat] = [:]

    private let playedStore: KeyValueStore
    private let addedStore: KeyValueStore
    private let statsStore: KeyValueStore
    private var playedDebouncer: Debouncer!
    private var addedDebouncer: Debouncer!
    private var statsDebouncer: Debouncer!

    init(
        playedStore: KeyValueStore = JSONFileStore(filename: "recently_played.json"),
        addedStore: KeyValueStore = JSONFileStore(filename: "recently_added.json"),
        statsStore: KeyValueStore = JSONFileStore(filename: "play_stats.json")
    ) {
        self.playedStore = playedStore
        self.addedStore = addedStore
        self.statsStore = statsStore
        self.playedDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSavePlayed() }
        self.addedDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSaveAdded() }
        self.statsDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSaveStats() }
        load()
    }

    // flush() is a no-op in deinit (its [weak self] is already nil); save direct.
    deinit {
        if playedDebouncer?.isPending == true { performSavePlayed() }
        if addedDebouncer?.isPending == true { performSaveAdded() }
        if statsDebouncer?.isPending == true { performSaveStats() }
    }

    /// Force any pending debounced saves to flush immediately.
    func flushPendingWrites() {
        playedDebouncer?.flush()
        addedDebouncer?.flush()
        statsDebouncer?.flush()
    }

    /// Wipes both lists and the play statistics (More → Clear Listening
    /// History). Saves go through the usual debounced path.
    func clearAll() {
        recentlyPlayed.removeAll()
        recentlyAdded.removeAll()
        playStats.removeAll()
        savePlayed()
        saveAdded()
        saveStats()
    }

    func trackPlayed(_ track: Track, at date: Date = Date()) {
        recentlyPlayed.removeAll { $0.id == track.id }
        recentlyPlayed.insert(track, at: 0)
        if recentlyPlayed.count > maxTracks {
            recentlyPlayed = Array(recentlyPlayed.prefix(maxTracks))
        }
        savePlayed()

        var stat = playStats[track.id] ?? PlayStat(lastPlayedAt: date, playCount: 0)
        stat.playCount += 1
        stat.lastPlayedAt = date
        playStats[track.id] = stat
        if playStats.count > maxStatsEntries {
            let keep = playStats.sorted { $0.value.lastPlayedAt > $1.value.lastPlayedAt }
                .prefix(maxStatsEntries)
            playStats = Dictionary(uniqueKeysWithValues: Array(keep))
        }
        saveStats()
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

    private func saveStats() {
        statsDebouncer.call()
    }

    private func performSaveStats() {
        let envelope = PlayStatsEnvelope(schemaVersion: Self.schemaVersion, stats: playStats)
        guard let data = try? SchemaStore.encodeValue(envelope) else { return }
        try? statsStore.save(data)
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
        if let envelope = SchemaStore.loadValue(PlayStatsEnvelope.self, from: statsStore) {
            playStats = envelope.stats
        }
    }
}
