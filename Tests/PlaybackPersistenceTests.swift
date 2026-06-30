import XCTest
@testable import Aria___Music_Browser

/// Covers persisting + restoring the playback session (now-playing track,
/// queue, position) across launches.
@MainActor
final class PlaybackPersistenceTests: XCTestCase {

    private func makeTrack(_ id: String) -> Track {
        Track(id: id, title: "T\(id)", artist: "A", thumbnailURL: nil)
    }

    func test_savesTrackAndQueue() throws {
        let store = InMemoryKeyValueStore()
        let player = PlayerManager(urlSession: MockURLSession(), playbackStore: store)

        player.currentTrack = makeTrack("now")
        player.queue = [makeTrack("a"), makeTrack("b")]
        player.duration = 200
        player.flushPendingWrites()

        let data = try XCTUnwrap(store.load())
        let snapshot = try JSONDecoder().decode(PersistedPlayback.self, from: data)
        XCTAssertEqual(snapshot.currentTrack?.id, "now")
        XCTAssertEqual(snapshot.queue.map(\.id), ["a", "b"])
        XCTAssertEqual(snapshot.schemaVersion, PlayerManager.playbackSchemaVersion)
    }

    func test_restoresIntoPausedState() throws {
        let snapshot = PersistedPlayback(
            schemaVersion: PlayerManager.playbackSchemaVersion,
            currentTrack: makeTrack("resume"),
            queue: [makeTrack("next1"), makeTrack("next2")],
            positionSeconds: 42,
            durationSeconds: 180
        )
        let store = InMemoryKeyValueStore(seed: try SchemaStore.encodeValue(snapshot))

        let player = PlayerManager(urlSession: MockURLSession(), playbackStore: store)

        XCTAssertEqual(player.currentTrack?.id, "resume")
        XCTAssertEqual(player.queue.map(\.id), ["next1", "next2"])
        XCTAssertEqual(player.currentTime, 42)
        XCTAssertEqual(player.duration, 180)
        XCTAssertFalse(player.isPlaying, "restore must never auto-resume audio")
        XCTAssertEqual(player.playbackState, .paused)
    }

    func test_emptySnapshotRestoresNothing() throws {
        let snapshot = PersistedPlayback(
            schemaVersion: PlayerManager.playbackSchemaVersion,
            currentTrack: nil, queue: [], positionSeconds: 0, durationSeconds: 0
        )
        let store = InMemoryKeyValueStore(seed: try SchemaStore.encodeValue(snapshot))
        let player = PlayerManager(urlSession: MockURLSession(), playbackStore: store)
        XCTAssertNil(player.currentTrack)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(player.playbackState, .idle)
    }

    func test_corruptPlaybackStateStartsCleanAndQuarantines() {
        let store = InMemoryKeyValueStore(seed: Data("garbage }{".utf8))
        let player = PlayerManager(urlSession: MockURLSession(), playbackStore: store)
        XCTAssertNil(player.currentTrack)
        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertEqual(store.backedUpCorrupt.count, 1)
    }

    func test_freshPlayerWithNoStateDoesNotWriteOnRestore() {
        let store = InMemoryKeyValueStore()
        _ = PlayerManager(urlSession: MockURLSession(), playbackStore: store)
        // Restoring an empty store must not trigger a save (nothing to persist).
        XCTAssertEqual(store.saveCount, 0)
    }
}
