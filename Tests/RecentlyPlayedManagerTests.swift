import XCTest
@testable import Aria___Music_Browser

final class RecentlyPlayedManagerTests: XCTestCase {

    func testDeinitPersistsBothPendingDebouncedSaves() {
        // Regression for the deinit-flush no-op (see FavoritesManager): both the
        // "played" and "added" debouncers capture [weak self], already nil during
        // deinit, so flush() would drop pending writes. deinit must persist both
        // synchronously.
        let playedStore = InMemoryKeyValueStore()
        let addedStore = InMemoryKeyValueStore()
        var manager: RecentlyPlayedManager? = RecentlyPlayedManager(
            playedStore: playedStore, addedStore: addedStore
        )
        manager?.trackPlayed(makeTrack(id: "1", title: "Alpha"))
        manager?.trackAdded(makeTrack(id: "2", title: "Beta"))
        XCTAssertEqual(playedStore.saveCount, 0, "played save is debounced; nothing written yet")
        XCTAssertEqual(addedStore.saveCount, 0, "added save is debounced; nothing written yet")

        manager = nil  // deallocate before the 0.5s debounce fires

        XCTAssertGreaterThan(playedStore.saveCount, 0, "deinit must persist the pending played write")
        XCTAssertGreaterThan(addedStore.saveCount, 0, "deinit must persist the pending added write")

        let reloaded = RecentlyPlayedManager(playedStore: playedStore, addedStore: addedStore)
        XCTAssertEqual(reloaded.recentlyPlayed.map(\.id), ["1"], "the pending played track survived deinit")
        XCTAssertEqual(reloaded.recentlyAdded.map(\.id), ["2"], "the pending added track survived deinit")
    }

    // MARK: - Helpers

    private func makeTrack(id: String, title: String) -> Track {
        Track(id: id, title: title, artist: "Test", thumbnailURL: nil)
    }
}
