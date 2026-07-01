import Foundation
import Combine

final class FavoritesManager: ObservableObject {
    /// Bump when `Track`'s on-disk shape needs a migration. v1 = first
    /// versioned envelope (migrated transparently from the legacy bare-array
    /// file on first load).
    static let schemaVersion = 1

    @Published var tracks: [Track] = [] {
        didSet { recomputeGrouped() }
    }

    @Published private(set) var grouped: [(letter: String, tracks: [Track])] = []

    private let store: KeyValueStore
    private var saveDebouncer: Debouncer!

    deinit {
        // saveDebouncer.flush() can't help here: its action captures [weak self],
        // already nil during deinit, so a pending write would be silently dropped.
        // Persist synchronously instead.
        if saveDebouncer?.isPending == true {
            saveDebouncer?.cancel()
            performSave()
        }
    }

    init(store: KeyValueStore = JSONFileStore(filename: "favorites.json")) {
        self.store = store
        self.saveDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
        load()
        recomputeGrouped()
    }

    func isFavorite(_ track: Track) -> Bool {
        tracks.contains(where: { $0.id == track.id })
    }

    func toggle(_ track: Track) {
        if let idx = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks.remove(at: idx)
        } else {
            tracks.append(track)
        }
        save()
    }

    func add(_ track: Track) {
        guard !isFavorite(track) else { return }
        tracks.append(track)
        save()
    }

    func remove(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        save()
    }

    func removeAll() {
        tracks.removeAll()
        save()
    }

    /// Backwards-compatible accessor. Prefer the published `grouped` property.
    func groupedByLetter() -> [(letter: String, tracks: [Track])] {
        grouped
    }

    private func recomputeGrouped() {
        let sorted = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        let dict = Dictionary(grouping: sorted) { $0.firstLetter }
        grouped = dict.keys.sorted().map { ($0, dict[$0] ?? []) }
    }

    private func save() {
        saveDebouncer.call()
    }

    private func performSave() {
        guard let data = try? SchemaStore.encode(tracks, schemaVersion: Self.schemaVersion) else { return }
        try? store.save(data)
    }

    /// Force any pending debounced save to flush immediately. Call from
    /// `applicationWillTerminate` or scenePhase transitions.
    func flushPendingWrites() {
        saveDebouncer?.flush()
    }

    private func load() {
        guard let saved = SchemaStore.loadItems(Track.self, from: store, currentVersion: Self.schemaVersion) else { return }
        tracks = saved
    }
}
