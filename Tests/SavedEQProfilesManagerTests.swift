import XCTest
@testable import Aria___Music_Browser

final class SavedEQProfilesManagerTests: XCTestCase {

    private func preset(_ name: String, gain: Float = 3) -> ParametricEQPreset {
        ParametricEQPreset(
            name: name, preamp: -6,
            bands: [ParametricBand(type: .peak, frequency: 1000, gain: gain, q: 1)]
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func test_remember_addsProfile() {
        let manager = SavedEQProfilesManager()
        manager.remember(preset("Sennheiser HD 650"))
        XCTAssertEqual(manager.profiles.map(\.name), ["Sennheiser HD 650"])
    }

    func test_remember_sameProfileTwice_doesNotDuplicate() {
        let manager = SavedEQProfilesManager()
        let hd650 = preset("Sennheiser HD 650")
        manager.remember(hd650, now: t0)
        manager.remember(hd650, now: t0.addingTimeInterval(60))
        XCTAssertEqual(manager.profiles.count, 1, "re-applying the same curve refreshes, not duplicates")
        XCTAssertEqual(manager.profiles[0].lastUsedAt, t0.addingTimeInterval(60))
    }

    func test_sameHeadphoneDifferentMeasurement_isASeparateProfile() {
        // Same name, different bands (e.g. oratory1990 vs crinacle) — these are
        // genuinely different curves and must both be keepable.
        let manager = SavedEQProfilesManager()
        manager.remember(preset("Sennheiser HD 650", gain: 3))
        manager.remember(preset("Sennheiser HD 650", gain: 5))
        XCTAssertEqual(manager.profiles.count, 2)
    }

    func test_profiles_areMostRecentlyUsedFirst() {
        let manager = SavedEQProfilesManager()
        manager.remember(preset("A"), now: t0)
        manager.remember(preset("B"), now: t0.addingTimeInterval(10))
        XCTAssertEqual(manager.profiles.map(\.name), ["B", "A"])

        // Switching back to A floats it to the top.
        manager.remember(preset("A"), now: t0.addingTimeInterval(20))
        XCTAssertEqual(manager.profiles.map(\.name), ["A", "B"])
    }

    func test_delete_removesOnlyThatProfile() {
        let manager = SavedEQProfilesManager()
        manager.remember(preset("A"))
        manager.remember(preset("B"))
        let toDelete = manager.profiles.first { $0.name == "A" }!
        manager.delete(toDelete)
        XCTAssertEqual(manager.profiles.map(\.name), ["B"])
    }

    func test_persistence_roundTripsAndKeepsOrder() {
        let store = InMemoryKeyValueStore()
        let manager = SavedEQProfilesManager(store: store)
        manager.remember(preset("Older"), now: t0)
        manager.remember(preset("Newer"), now: t0.addingTimeInterval(60))
        manager.flushPendingWrites()

        let revived = SavedEQProfilesManager(store: store)
        XCTAssertEqual(revived.profiles.map(\.name), ["Newer", "Older"])
        XCTAssertEqual(revived.profiles[0].preset, preset("Newer"),
                       "the full curve must survive, not just the name")
    }

    func test_freshStore_isEmpty() {
        XCTAssertTrue(SavedEQProfilesManager(store: InMemoryKeyValueStore()).profiles.isEmpty)
    }
}
