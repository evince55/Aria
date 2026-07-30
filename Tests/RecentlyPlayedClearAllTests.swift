import XCTest
@testable import Aria___Music_Browser

@MainActor
final class RecentlyPlayedClearAllTests: XCTestCase {

    private func makeTrack(id: String) -> Track {
        Track(id: id, title: "Title \(id)", artist: "Artist", thumbnailURL: nil)
    }

    func test_clearAll_emptiesBothListsAndPersists() {
        let playedStore = InMemoryKeyValueStore()
        let addedStore = InMemoryKeyValueStore()
        let manager = RecentlyPlayedManager(playedStore: playedStore, addedStore: addedStore)
        manager.trackPlayed(makeTrack(id: "a"))
        manager.trackPlayed(makeTrack(id: "b"))
        manager.trackAdded(makeTrack(id: "c"))

        manager.clearAll()

        XCTAssertTrue(manager.recentlyPlayed.isEmpty)
        XCTAssertTrue(manager.recentlyAdded.isEmpty)

        // The empty state must be what a relaunch loads (debounced save → flush).
        manager.flushPendingWrites()
        let reloaded = RecentlyPlayedManager(playedStore: playedStore, addedStore: addedStore)
        XCTAssertTrue(reloaded.recentlyPlayed.isEmpty)
        XCTAssertTrue(reloaded.recentlyAdded.isEmpty)
    }

    // MARK: - Play stats (feeds the library-search affinity flags)

    func test_trackPlayed_recordsCountAndLastPlayed_persisted() {
        let statsStore = InMemoryKeyValueStore()
        let manager = RecentlyPlayedManager(
            playedStore: InMemoryKeyValueStore(),
            addedStore: InMemoryKeyValueStore(),
            statsStore: statsStore)
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)

        manager.trackPlayed(makeTrack(id: "a"), at: first)
        manager.trackPlayed(makeTrack(id: "a"), at: second)
        manager.trackPlayed(makeTrack(id: "b"), at: second)

        XCTAssertEqual(manager.playStats["a"]?.playCount, 2)
        XCTAssertEqual(manager.playStats["a"]?.lastPlayedAt, second)
        XCTAssertEqual(manager.playStats["b"]?.playCount, 1)

        manager.flushPendingWrites()
        let reloaded = RecentlyPlayedManager(
            playedStore: InMemoryKeyValueStore(),
            addedStore: InMemoryKeyValueStore(),
            statsStore: statsStore)
        XCTAssertEqual(reloaded.playStats["a"]?.playCount, 2)
    }

    func test_clearAll_alsoClearsPlayStats() {
        let statsStore = InMemoryKeyValueStore()
        let manager = RecentlyPlayedManager(
            playedStore: InMemoryKeyValueStore(),
            addedStore: InMemoryKeyValueStore(),
            statsStore: statsStore)
        manager.trackPlayed(makeTrack(id: "a"))

        manager.clearAll()
        manager.flushPendingWrites()

        XCTAssertTrue(manager.playStats.isEmpty)
        let reloaded = RecentlyPlayedManager(
            playedStore: InMemoryKeyValueStore(),
            addedStore: InMemoryKeyValueStore(),
            statsStore: statsStore)
        XCTAssertTrue(reloaded.playStats.isEmpty)
    }
}
