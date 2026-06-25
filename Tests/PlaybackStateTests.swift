import XCTest
@testable import Aria___Music_Browser

final class PlaybackStateTests: XCTestCase {

    func test_preparingDownload_carriesProgress() {
        let s = PlayerManager.PlaybackState.preparingDownload(progress: 0.42)
        if case .preparingDownload(let p) = s {
            XCTAssertEqual(p, 0.42, accuracy: 0.0001)
        } else {
            XCTFail("expected .preparingDownload, got \(s)")
        }
    }

    func test_preparingDownload_equalityByProgress() {
        XCTAssertEqual(
            PlayerManager.PlaybackState.preparingDownload(progress: 0.5),
            PlayerManager.PlaybackState.preparingDownload(progress: 0.5)
        )
        XCTAssertNotEqual(
            PlayerManager.PlaybackState.preparingDownload(progress: 0.5),
            PlayerManager.PlaybackState.preparingDownload(progress: 0.7)
        )
    }

    func test_preparingDownload_notEqualToOtherStates() {
        let s = PlayerManager.PlaybackState.preparingDownload(progress: 0)
        XCTAssertNotEqual(s, .idle)
        XCTAssertNotEqual(s, .loading)
        XCTAssertNotEqual(s, .playing)
        XCTAssertNotEqual(s, .paused)
        XCTAssertNotEqual(s, .ended)
    }
}
