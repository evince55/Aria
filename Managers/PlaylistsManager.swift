import Foundation
import Combine

enum PlaylistSortOrder: String, CaseIterable {
    case alphabetical = "Alphabetical"
    case recentlyPlayed = "Recently Played"
}

final class PlaylistsManager: ObservableObject {
    /// Bump when `Playlist`'s on-disk shape needs a migration. v1 = first
    /// versioned envelope (migrated from the legacy bare-array file).
    static let schemaVersion = 1

    @Published var playlists: [Playlist] = [] {
        didSet { recomputeSorted() }
    }
    @Published var sortOrder: PlaylistSortOrder = .recentlyPlayed {
        didSet { recomputeSorted() }
    }

    @Published private(set) var sortedPlaylists: [Playlist] = []
    @Published private(set) var recentlyPlayedPlaylists: [Playlist] = []

    private let store: KeyValueStore
    private var saveDebouncer: Debouncer!

    init(store: KeyValueStore = JSONFileStore(filename: "playlists.json")) {
        self.store = store
        self.saveDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
        load()
        recomputeSorted()
    }

    // flush() is a no-op in deinit (its [weak self] is already nil); save direct.
    deinit { if saveDebouncer?.isPending == true { performSave() } }

    func create(name: String) -> Playlist {
        let playlist = Playlist(name: name, tracks: [])
        playlists.append(playlist)
        save()
        return playlist
    }

    /// Create a playlist pre-populated with `tracks`, preserving order and
    /// dropping duplicate ids. Used by "Save Queue as Playlist".
    @discardableResult
    func create(name: String, tracks: [Track]) -> Playlist {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.id).inserted }
        let playlist = Playlist(name: name, tracks: unique)
        playlists.append(playlist)
        save()
        return playlist
    }

    func delete(_ playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    /// Reorder tracks within a playlist (drag-to-reorder from the detail view).
    func moveTrack(in playlist: Playlist, from offsets: IndexSet, to destination: Int) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].tracks.moveElements(fromOffsets: offsets, toOffset: destination)
        save()
    }

    func deleteAll() {
        playlists.removeAll()
        save()
    }

    func rename(_ playlist: Playlist, to name: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].name = name
        save()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard !playlists[idx].tracks.contains(where: { $0.id == track.id }) else { return }
        playlists[idx].tracks.append(track)
        playlists[idx].lastPlayedAt = Date()
        save()
    }

    func removeTrack(_ track: Track, from playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].tracks.removeAll { $0.id == track.id }
        save()
    }

    func markPlayed(_ playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx].lastPlayedAt = Date()
        save()
    }

    private func recomputeSorted() {
        switch sortOrder {
        case .alphabetical:
            sortedPlaylists = playlists.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlyPlayed:
            sortedPlaylists = playlists.sorted {
                ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
            }
        }
        recentlyPlayedPlaylists = playlists
            .filter { $0.lastPlayedAt != nil }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }

    private func save() {
        saveDebouncer.call()
    }

    private func performSave() {
        guard let data = try? SchemaStore.encode(playlists, schemaVersion: Self.schemaVersion) else { return }
        try? store.save(data)
    }

    /// Force any pending debounced save to flush immediately.
    func flushPendingWrites() {
        saveDebouncer?.flush()
    }

    private func load() {
        guard let saved = SchemaStore.loadItems(Playlist.self, from: store, currentVersion: Self.schemaVersion) else { return }
        playlists = saved
    }
}
