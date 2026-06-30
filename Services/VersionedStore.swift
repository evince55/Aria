import Foundation

/// On-disk wrapper that tags a store's payload with a schema version:
/// `{ "schemaVersion": N, "items": [...] }`.
///
/// Why this exists: every user-data store (favorites, playlists,
/// recently-played, local library) used to persist a *bare top-level array*.
/// The moment the `Track` / `Playlist` model gains a required field, decoding
/// an old file fails wholesale and the `try?` in each manager silently drops
/// the entire collection. Versioning lets a future migration recognise an old
/// payload and upgrade it instead of losing it.
struct VersionedEnvelope<Item: Codable>: Codable {
    var schemaVersion: Int
    var items: [Item]
}

/// Decode/encode helpers that add schema versioning + corruption quarantine on
/// top of the raw `KeyValueStore` byte seam. Stateless; all behaviour is in the
/// two static methods below.
enum SchemaStore {

    // MARK: - Array payloads (favorites / playlists / recents / library)

    /// Encode `items` into the current versioned envelope.
    static func encode<Item: Codable>(_ items: [Item], schemaVersion: Int) throws -> Data {
        try JSONEncoder().encode(VersionedEnvelope(schemaVersion: schemaVersion, items: items))
    }

    /// Load + migrate an array payload from `store`.
    ///
    /// Resolution order:
    /// 1. **Current envelope** `{schemaVersion, items}` — decode and return.
    /// 2. **Legacy bare array** `[...]` (the pre-versioning format) — decode and
    ///    return; the next `save` rewrites it in the envelope format. A bare
    ///    array can't decode as an object and vice-versa, so the two formats are
    ///    unambiguous.
    /// 3. **Undecodable** — quarantine the bytes via `backupCorrupt` and return
    ///    `nil`, so the caller keeps its empty default instead of crashing.
    ///
    /// Returns `nil` when nothing is stored yet (first launch).
    static func loadItems<Item: Codable>(
        _ type: Item.Type,
        from store: KeyValueStore,
        currentVersion: Int
    ) -> [Item]? {
        guard let data = store.load() else { return nil }
        let decoder = JSONDecoder()

        if let env = try? decoder.decode(VersionedEnvelope<Item>.self, from: data) {
            return env.items
        }
        if let legacy = try? decoder.decode([Item].self, from: data) {
            return legacy
        }
        store.backupCorrupt(data)
        return nil
    }

    // MARK: - Single-value payloads (playback state)

    /// Encode a single `Codable` value (used by the playback-state store, whose
    /// payload is one object, not an array). The value type is expected to carry
    /// its own `schemaVersion` field.
    static func encodeValue<Value: Codable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// Load a single `Codable` value, quarantining undecodable bytes the same
    /// way `loadItems` does. Returns `nil` on first launch or after a corrupt
    /// payload is moved aside.
    static func loadValue<Value: Codable>(
        _ type: Value.Type,
        from store: KeyValueStore
    ) -> Value? {
        guard let data = store.load() else { return nil }
        if let value = try? JSONDecoder().decode(Value.self, from: data) {
            return value
        }
        store.backupCorrupt(data)
        return nil
    }
}
