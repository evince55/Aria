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
    /// Full `URLRequest` objects seen via `data(for:)`, so tests can assert on
    /// headers (e.g. `X-API-Key`).
    private(set) var recordedRequestObjects: [URLRequest] = []

    /// Closure invoked for each `dataTask(with:completionHandler:)` call.
    /// Test sets this to control the response.
    var dataTaskHandler: ((URL, @escaping (Data?, URLResponse?, Error?) -> Void) -> Void)?

    /// Closure invoked for each `data(from:)` call.
    /// Test sets this to control the response. Used by `StreamResolver`.
    var dataFromHandler: ((URL) async throws -> (Data, URLResponse))?

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
        // Record a synthetic request entry so legacy assertions that scan
        // `recordedRequests` keep working. The completion handler is a
        // no-op since the async path never invokes it.
        let captured = url
        recordedRequests.append(RecordedRequest(url: captured, completionHandler: { _, _, _ in }))
        if let handler = dataFromHandler {
            return try await handler(url)
        }
        return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
    }

    /// Concrete `data(for:)` (overrides the protocol's default bridge) so tests
    /// can inspect the actual request headers. Still records the URL into
    /// `recordedRequests` so legacy URL-based assertions keep working.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequestObjects.append(request)
        let url = request.url ?? URL(string: "about:blank")!
        recordedRequests.append(RecordedRequest(url: url, completionHandler: { _, _, _ in }))
        if let handler = dataFromHandler {
            return try await handler(url)
        }
        return (Data(), URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
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

    func test_QueueMoveReorders() {
        player.addToQueue(makeTrack(id: "1", title: "A"))
        player.addToQueue(makeTrack(id: "2", title: "B"))
        player.addToQueue(makeTrack(id: "3", title: "C"))
        player.moveInQueue(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(player.queue.map(\.id), ["2", "3", "1"])
    }

    func test_QueueClearRemovesAll() {
        player.addToQueue(makeTrack(id: "1", title: "A"))
        player.addToQueue(makeTrack(id: "2", title: "B"))
        player.clearQueue()
        XCTAssertTrue(player.queue.isEmpty)
    }

    func test_PlaybackRateDefaultsToOne() {
        XCTAssertEqual(player.playbackRate, 1.0)
    }

    func test_SetPlaybackRateUpdatesValue() {
        player.setPlaybackRate(1.5)
        XCTAssertEqual(player.playbackRate, 1.5)
    }

    func test_SetPlaybackRateClampsToSupportedRange() {
        player.setPlaybackRate(5.0)
        XCTAssertEqual(player.playbackRate, 2.0)
        player.setPlaybackRate(0.1)
        XCTAssertEqual(player.playbackRate, 0.5)
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

    func test_FetchStreamURLRequestsBackend() async {
        let json = #"{"url":"/api/stream/abc.m4a","cached":false}"#
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        mockSession.dataFromHandler = { url in
            (data, response)
        }
        player.play(makeTrack(id: "abc", title: "A"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(self.mockSession.recordedRequests.contains(where: {
            $0.url.absoluteString.contains("video_id=abc")
        }))
    }

    func test_FetchStreamURLHandlesNetworkError() async {
        mockSession.dataFromHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        player.play(makeTrack(id: "abc", title: "A"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(self.player.playbackState, .idle)
        XCTAssertFalse(self.player.isPlaying)
    }

    func test_FetchStreamURLHandlesMalformedJSON() async {
        mockSession.dataFromHandler = { url in
            (Data("not json".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        player.play(makeTrack(id: "abc", title: "A"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(self.player.playbackState, .idle)
    }

    // MARK: - Engine / cache (3)

    func test_EQEnabledFlagToggles() {
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(player.eq.isEnabled)
        player.resetEQ()
        XCTAssertFalse(player.eq.isEnabled)
    }

    func test_PlayWithEQEnabled_resolvesAndStartsAVPlayer() async {
        // With EQ on, playback still resolves the direct URL and starts AVPlayer
        // immediately — EQ is applied by the real-time tap, no download. The
        // first play() should record a resolve request for the track.
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        mockSession.dataFromHandler = { url in
            (
                Data(#"{"url":"/api/stream/abc.m4a","cached":false}"#.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        player.play(makeTrack(id: "abc", title: "A"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(
            self.mockSession.recordedRequests.contains(where: { $0.url.absoluteString.contains("video_id=abc") }),
            "expected a resolve request for the played track"
        )
    }

    func test_PlayWithEQEnabled_rapidSkipDoesNotCrash() async {
        // Sanity: a fast play()→play() sequence with EQ on should not crash;
        // the first resolve is cancelled and the second play() starts fresh.
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        mockSession.dataFromHandler = { url in
            try? await Task.sleep(nanoseconds: 200_000_000)
            return (
                Data(#"{"url":"/api/stream/abc.m4a","cached":false}"#.utf8),
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        player.play(makeTrack(id: "abc", title: "A"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        player.play(makeTrack(id: "def", title: "B"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(true)  // reached here without crashing
    }

    // MARK: - Lifecycle (2)

    func test_BackendURLIsNonEmpty() {
        XCTAssertFalse(PlayerManager.backendURL.isEmpty)
    }

    func test_PlaybackStateIdleAtInit() {
        XCTAssertEqual(player.playbackState, .idle)
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - Local file playback

    func test_playLocalTrack_setsCurrentTrack() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_\(UUID().uuidString).mp3")
        try? Data(repeating: 0, count: 100).write(to: url)
        let local = LocalTrack(
            id: UUID(),
            title: "Local Song",
            artist: "Local Artist",
            artworkFileName: nil,
            fileName: url.lastPathComponent,
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        defer { try? FileManager.default.removeItem(at: url) }

        player.play(localTrack: local, fileURL: url)

        XCTAssertEqual(player.currentTrack?.title, "Local Song")
        XCTAssertEqual(player.currentTrack?.artist, "Local Artist")
        XCTAssertTrue(player.currentTrack?.id.hasPrefix("local:") ?? false)
        XCTAssertTrue(player.isPlaying)
    }

    func test_playLocalTrackWithEQ_skipsBackend() async {
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_\(UUID().uuidString).mp3")
        try? Data(repeating: 0, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let local = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: nil,
            fileName: url.lastPathComponent,
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )

        // Track requests before and after.
        let before = mockSession.recordedRequests.count
        player.play(localTrack: local, fileURL: url)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // No new backend / stream resolution requests should be made
        // — the local file plays directly through the engine path.
        XCTAssertEqual(mockSession.recordedRequests.count, before,
                       "local file playback should not hit the backend")
    }

    func test_play_trackWithLocalFileURL_routesToLocalPath() async {
        // A Track with localFileURL set must play through the local
        // path (no backend fetch) even when called via the public
        // play(track:) entry point.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_\(UUID().uuidString).mp3")
        try? Data(repeating: 0, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let track = Track(
            id: "local:\(UUID().uuidString)",
            title: "From Playlist",
            artist: "Local",
            thumbnailURL: nil,
            localFileURL: url
        )
        let before = mockSession.recordedRequests.count
        player.play(track)
        // Assert currentStreamURL synchronously, before the AVPlayer KVO
        // can dispatch a .failed status (the dummy 100-byte file is not
        // a real audio track, so KVO clears it on the main run loop).
        XCTAssertEqual(player.currentStreamURL, url)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mockSession.recordedRequests.count, before,
                       "Track with localFileURL should not trigger any network request")
        XCTAssertEqual(player.currentTrack?.id, track.id)
    }

    func test_play_trackWithoutLocalFileURL_stillGoesToBackend() async {
        // Sanity: a remote Track with no localFileURL still hits the
        // backend. Refactor must not have changed the streamed path.
        let json = #"{"url":"/api/stream/abc.m4a","cached":false}"#
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        mockSession.dataFromHandler = { _ in (data, response) }

        let track = Track(id: "yt-abc", title: "YouTube", artist: "Y", thumbnailURL: nil, localFileURL: nil)
        player.play(track)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(mockSession.recordedRequests.contains(where: { $0.url.absoluteString.contains("video_id=yt-abc") }))
    }

    func test_enableEQDuringLocalPlayback_doesNotHitBackend() async {
        // Regression: enabling EQ on a playing local file must apply EQ via
        // the AVPlayer tap, NOT call fetchStreamURL (which would hit the
        // YouTube backend with an invalid video_id like "local:<UUID>").
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_\(UUID().uuidString).mp3")
        try? Data(repeating: 0, count: 100).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let local = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: nil,
            fileName: url.lastPathComponent,
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )

        // Start with EQ off so the local file plays via AVPlayer.
        XCTAssertFalse(player.eq.isEnabled)
        let beforePlay = mockSession.recordedRequests.count
        player.play(localTrack: local, fileURL: url)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mockSession.recordedRequests.count, beforePlay,
                       "initial local playback with EQ off should not hit the backend")

        // Enable EQ — attaches the tap to the local item; must not hit the net.
        let beforeEnable = mockSession.recordedRequests.count
        player.applyEQPreset([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            mockSession.recordedRequests.count, beforeEnable,
            "enabling EQ on a playing local track must not hit the backend (was \(mockSession.recordedRequests.count - beforeEnable) new requests)"
        )
    }

    func test_playStreamedTrack_prefersDownloadedCopy_skipsBackend() async {
        // A streamed track that's been downloaded must play from its local copy,
        // never hitting the backend to resolve.
        let id = "dQw4w9WgXcQ"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dltest_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileName = "\(id).m4a"
        try? Data(repeating: 0, count: 100).write(to: dir.appendingPathComponent(fileName))
        let rec = DownloadRecord(videoID: id, fileName: fileName, sizeBytes: 100,
                                 downloadedAt: Date(), title: "T", artist: "A", thumbnailURL: nil)
        let store = InMemoryKeyValueStore(
            seed: try! SchemaStore.encode([rec], schemaVersion: DownloadManager.schemaVersion))
        let downloads = DownloadManager(store: store, downloadsDirectory: dir,
                                        urlSession: mockSession, backendURL: "http://t", apiKey: nil)
        player.configureDownloads(downloads)

        let before = mockSession.recordedRequests.count
        player.play(Track(id: id, title: "T", artist: "A"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockSession.recordedRequests.count, before,
                       "a downloaded streamed track must play locally without resolving")
        XCTAssertEqual(player.currentTrack?.id, id)
    }

    func test_localTrack_asPlayerTrack_setsLocalFileURL() {
        let url = URL(fileURLWithPath: "/tmp/foo.mp3")
        let local = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: nil,
            fileName: "foo.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        let track = local.asPlayerTrack(fileURL: url)
        XCTAssertEqual(track.id, "local:\(local.id.uuidString)")
        XCTAssertEqual(track.title, "T")
        XCTAssertEqual(track.artist, "A")
        XCTAssertEqual(track.localFileURL, url)
        XCTAssertTrue(track.isLocal)
    }

    func test_localTrack_asPlayerTrack_usesDefaultArtistWhenMissing() {
        let url = URL(fileURLWithPath: "/tmp/foo.mp3")
        let local = LocalTrack(
            id: UUID(),
            title: "T",
            artist: nil,
            artworkFileName: nil,
            fileName: "foo.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        let track = local.asPlayerTrack(fileURL: url)
        XCTAssertEqual(track.artist, "This Device")
    }

    func test_playSlice_startsAtIndexAndQueuesRemainder() {
        let a = Track(id: "a", title: "A", artist: "x", thumbnailURL: nil, localFileURL: nil)
        let b = Track(id: "b", title: "B", artist: "x", thumbnailURL: nil, localFileURL: nil)
        let c = Track(id: "c", title: "C", artist: "x", thumbnailURL: nil, localFileURL: nil)
        player.playSlice([a, b, c], startIndex: 1)
        XCTAssertEqual(player.currentTrack?.id, "b")
        XCTAssertEqual(player.queue.map(\.id), ["c"])
    }

    func test_playSlice_emptyTracksIsNoOp() {
        player.playSlice([], startIndex: 0)
        XCTAssertNil(player.currentTrack)
    }

    func test_playSlice_startIndexClampedToBounds() {
        let a = Track(id: "a", title: "A", artist: "x", thumbnailURL: nil, localFileURL: nil)
        player.playSlice([a], startIndex: 5)
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertTrue(player.queue.isEmpty)
    }

    // MARK: - Real shuffle

    func test_Shuffle_preservesTrackSetAndIsReversible() {
        let original = (1...12).map { makeTrack(id: "\($0)", title: "T\($0)") }
        original.forEach { player.addToQueue($0) }
        let originalIDs = player.queue.map(\.id)

        player.toggleShuffle()
        XCTAssertTrue(player.isShuffled)
        XCTAssertEqual(Set(player.queue.map(\.id)), Set(originalIDs),
                       "shuffle must preserve the set of upcoming tracks")

        player.toggleShuffle()
        XCTAssertFalse(player.isShuffled)
        XCTAssertEqual(player.queue.map(\.id), originalIDs,
                       "un-shuffling must restore the original order")
    }

    func test_Shuffle_unshuffleDropsAlreadyPlayedTracks() {
        let original = (1...6).map { makeTrack(id: "\($0)", title: "T\($0)") }
        original.forEach { player.addToQueue($0) }
        player.toggleShuffle()
        // Simulate two tracks being consumed off the shuffled queue.
        player.queue.removeFirst(2)
        let remaining = Set(player.queue.map(\.id))
        player.toggleShuffle()
        XCTAssertEqual(Set(player.queue.map(\.id)), remaining,
                       "restored order must only contain still-upcoming tracks")
    }

    // MARK: - Repeat-All

    func test_RepeatAll_reseedsQueueWhenItDrains() {
        let a = makeTrack(id: "a", title: "A")
        let b = makeTrack(id: "b", title: "B")
        player.repeatMode = .all
        player.playSlice([a, b], startIndex: 0)   // current=a, queue=[b]
        player.playNextInQueue()                  // current=b, queue=[]
        XCTAssertEqual(player.currentTrack?.id, "b")
        player.playNextInQueue()                  // drained + repeat all -> loop to a
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertEqual(player.queue.map(\.id), ["b"])
    }

    func test_RepeatOff_endsWhenQueueDrains() {
        let a = makeTrack(id: "a", title: "A")
        player.repeatMode = .off
        player.playSlice([a], startIndex: 0)   // current=a, queue=[]
        player.playNextInQueue()               // drained + repeat off -> ended
        XCTAssertEqual(player.playbackState, .ended)
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: - Previous-track history

    func test_PreviousTrack_returnsToPreviouslyPlayedTrack() {
        let a = makeTrack(id: "a", title: "A")
        let b = makeTrack(id: "b", title: "B")
        player.playSlice([a, b], startIndex: 0)   // current=a, queue=[b]
        player.playNextInQueue()                  // current=b, history=[a]
        XCTAssertEqual(player.currentTrack?.id, "b")

        player.previousTrack()                    // currentTime 0 -> go back to a
        XCTAssertEqual(player.currentTrack?.id, "a")
        XCTAssertEqual(player.queue.first?.id, "b",
                       "the track we left should be put back at the front of the queue")
    }

    func test_PreviousTrack_restartsWhenPastThreshold() {
        let a = makeTrack(id: "a", title: "A")
        let b = makeTrack(id: "b", title: "B")
        player.playSlice([a, b], startIndex: 0)
        player.playNextInQueue()                  // current=b, history=[a]
        player.currentTime = 30                   // well into the track
        player.previousTrack()                    // should restart b, not pop history
        XCTAssertEqual(player.currentTrack?.id, "b")
    }

    func test_PreviousTrack_withNoHistoryRestartsCurrent() {
        let a = makeTrack(id: "a", title: "A")
        player.play(a)
        player.previousTrack()
        XCTAssertEqual(player.currentTrack?.id, "a")
    }

    // MARK: - hasNext / hasPrevious (remote command availability)

    func test_hasNextAndHasPrevious_reflectQueueAndHistory() {
        XCTAssertFalse(player.hasNext)
        XCTAssertFalse(player.hasPrevious)

        let a = makeTrack(id: "a", title: "A")
        let b = makeTrack(id: "b", title: "B")
        player.playSlice([a, b], startIndex: 0)   // queue=[b], no history
        XCTAssertTrue(player.hasNext)
        XCTAssertFalse(player.hasPrevious)

        player.playNextInQueue()                  // queue=[], history=[a]
        XCTAssertFalse(player.hasNext)
        XCTAssertTrue(player.hasPrevious)
    }

    func test_hasNext_trueUnderRepeatAllEvenWhenQueueEmpty() {
        player.repeatMode = .all
        XCTAssertTrue(player.hasNext)
    }

    // MARK: - Sleep timer

    func test_SleepTimer_pausesPlaybackWhenElapsed() async {
        player.isPlaying = true
        player.playbackState = .playing
        player.scheduleSleepTimer(after: 0.05)
        XCTAssertNotNil(player.sleepTimerEndDate)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.playbackState, .paused)
        XCTAssertNil(player.sleepTimerEndDate, "the timer should clear itself after firing")
    }

    func test_SleepTimerOff_cancelsPendingTimer() {
        player.scheduleSleepTimer(after: 100)
        XCTAssertNotNil(player.sleepTimerEndDate)
        player.startSleepTimer(.off)
        XCTAssertNil(player.sleepTimerEndDate)
    }

    func test_SleepTimerDuration_mapsToInterval() {
        XCTAssertNil(SleepTimerDuration.off.timeInterval)
        XCTAssertEqual(SleepTimerDuration.min15.timeInterval, 15 * 60)
        XCTAssertEqual(SleepTimerDuration.hour2.timeInterval, 2 * 60 * 60)
    }

    // MARK: - Helpers

    private func makeTrack(id: String, title: String) -> Track {
        Track(id: id, title: title, artist: "T", thumbnailURL: nil)
    }
}
