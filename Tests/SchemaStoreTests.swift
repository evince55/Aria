import XCTest
@testable import Aria___Music_Browser

/// Covers the schema-versioning + migration + corruption-quarantine layer that
/// wraps every JSON store. The contract: never silently lose data — migrate a
/// legacy bare-array file in place, and move undecodable bytes aside instead of
/// dropping the collection.
final class SchemaStoreTests: XCTestCase {

    private func makeTrack(_ id: String) -> Track {
        Track(id: id, title: "T\(id)", artist: "A", thumbnailURL: nil)
    }

    // MARK: - Array payloads

    func testEnvelopeRoundTrips() {
        let store = InMemoryKeyValueStore()
        let items = [makeTrack("1"), makeTrack("2")]
        let data = try! SchemaStore.encode(items, schemaVersion: 1)
        try! store.save(data)

        let loaded = SchemaStore.loadItems(Track.self, from: store, currentVersion: 1)
        XCTAssertEqual(loaded?.map(\.id), ["1", "2"])
    }

    func testEncodeWritesVersionedEnvelopeNotBareArray() throws {
        let data = try SchemaStore.encode([makeTrack("1")], schemaVersion: 1)
        // The persisted bytes must be the {schemaVersion, items} object, so a
        // future version can recognise and migrate it.
        let env = try JSONDecoder().decode(VersionedEnvelope<Track>.self, from: data)
        XCTAssertEqual(env.schemaVersion, 1)
        XCTAssertEqual(env.items.map(\.id), ["1"])
        // It must NOT decode as a bare array.
        XCTAssertThrowsError(try JSONDecoder().decode([Track].self, from: data))
    }

    func testMigratesLegacyBareArray() {
        // Seed the store with the OLD on-disk format: a bare top-level array.
        let legacy = try! JSONEncoder().encode([makeTrack("a"), makeTrack("b")])
        let store = InMemoryKeyValueStore(seed: legacy)

        let loaded = SchemaStore.loadItems(Track.self, from: store, currentVersion: 1)
        XCTAssertEqual(loaded?.map(\.id), ["a", "b"], "legacy bare-array file must still load")
        XCTAssertTrue(store.backedUpCorrupt.isEmpty, "valid legacy data must not be treated as corrupt")
    }

    func testCorruptDataIsQuarantinedNotDropped() {
        let garbage = Data("{ this is not valid json ][".utf8)
        let store = InMemoryKeyValueStore(seed: garbage)

        let loaded = SchemaStore.loadItems(Track.self, from: store, currentVersion: 1)
        XCTAssertNil(loaded, "undecodable data yields nil so the caller keeps its default")
        XCTAssertEqual(store.backedUpCorrupt.count, 1)
        XCTAssertEqual(store.backedUpCorrupt.first, garbage, "the original bytes must be preserved for recovery")
    }

    func testEmptyStoreReturnsNil() {
        let store = InMemoryKeyValueStore()
        XCTAssertNil(SchemaStore.loadItems(Track.self, from: store, currentVersion: 1))
        XCTAssertTrue(store.backedUpCorrupt.isEmpty, "an empty store is first-launch, not corruption")
    }

    // MARK: - Single-value payloads

    struct Sample: Codable, Equatable { var schemaVersion: Int; var value: String }

    func testValueRoundTrips() {
        let store = InMemoryKeyValueStore()
        let sample = Sample(schemaVersion: 1, value: "hi")
        try! store.save(try! SchemaStore.encodeValue(sample))
        XCTAssertEqual(SchemaStore.loadValue(Sample.self, from: store), sample)
    }

    func testValueCorruptIsQuarantined() {
        let garbage = Data("nope".utf8)
        let store = InMemoryKeyValueStore(seed: garbage)
        XCTAssertNil(SchemaStore.loadValue(Sample.self, from: store))
        XCTAssertEqual(store.backedUpCorrupt.first, garbage)
    }
}
