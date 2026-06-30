import Foundation

/// A minimal key-value persistence seam for the user-data stores
/// (FavoritesManager, PlaylistsManager, RecentlyPlayedManager).
///
/// Each store previously hardcoded its own `documentDirectory/<file>.json`
/// path and its own atomic-write + JSON-decode dance. Three near-identical
/// implementations; one place to change behavior. The protocol makes the
/// disk-vs-memory choice an init-time decision so tests can use an
/// `InMemoryKeyValueStore` and production gets the file-backed default.
protocol KeyValueStore: AnyObject {
    /// Returns the persisted bytes, or `nil` if nothing has been stored.
    func load() -> Data?
    /// Writes the bytes atomically. Throws on failure (caller decides how
    /// to surface this — the production stores currently swallow the error
    /// because user data is recoverable from `@Published` state on next
    /// launch).
    func save(_ data: Data) throws

    /// Moves undecodable bytes aside so the next `save(_:)` starts clean
    /// without silently destroying the user's data. Called by the schema
    /// layer when a load fails to decode (corruption or an unsupported
    /// future format). Best-effort: failures here are non-fatal.
    func backupCorrupt(_ data: Data)
}

/// File-backed implementation. Writes are atomic; reads are best-effort
/// and return `nil` on any I/O or decoding error (matching the prior
/// `try? Data(contentsOf:)` behavior).
final class JSONFileStore: KeyValueStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    convenience init(
        filename: String,
        in directory: FileManager.SearchPathDirectory = .documentDirectory
    ) {
        let dir = FileManager.default.urls(for: directory, in: .userDomainMask)[0]
        self.init(url: dir.appendingPathComponent(filename))
    }

    func load() -> Data? {
        try? Data(contentsOf: url)
    }

    func save(_ data: Data) throws {
        try AtomicFileWriter.writeAtomically(data, to: url)
    }

    /// Writes the corrupt bytes to a sibling `<file>.corrupt-<unixtime>` so a
    /// support/debug pass can recover them, then leaves `url` untouched (the
    /// caller starts from empty state and the next save overwrites it).
    func backupCorrupt(_ data: Data) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backupURL = url.appendingPathExtension("corrupt-\(stamp)")
        try? data.write(to: backupURL, options: .atomic)
    }
}

/// In-memory implementation for tests. Behaves like a tiny key-value
/// store; never touches the file system, so tests run in any directory
/// and don't need cleanup.
final class InMemoryKeyValueStore: KeyValueStore {
    private var data: Data?
    /// Counts how many times `save(_:)` was called. Useful for asserting
    /// that the debouncer actually coalesced bursts of writes.
    private(set) var saveCount: Int = 0
    /// Corrupt payloads handed to `backupCorrupt(_:)`, newest last. Lets tests
    /// assert that undecodable data was quarantined rather than dropped.
    private(set) var backedUpCorrupt: [Data] = []

    init(seed: Data? = nil) {
        self.data = seed
    }

    func load() -> Data? { data }

    func save(_ data: Data) throws {
        self.data = data
        saveCount += 1
    }

    func backupCorrupt(_ data: Data) {
        backedUpCorrupt.append(data)
    }
}
