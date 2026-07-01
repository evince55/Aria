import XCTest
@testable import Aria___Music_Browser

final class FavoritesManagerTests: XCTestCase {
    private var manager: FavoritesManager!
    private var store: InMemoryKeyValueStore!

    override func setUp() {
        super.setUp()
        store = InMemoryKeyValueStore()
        manager = FavoritesManager(store: store)
    }

    override func tearDown() {
        manager = nil
        store = nil
        super.tearDown()
    }

    func testAddMakesFavorite() {
        let track = makeTrack(id: "1", title: "Alpha")
        manager.add(track)
        XCTAssertTrue(manager.isFavorite(track))
        XCTAssertEqual(manager.tracks.count, 1)
    }

    func testAddDuplicateIsNoOp() {
        let track = makeTrack(id: "1", title: "Alpha")
        manager.add(track)
        manager.add(track)
        XCTAssertEqual(manager.tracks.count, 1)
    }

    func testToggleAddsAndRemoves() {
        let track = makeTrack(id: "1", title: "Alpha")
        manager.toggle(track)
        XCTAssertTrue(manager.isFavorite(track))
        manager.toggle(track)
        XCTAssertFalse(manager.isFavorite(track))
    }

    func testRemoveByTrack() {
        let track = makeTrack(id: "1", title: "Alpha")
        manager.add(track)
        manager.remove(track)
        XCTAssertFalse(manager.isFavorite(track))
    }

    func testGroupedByLetterSortsAndBuckets() {
        manager.add(makeTrack(id: "1", title: "Banana"))
        manager.add(makeTrack(id: "2", title: "Apple"))
        manager.add(makeTrack(id: "3", title: "Apricot"))
        manager.add(makeTrack(id: "4", title: "Blueberry"))

        let grouped = manager.grouped
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].letter, "A")
        XCTAssertEqual(grouped[0].tracks.map(\.title), ["Apple", "Apricot"])
        XCTAssertEqual(grouped[1].letter, "B")
        XCTAssertEqual(grouped[1].tracks.map(\.title), ["Banana", "Blueberry"])
    }

    func testGroupedRecomputedOnMutation() {
        manager.add(makeTrack(id: "1", title: "A"))
        XCTAssertEqual(manager.grouped.count, 1)
        manager.add(makeTrack(id: "2", title: "B"))
        XCTAssertEqual(manager.grouped.count, 2)
    }

    func testRemoveAllClears() {
        manager.add(makeTrack(id: "1", title: "A"))
        manager.add(makeTrack(id: "2", title: "B"))
        manager.removeAll()
        XCTAssertTrue(manager.tracks.isEmpty)
    }

    func testPersistsAcrossInstances() {
        let track = makeTrack(id: "p1", title: "Persisted")
        manager.add(track)
        manager.flushPendingWrites()

        // A new manager pointed at the same store should see the saved track.
        let restored = FavoritesManager(store: store)
        XCTAssertEqual(restored.tracks.count, 1)
        XCTAssertEqual(restored.tracks.first?.id, "p1")
    }

    // MARK: - Schema versioning / migration

    func testLoadsLegacyBareArrayFile() {
        // Pre-versioning files were a bare top-level array. A manager pointed at
        // such a store must still load the data (transparent migration).
        let legacy = try! JSONEncoder().encode([
            Track(id: "old1", title: "Old", artist: "A", thumbnailURL: nil)
        ])
        let legacyStore = InMemoryKeyValueStore(seed: legacy)
        let migrated = FavoritesManager(store: legacyStore)
        XCTAssertEqual(migrated.tracks.map(\.id), ["old1"])
    }

    func testRewritesLegacyFileInVersionedFormatOnSave() throws {
        let legacy = try JSONEncoder().encode([
            Track(id: "old1", title: "Old", artist: "A", thumbnailURL: nil)
        ])
        let legacyStore = InMemoryKeyValueStore(seed: legacy)
        let migrated = FavoritesManager(store: legacyStore)
        migrated.add(makeTrack(id: "new1", title: "New"))
        migrated.flushPendingWrites()

        // The persisted bytes are now the versioned envelope, not a bare array.
        let data = try XCTUnwrap(legacyStore.load())
        let env = try JSONDecoder().decode(VersionedEnvelope<Track>.self, from: data)
        XCTAssertEqual(env.schemaVersion, FavoritesManager.schemaVersion)
        XCTAssertEqual(env.items.map(\.id), ["old1", "new1"])
    }

    func testCorruptFileIsQuarantinedAndManagerStartsEmpty() {
        let garbage = InMemoryKeyValueStore(seed: Data("not json at all }{".utf8))
        let manager = FavoritesManager(store: garbage)
        XCTAssertTrue(manager.tracks.isEmpty, "a corrupt file must not crash; start clean")
        XCTAssertEqual(garbage.backedUpCorrupt.count, 1, "corrupt bytes are preserved for recovery")
    }

    func testDeinitPersistsPendingDebouncedSave() {
        // Regression for the deinit-flush no-op: `deinit { saveDebouncer?.flush() }`
        // ran the stored `{ [weak self] in self?.performSave() }` action, but
        // `self` is already nil during deinit, so a still-pending write was
        // silently dropped. deinit must persist it synchronously instead.
        let store = InMemoryKeyValueStore()
        var manager: FavoritesManager? = FavoritesManager(store: store)
        manager?.add(makeTrack(id: "1", title: "Alpha"))
        XCTAssertEqual(store.saveCount, 0, "the save is debounced; nothing written yet")

        manager = nil  // deallocate before the 0.5s debounce fires

        XCTAssertGreaterThan(store.saveCount, 0, "deinit must persist the pending write")
        let reloaded = FavoritesManager(store: store)
        XCTAssertEqual(reloaded.tracks.map(\.id), ["1"], "the pending favorite survived deinit")
    }

    // MARK: - Helpers

    private func makeTrack(id: String, title: String) -> Track {
        Track(id: id, title: title, artist: "Test", thumbnailURL: nil)
    }
}
