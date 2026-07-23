import XCTest
@testable import Aria___Music_Browser

/// Entitlement-state coverage for `ProStore`. All tests construct with
/// `autostart: false` so no StoreKit calls run, and drive state through
/// `applyEntitlement` — the same funnel verified transactions use.
///
/// Each test uses its own UserDefaults suite and wipes it in tearDown so
/// entitlement state can't leak between tests (or into other suites).
final class ProStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "pro-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_freshInstall_isNotPro() {
        let store = ProStore(defaults: defaults, autostart: false)
        XCTAssertFalse(store.isPro)
    }

    func test_cachedEntitlement_unlocksAtInit() {
        defaults.set(true, forKey: ProStore.cacheKey)
        let store = ProStore(defaults: defaults, autostart: false)
        XCTAssertTrue(store.isPro, "a cached unlock must apply instantly at launch, before any StoreKit round-trip")
    }

    func test_applyEntitlement_grantsAndPersists() {
        let store = ProStore(defaults: defaults, autostart: false)
        store.applyEntitlement(true)
        XCTAssertTrue(store.isPro)
        XCTAssertTrue(defaults.bool(forKey: ProStore.cacheKey), "grant must persist for the next launch")
    }

    func test_applyEntitlement_revokesAndPersists() {
        defaults.set(true, forKey: ProStore.cacheKey)
        let store = ProStore(defaults: defaults, autostart: false)
        XCTAssertTrue(store.isPro)

        // A refunded transaction arrives via the updates listener with
        // revocationDate set → applyEntitlement(false).
        store.applyEntitlement(false)
        XCTAssertFalse(store.isPro)
        XCTAssertFalse(defaults.bool(forKey: ProStore.cacheKey))
    }

    func test_entitlementChange_publishesObjectWillChange() {
        let store = ProStore(defaults: defaults, autostart: false)
        let exp = expectation(description: "objectWillChange fires on unlock")
        let cancellable = store.objectWillChange.sink { exp.fulfill() }
        store.applyEntitlement(true)
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()
    }

    func test_productID_isStable() {
        // The product id is the contract with App Store Connect / Aria.storekit.
        // Changing it orphans every existing purchase — this test makes that a
        // deliberate act, not an accident.
        XCTAssertEqual(ProStore.proProductID, "com.chaitea321.aria.pro")
    }
}
