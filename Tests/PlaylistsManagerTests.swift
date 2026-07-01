import XCTest
@testable import Aria___Music_Browser

final class PlaylistsManagerTests: XCTestCase {
    private var manager: PlaylistsManager!
    private var store: InMemoryKeyValueStore!

    override func setUp() {
        super.setUp()
        // Inject an in-memory store so each test is hermetic. (Previously these
        // used the default file-backed store; they only stayed isolated because
        // the deinit flush was a silent no-op — once deinit correctly persists,
        // a shared on-disk playlists.json would bleed state between tests.)
        store = InMemoryKeyValueStore()
        manager = PlaylistsManager(store: store)
    }

    override func tearDown() {
        manager = nil
        store = nil
        super.tearDown()
    }

    func testCreateReturnsPlaylist() {
        let playlist = manager.create(name: "Chill")
        XCTAssertEqual(playlist.name, "Chill")
        XCTAssertTrue(playlist.tracks.isEmpty)
        XCTAssertEqual(manager.playlists.count, 1)
    }

    func testRename() {
        let playlist = manager.create(name: "Old")
        manager.rename(playlist, to: "New")
        XCTAssertEqual(manager.playlists.first?.name, "New")
    }

    func testAddTrackIsIdempotent() {
        let playlist = manager.create(name: "P")
        let track = makeTrack(id: "1", title: "T")
        manager.addTrack(track, to: playlist)
        manager.addTrack(track, to: playlist)
        XCTAssertEqual(manager.playlists.first?.tracks.count, 1)
    }

    func testRemoveTrack() {
        let playlist = manager.create(name: "P")
        let track = makeTrack(id: "1", title: "T")
        manager.addTrack(track, to: playlist)
        manager.removeTrack(track, from: playlist)
        XCTAssertEqual(manager.playlists.first?.tracks.count, 0)
    }

    func testMarkPlayedUpdatesTimestamp() {
        let playlist = manager.create(name: "P")
        XCTAssertNil(playlist.lastPlayedAt)
        manager.markPlayed(playlist)
        XCTAssertNotNil(manager.playlists.first?.lastPlayedAt)
    }

    func testDelete() {
        let playlist = manager.create(name: "P")
        manager.delete(playlist)
        XCTAssertTrue(manager.playlists.isEmpty)
    }

    func testSortedPlaylistsRespectsOrder() {
        manager.deleteAll()
        manager.sortOrder = .alphabetical
        manager.create(name: "Charlie")
        manager.create(name: "Alpha")
        manager.create(name: "Bravo")
        XCTAssertEqual(manager.sortedPlaylists.map(\.name), ["Alpha", "Bravo", "Charlie"])
    }

    func testRecentlyPlayedPlaylistsExcludesUnplayed() {
        manager.deleteAll()
        let a = manager.create(name: "A")
        let _ = manager.create(name: "B")
        manager.markPlayed(a)
        XCTAssertEqual(manager.recentlyPlayedPlaylists.map(\.name), ["A"])
    }

    func testCreateWithTracksPreservesOrderAndDedupes() {
        let tracks = [
            makeTrack(id: "1", title: "A"),
            makeTrack(id: "2", title: "B"),
            makeTrack(id: "1", title: "A"),
        ]
        let p = manager.create(name: "Saved Queue", tracks: tracks)
        XCTAssertEqual(p.tracks.map(\.id), ["1", "2"])
        XCTAssertEqual(manager.playlists.first?.tracks.count, 2)
    }

    func testMoveTrackReorders() {
        let p = manager.create(name: "P")
        manager.addTrack(makeTrack(id: "1", title: "A"), to: p)
        manager.addTrack(makeTrack(id: "2", title: "B"), to: p)
        manager.addTrack(makeTrack(id: "3", title: "C"), to: p)
        manager.moveTrack(in: p, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(manager.playlists.first?.tracks.map(\.id), ["2", "3", "1"])
    }

    func testDeinitPersistsPendingDebouncedSave() {
        // Regression for the deinit-flush no-op (see FavoritesManager): a still
        // -pending debounced write must be persisted synchronously in deinit.
        let store = InMemoryKeyValueStore()
        var manager: PlaylistsManager? = PlaylistsManager(store: store)
        _ = manager?.create(name: "Chill")
        XCTAssertEqual(store.saveCount, 0, "the save is debounced; nothing written yet")

        manager = nil  // deallocate before the 0.5s debounce fires

        XCTAssertGreaterThan(store.saveCount, 0, "deinit must persist the pending write")
        let reloaded = PlaylistsManager(store: store)
        XCTAssertEqual(reloaded.playlists.map(\.name), ["Chill"], "the pending playlist survived deinit")
    }

    // MARK: - Helpers

    private func makeTrack(id: String, title: String) -> Track {
        Track(id: id, title: title, artist: "T", thumbnailURL: nil)
    }
}
