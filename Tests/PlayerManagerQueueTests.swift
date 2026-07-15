import XCTest
@testable import Aria___Music_Browser

/// Queue-interaction behaviors: tap-to-jump (`playFromQueue`) and
/// `playNext` front-insertion. Complements the queue basics in
/// `PlayerManagerTests`.
@MainActor
final class PlayerManagerQueueTests: XCTestCase {

    private var mockSession: MockURLSession!
    private var player: PlayerManager!

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        player = PlayerManager(urlSession: mockSession)
        mockSession.dataTaskHandler = { _, completion in
            completion(Data(), nil, nil)
        }
    }

    override func tearDown() {
        player = nil
        mockSession = nil
        super.tearDown()
    }

    private func makeTrack(id: String) -> Track {
        Track(id: id, title: "Title \(id)", artist: "T", thumbnailURL: nil)
    }

    private func seedQueue(_ ids: [String]) {
        for id in ids { player.addToQueue(makeTrack(id: id)) }
    }

    // MARK: - playFromQueue(at:)

    func test_playFromQueue_middleIndexPlaysThatTrackAndDropsSkipped() {
        seedQueue(["a", "b", "c", "d"])
        player.playFromQueue(at: 2)
        XCTAssertEqual(player.currentTrack?.id, "c")
        XCTAssertEqual(player.queue.map(\.id), ["d"], "skipped rows are dropped, later rows stay")
    }

    func test_playFromQueue_indexZeroBehavesLikeAdvance() {
        seedQueue(["a", "b"])
        player.playFromQueue(at: 0)
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertEqual(player.queue.map(\.id), ["b"])
    }

    func test_playFromQueue_lastIndexEmptiesQueue() {
        seedQueue(["a", "b", "c"])
        player.playFromQueue(at: 2)
        XCTAssertEqual(player.currentTrack?.id, "c")
        XCTAssertTrue(player.queue.isEmpty)
    }

    func test_playFromQueue_outOfBoundsIsNoOp() {
        seedQueue(["a"])
        player.playFromQueue(at: 5)
        XCTAssertNil(player.currentTrack)
        XCTAssertEqual(player.queue.map(\.id), ["a"])

        player.playFromQueue(at: -1)
        XCTAssertEqual(player.queue.map(\.id), ["a"])
    }

    /// Skipped rows were never played, so Previous must not step "back" into
    /// them — after a jump, Previous returns to the track that was actually
    /// playing before the jump.
    func test_playFromQueue_skippedTracksDoNotEnterHistory() {
        seedQueue(["a", "b", "c"])
        player.playFromQueue(at: 0)          // now playing "a"
        player.playFromQueue(at: 1)          // skip "b", play "c"
        XCTAssertEqual(player.currentTrack?.id, "c")
        player.previousTrack()
        XCTAssertEqual(player.currentTrack?.id, "a",
                       "previous should return to the last *played* track, not a skipped one")
    }

    // MARK: - playNext(_:)

    func test_playNext_insertsAtFront() {
        seedQueue(["a", "b"])
        player.playNext(makeTrack(id: "x"))
        XCTAssertEqual(player.queue.map(\.id), ["x", "a", "b"])
    }

    func test_playNext_movesExistingCopyToFrontWithoutDuplicating() {
        seedQueue(["a", "b", "c"])
        player.playNext(makeTrack(id: "b"))
        XCTAssertEqual(player.queue.map(\.id), ["b", "a", "c"])
    }

    func test_playNext_worksOnEmptyQueue() {
        player.playNext(makeTrack(id: "x"))
        XCTAssertEqual(player.queue.map(\.id), ["x"])
    }
}
