import XCTest
@testable import Aria___Music_Browser

@MainActor
final class SettingsManagerTests: XCTestCase {

    private let sleepKey = "sleep_timer"
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        // Preserve and clear any real persisted value so the test is hermetic.
        savedValue = UserDefaults.standard.object(forKey: sleepKey)
        UserDefaults.standard.removeObject(forKey: sleepKey)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: sleepKey)
        } else {
            UserDefaults.standard.removeObject(forKey: sleepKey)
        }
        super.tearDown()
    }

    /// The sleep timer is ephemeral: a value left over from a previous launch
    /// must NOT silently restore as an "active" selection, because nothing
    /// re-arms the timer at launch — that would show a duration with no
    /// running timer.
    func test_sleepTimer_doesNotRestorePersistedValueOnLaunch() {
        UserDefaults.standard.set(SleepTimerDuration.min30.rawValue, forKey: sleepKey)
        let settings = SettingsManager()
        XCTAssertEqual(settings.sleepTimer, .off,
                       "a persisted sleep-timer value must not restore on launch")
    }

    /// Saving settings must not write the (ephemeral) sleep timer back to
    /// persistent storage.
    func test_save_doesNotPersistSleepTimer() {
        let settings = SettingsManager()
        settings.sleepTimer = .min45
        settings.save()
        XCTAssertNil(UserDefaults.standard.object(forKey: sleepKey),
                     "sleep timer must not be persisted")
    }
}
