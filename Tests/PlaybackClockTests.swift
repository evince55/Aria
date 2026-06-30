import XCTest
@testable import Aria___Music_Browser

/// Covers the `PlaybackClock` split (position/duration forwarders) and the
/// stall-recovery entry points on `PlayerManager`. Reuses `MockURLSession`
/// from `PlayerManagerTests` (same test target).
@MainActor
final class PlaybackClockTests: XCTestCase {

    private var player: PlayerManager!

    override func setUp() {
        super.setUp()
        player = PlayerManager(urlSession: MockURLSession())
    }

    override func tearDown() {
        player = nil
        super.tearDown()
    }

    // MARK: - Clock forwarding

    func test_currentTimeForwardsToClock() {
        player.currentTime = 42
        XCTAssertEqual(player.clock.currentTime, 42)
        player.clock.currentTime = 7
        XCTAssertEqual(player.currentTime, 7)
    }

    func test_durationForwardsToClock() {
        player.duration = 200
        XCTAssertEqual(player.clock.duration, 200)
        player.clock.duration = 99
        XCTAssertEqual(player.duration, 99)
    }

    func test_seekUpdatesClock() {
        player.seek(to: 30)
        XCTAssertEqual(player.clock.currentTime, 30)
    }

    // MARK: - Stall recovery

    func test_handleStall_setsSeekTargetToCurrentPositionAndReloads() {
        // currentVideoID is set synchronously by play(); no await so the
        // async resolve/AVPlayer callbacks don't run and the assertions are
        // deterministic.
        player.play(makeTrack(id: "vid1"))
        player.clock.currentTime = 55
        let genBefore = player.playGeneration

        player.handleStall()

        XCTAssertEqual(player.seekTarget, 55, "stall recovery should resume at the current position")
        XCTAssertEqual(player.playbackState, .loading)
        XCTAssertEqual(player.playGeneration, genBefore + 1)
    }

    func test_handleStall_capsAtMaxRetries() {
        player.play(makeTrack(id: "vid1"))
        let gen0 = player.playGeneration

        player.handleStall()
        player.handleStall()
        player.handleStall()
        let gen3 = player.playGeneration
        player.handleStall()  // 4th — should be capped

        XCTAssertEqual(gen3, gen0 + 3, "first three stalls each trigger a re-resolve")
        XCTAssertEqual(player.playGeneration, gen3, "the fourth stall is a no-op")
    }

    func test_notePlaybackRecovered_clearsRebufferingAndResetsRetries() {
        player.play(makeTrack(id: "vid1"))
        player.isRebuffering = true
        player.handleStall()
        player.handleStall()

        player.notePlaybackRecovered()
        XCTAssertFalse(player.isRebuffering)

        // After recovery the stall budget is replenished: three more re-resolves
        // are allowed.
        let gen = player.playGeneration
        player.handleStall()
        player.handleStall()
        player.handleStall()
        XCTAssertEqual(player.playGeneration, gen + 3)
    }

    // MARK: - Helpers

    private func makeTrack(id: String) -> Track {
        Track(id: id, title: "T", artist: "A", thumbnailURL: nil)
    }
}
