import XCTest
import Combine
@testable import Aria___Music_Browser

// MARK: - Test doubles

/// Records every URL requested and lets the test decide what to return.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    struct RecordedRequest {
        let url: URL
        let completionHandler: (Data?, URLResponse?, Error?) -> Void
    }

    private(set) var recordedRequests: [RecordedRequest] = []

    /// Closure invoked for each `dataTask(with:completionHandler:)` call.
    /// Test sets this to control the response.
    var dataTaskHandler: ((URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void)?

    @discardableResult
    func dataTask(
        with url: URL,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTaskProtocol {
        recordedRequests.append(RecordedRequest(url: url, completionHandler: completionHandler))
        if let handler = dataTaskHandler {
            handler(url, completionHandler)
        }
        return MockURLSessionDataTask()
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }
}

final class MockURLSessionDataTask: URLSessionDataTaskProtocol, @unchecked Sendable {
    private(set) var didResume = false
    private(set) var didCancel = false
    func resume() { didResume = true }
    func cancel() { didCancel = true }
}

// MARK: - PlayerManager tests

@MainActor
final class PlayerManagerTests: XCTestCase {

    private var mockSession: MockURLSession!
    private var player: PlayerManager!

    override func setUp() {
        super.setUp()
        mockSession = MockURLSession()
        player = PlayerManager(urlSession: mockSession)
    }

    override func tearDown() {
        player = nil
        mockSession = nil
        super.tearDown()
    }

    // MARK: - Queue management (4)

    func test_QueueAddAppendsTrack() {
        let track = makeTrack(id: "1", title: "A")
        XCTAssertTrue(player.queue.isEmpty)
        player.addToQueue(track)
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertEqual(player.queue.first?.id, "1")
    }

    func test_QueueAddDoesNotDedupe() {
        // addToQueue just appends; dedup is the caller's responsibility.
        let track = makeTrack(id: "1", title: "A")
        player.addToQueue(track)
        player.addToQueue(track)
        XCTAssertEqual(player.queue.count, 2)
    }

    func test_QueueRemoveAtIndex() {
        player.addToQueue(makeTrack(id: "1", title: "A"))
        player.addToQueue(makeTrack(id: "2", title: "B"))
        player.addToQueue(makeTrack(id: "3", title: "C"))
        player.removeFromQueue(at: 1)
        XCTAssertEqual(player.queue.map(\.id), ["1", "3"])
    }

    func test_QueueClearRemovesAll() {
        player.addToQueue(makeTrack(id: "1", title: "A"))
        player.addToQueue(makeTrack(id: "2", title: "B"))
        player.clearQueue()
        XCTAssertTrue(player.queue.isEmpty)
    }

    // MARK: - Play generation (3)

    func test_PlayBumpsGeneration() {
        let initial = player.playGeneration
        player.play(makeTrack(id: "1", title: "A"))
        XCTAssertEqual(player.playGeneration, initial + 1)
    }

    func test_PlayResetsState() {
        player.currentTrack = makeTrack(id: "0", title: "X")
        player.currentTime = 100
        player.duration = 200
        mockSession.dataTaskHandler = { _, completion in
            completion(Data(), nil, nil)
        }
        player.play(makeTrack(id: "1", title: "A"))
        XCTAssertEqual(player.currentTrack?.id, "1")
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, 0)
        XCTAssertTrue(player.isPlaying)
    }

    func test_PlayGenerationMonotonic() {
        mockSession.dataTaskHandler = { _, completion in
            completion(Data(), nil, nil)
        }
        let g1 = player.playGeneration
        player.play(makeTrack(id: "1", title: "A"))
        let g2 = player.playGeneration
        player.play(makeTrack(id: "2", title: "B"))
        let g3 = player.playGeneration
        XCTAssertEqual(g2, g1 + 1)
        XCTAssertEqual(g3, g2 + 1)
    }

    // MARK: - Repeat / shuffle (3)

    func test_ToggleShuffle() {
        XCTAssertFalse(player.isShuffled)
        player.toggleShuffle()
        XCTAssertTrue(player.isShuffled)
        player.toggleShuffle()
        XCTAssertFalse(player.isShuffled)
    }

    func test_CycleRepeatModeAdvances() {
        XCTAssertEqual(player.repeatMode, .off)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .off)
    }

    func test_PlayNextInQueueAdvancesQueue() {
        player.addToQueue(makeTrack(id: "a", title: "A"))
        player.addToQueue(makeTrack(id: "b", title: "B"))
        mockSession.dataTaskHandler = { _, completion in
            completion(Data(), nil, nil)
        }
        player.playNextInQueue()
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertEqual(player.queue.count, 1)
        XCTAssertEqual(player.queue.first?.id, "b")
    }

    // MARK: - EQ transitions (3)

    func test_FlatPresetLeavesEqDisabled() {
        let flat = Array(repeating: Float(0), count: 10)
        player.applyEQPreset(flat)
        XCTAssertFalse(player.eq.isEnabled)
    }

    func test_NonZeroPresetEnablesEq() {
        let preset: [Float] = [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]
        player.applyEQPreset(preset)
        XCTAssertTrue(player.eq.isEnabled)
    }

    func test_ResetEqDisablesAndClearsBands() {
        player.applyEQPreset([3, 2, 1, 0, 0, 0, 0, 1, 2, 3])
        XCTAssertTrue(player.eq.isEnabled)
        player.resetEQ()
        XCTAssertFalse(player.eq.isEnabled)
        XCTAssertTrue(player.eq.bands.allSatisfy { $0 == 0 })
    }

    // MARK: - Network (3)

    func test_FetchStreamURLRequestsBackend() {
        let json = #"{"url":"/api/stream/abc.m4a","cached":false}"#
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        mockSession.dataTaskHandler = { url, completion in
            completion(data, response, nil)
        }
        player.play(makeTrack(id: "abc", title: "A"))
        let exp = expectation(description: "url requested")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(self.mockSession.recordedRequests.contains(where: {
                $0.url.absoluteString.contains("video_id=abc")
            }))
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func test_FetchStreamURLHandlesNetworkError() {
        mockSession.dataTaskHandler = { _, completion in
            completion(nil, nil, URLError(.notConnectedToInternet))
        }
        player.play(makeTrack(id: "abc", title: "A"))
        let exp = expectation(description: "idle after error")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.player.playbackState, .idle)
            XCTAssertFalse(self.player.isPlaying)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    func test_FetchStreamURLHandlesMalformedJSON() {
        mockSession.dataTaskHandler = { _, completion in
            completion(Data("not json".utf8), nil, nil)
        }
        player.play(makeTrack(id: "abc", title: "A"))
        let exp = expectation(description: "idle after parse error")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(self.player.playbackState, .idle)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Engine / cache (3)

    func test_EQEnabledFlagToggles() {
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(player.eq.isEnabled)
        player.resetEQ()
        XCTAssertFalse(player.eq.isEnabled)
    }

    func test_ClearEQCacheDoesNotCrash() {
        player.clearEQCache()
    }

    func test_PlayWithEQEnabledRecordsRequest() {
        // With EQ on, the engine path requires a download. The first play()
        // should record at least one network request.
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        mockSession.dataTaskHandler = { url, completion in
            if url.absoluteString.contains("/api/play") {
                completion(
                    Data(#"{"url":"/api/stream/abc.m4a","cached":false}"#.utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    nil
                )
            } else {
                completion(Data(),
                            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            nil)
            }
        }
        player.play(makeTrack(id: "abc", title: "A"))
        let exp = expectation(description: "first play records request")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertGreaterThan(self.mockSession.recordedRequests.count, 0)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
    }

    // MARK: - Lifecycle (2)

    func test_BackendURLIsNonEmpty() {
        XCTAssertFalse(PlayerManager.backendURL.isEmpty)
    }

    func test_PlaybackStateIdleAtInit() {
        XCTAssertEqual(player.playbackState, .idle)
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - Helpers

    private func makeTrack(id: String, title: String) -> Track {
        Track(id: id, title: title, artist: "T", thumbnailURL: nil)
    }
}
