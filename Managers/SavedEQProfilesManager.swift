import Foundation
import Combine

/// Keeps the user's headphone EQ profiles so switching between them is one tap
/// instead of a re-download. Profiles are added automatically whenever one is
/// applied (you found it, you'll want it again) and can be removed by hand.
///
/// Ordering is most-recently-used first — with a handful of headphones that
/// puts the one you're switching back to at the top.
final class SavedEQProfilesManager: ObservableObject {
    /// Bump when `SavedEQProfile`'s on-disk shape needs a migration.
    static let schemaVersion = 1

    @Published private(set) var profiles: [SavedEQProfile] = []

    private let store: KeyValueStore
    private var debouncer: Debouncer!

    /// Defaults to an in-memory store so directly-constructed instances (tests,
    /// previews) never touch the real Documents directory; `AriaApp` injects
    /// the file-backed store.
    init(store: KeyValueStore = InMemoryKeyValueStore()) {
        self.store = store
        if let saved = SchemaStore.loadItems(SavedEQProfile.self, from: store,
                                             currentVersion: Self.schemaVersion) {
            profiles = saved.sorted { $0.lastUsedAt > $1.lastUsedAt }
        }
        self.debouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
    }

    // flush() is a no-op in deinit (its [weak self] is already nil); save direct.
    deinit { if debouncer?.isPending == true { performSave() } }

    /// Records `preset` as used now. Identity is the preset itself, so
    /// re-applying the same headphone refreshes its position instead of adding
    /// a duplicate; a different measurement of the same headphone (different
    /// source, so different bands) is legitimately a separate profile.
    func remember(_ preset: ParametricEQPreset, now: Date = Date()) {
        if let index = profiles.firstIndex(where: { $0.preset == preset }) {
            profiles[index].lastUsedAt = now
        } else {
            profiles.append(SavedEQProfile(preset: preset, lastUsedAt: now))
        }
        profiles.sort { $0.lastUsedAt > $1.lastUsedAt }
        save()
    }

    func delete(_ profile: SavedEQProfile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func deleteAll() {
        profiles.removeAll()
        save()
    }

    // MARK: - Persistence

    func flushPendingWrites() { debouncer?.flush() }

    private func save() { debouncer.call() }

    private func performSave() {
        guard let data = try? SchemaStore.encode(profiles, schemaVersion: Self.schemaVersion) else { return }
        try? store.save(data)
    }
}
