import Foundation
import Combine

/// Owns the persisted smart-playlist definitions (rules only — results are
/// re-evaluated live by `SmartPlaylistEngine`, never snapshotted).
final class SmartPlaylistsManager: ObservableObject {
    /// Bump when `SmartPlaylist`'s on-disk shape needs a migration.
    static let schemaVersion = 1

    @Published private(set) var playlists: [SmartPlaylist] = []

    private let store: KeyValueStore
    private var debouncer: Debouncer!

    /// Defaults to an in-memory store so directly-constructed instances (tests,
    /// previews) never touch the real Documents directory; `AriaApp` injects
    /// the file-backed store.
    init(store: KeyValueStore = InMemoryKeyValueStore()) {
        self.store = store
        if let saved = SchemaStore.loadItems(SmartPlaylist.self, from: store,
                                             currentVersion: Self.schemaVersion) {
            playlists = saved
        }
        self.debouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
    }

    // flush() is a no-op in deinit (its [weak self] is already nil); save direct.
    deinit { if debouncer?.isPending == true { performSave() } }

    // MARK: - CRUD

    /// Insert-or-replace by id — the editor calls this for both create and edit.
    func upsert(_ playlist: SmartPlaylist) {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
        save()
    }

    func delete(_ playlist: SmartPlaylist) {
        playlists.removeAll { $0.id == playlist.id }
        save()
    }

    func deleteAll() {
        playlists.removeAll()
        save()
    }

    // MARK: - Persistence

    func flushPendingWrites() { debouncer?.flush() }

    private func save() { debouncer.call() }

    private func performSave() {
        guard let data = try? SchemaStore.encode(playlists, schemaVersion: Self.schemaVersion) else { return }
        try? store.save(data)
    }
}
