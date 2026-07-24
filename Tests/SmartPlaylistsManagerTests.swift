import XCTest
@testable import Aria___Music_Browser

final class SmartPlaylistsManagerTests: XCTestCase {

    private func sample(_ name: String = "Fresh FLACs") -> SmartPlaylist {
        var rules = SmartPlaylistRules()
        rules.losslessOnly = true
        rules.addedWithinDays = 30
        return SmartPlaylist(name: name, rules: rules, sort: .newestAdded, limit: 50)
    }

    func test_upsert_createsThenUpdatesInPlace() {
        let manager = SmartPlaylistsManager()
        var p = sample()
        manager.upsert(p)
        XCTAssertEqual(manager.playlists.count, 1)

        p.name = "Renamed"
        manager.upsert(p)
        XCTAssertEqual(manager.playlists.count, 1, "same id must update, not duplicate")
        XCTAssertEqual(manager.playlists.first?.name, "Renamed")
    }

    func test_delete_removesById() {
        let manager = SmartPlaylistsManager()
        let p = sample()
        manager.upsert(p)
        manager.delete(p)
        XCTAssertTrue(manager.playlists.isEmpty)
    }

    func test_persistence_roundTripsRulesExactly() {
        let store = InMemoryKeyValueStore()
        let manager = SmartPlaylistsManager(store: store)
        let p = sample()
        manager.upsert(p)
        manager.flushPendingWrites()

        let revived = SmartPlaylistsManager(store: store)
        XCTAssertEqual(revived.playlists, [p], "rules, sort, and limit must survive the round trip")
    }

    func test_freshStore_startsEmpty() {
        XCTAssertTrue(SmartPlaylistsManager(store: InMemoryKeyValueStore()).playlists.isEmpty)
    }
}
