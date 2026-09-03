import XCTest
@testable import Aria___Music_Browser

/// A brand-new install must land somewhere useful. Favorites is empty on
/// first run by definition; Library has the Import call-to-action.
final class DefaultStartTabTests: XCTestCase {
    private let key = "default_start_tab"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func test_libraryIsAnOption_andPersistsByRawValue() {
        XCTAssertEqual(DefaultStartTab(rawValue: "Library"), .library)
        XCTAssertTrue(DefaultStartTab.allCases.contains(.library),
                      "the More → Default Start Page picker iterates allCases")
    }

    func test_freshInstall_defaultsToLibrary() {
        XCTAssertEqual(SettingsManager().defaultStartTab, .library)
    }

    func test_persistedChoiceStillWins() {
        UserDefaults.standard.set("Favorites", forKey: key)
        XCTAssertEqual(SettingsManager().defaultStartTab, .favorites,
                       "changing the default must not override a user's saved choice")
    }
}
