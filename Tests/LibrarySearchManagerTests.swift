import XCTest
@testable import Aria___Music_Browser

/// Query decoding, `Loadable` state transitions, scope gating, and the
/// privacy DELETE-on-URL-change flow. All network stubbed via
/// `MockURLSession` — the suite passes with no network.
@MainActor
final class LibrarySearchManagerTests: XCTestCase {

    private func ok(_ json: String, for url: URL, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    private func makeManager(
        session: MockURLSession,
        baseURL: String? = "https://api.example",
        apiKey: String? = nil
    ) -> LibrarySearchManager {
        let sync = LibrarySyncService(
            store: InMemoryKeyValueStore(), session: session,
            resolveBaseURL: { baseURL }, resolveAPIKey: { apiKey })
        return LibrarySearchManager(
            syncService: sync, session: session,
            resolveBaseURL: { baseURL }, resolveAPIKey: { apiKey })
    }

    private func configure(_ manager: LibrarySearchManager,
                           favorites: FavoritesManager) {
        manager.configure(
            favorites: favorites,
            playlists: PlaylistsManager(store: InMemoryKeyValueStore()),
            localLibrary: LocalLibraryManager(
                store: InMemoryKeyValueStore(),
                libraryDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("lib-search-tests", isDirectory: true)),
            recents: RecentlyPlayedManager(
                playedStore: InMemoryKeyValueStore(),
                addedStore: InMemoryKeyValueStore(),
                statsStore: InMemoryKeyValueStore()),
            settings: SettingsManager())
    }

    /// Polls the main run loop until `condition` holds (the manager hops
    /// through Tasks internally; deterministic single-runloop polling keeps
    /// these tests fast without real timers).
    private func waitUntil(
        timeout: TimeInterval = 2, _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw XCTSkip.makeTimeoutFailure() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - LibrarySearchService decoding

    func test_queryClient_buildsRequestAndDecodes() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in
            self.ok(#"{"results":[{"track_id":"yt1","score":1.25,"matched":"lexical"}],"mode":"lexical"}"#, for: url)
        }
        let service = LibrarySearchService(
            backendURL: "https://api.example", session: session, apiKey: "sekret")

        let response = try await service.query(deviceID: "dev-1", q: "mellow guitar", k: 25)

        XCTAssertEqual(response.mode, "lexical")
        XCTAssertEqual(response.results, [
            .init(trackID: "yt1", score: 1.25, matched: "lexical")
        ])
        let request = try XCTUnwrap(session.recordedRequestObjects.last)
        XCTAssertEqual(request.url?.path, "/api/library/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "sekret")
        let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let items = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(items["device_id"], "dev-1")
        XCTAssertEqual(items["q"], "mellow guitar")
        XCTAssertEqual(items["k"], "25")
    }

    func test_queryClient_surfacesServerErrorAndBadJSON() async {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.ok("oops", for: url, status: 500) }
        let service = LibrarySearchService(
            backendURL: "https://api.example", session: session, apiKey: nil)
        do {
            _ = try await service.query(deviceID: "d", q: "x")
            XCTFail("expected serverError")
        } catch let error as LibrarySearchService.ServiceError {
            guard case .serverError(500) = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch { XCTFail("wrong error type: \(error)") }

        session.dataFromHandler = { url in self.ok("not json", for: url) }
        do {
            _ = try await service.query(deviceID: "d", q: "x")
            XCTFail("expected decodingFailed")
        } catch let error as LibrarySearchService.ServiceError {
            guard case .decodingFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        } catch { XCTFail("wrong error type: \(error)") }
    }

    // MARK: - Manager search: Loadable transitions + id mapping

    func test_search_loadsAndMapsTrackIDsInServerOrder() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in
            self.ok(#"{"results":[{"track_id":"yt2","score":2.0,"matched":"both"},{"track_id":"yt1","score":1.0,"matched":"vector"},{"track_id":"unknown","score":0.5,"matched":"lexical"}],"mode":"hybrid"}"#, for: url)
        }
        let manager = makeManager(session: session)
        let favorites = FavoritesManager(store: InMemoryKeyValueStore())
        favorites.add(Track(id: "yt1", title: "One", artist: "A"))
        favorites.add(Track(id: "yt2", title: "Two", artist: "B"))
        configure(manager, favorites: favorites)

        manager.search(query: "upbeat stuff")
        XCTAssertTrue(manager.results.isLoading)

        try await waitUntil { manager.results.value != nil }
        XCTAssertEqual(manager.results.value?.map(\.id), ["yt2", "yt1"])
        XCTAssertEqual(manager.mode, "hybrid")
    }

    func test_search_failureSetsFailed_andEmptyQueryResetsToIdle() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.ok("x", for: url, status: 503) }
        let manager = makeManager(session: session)
        configure(manager, favorites: FavoritesManager(store: InMemoryKeyValueStore()))

        manager.search(query: "anything")
        try await waitUntil { manager.results.error != nil }

        manager.search(query: "   ")
        guard case .idle = manager.results else {
            return XCTFail("blank query should reset to idle")
        }
    }

    func test_search_withoutBackendStaysIdle() {
        let session = MockURLSession()
        let manager = makeManager(session: session, baseURL: nil)
        manager.search(query: "anything")
        guard case .idle = manager.results else {
            return XCTFail("no backend -> no request, stays idle")
        }
        XCTAssertTrue(session.recordedRequestObjects.isEmpty)
    }

    // MARK: - Gating

    func test_scopeVisible_pureRules() {
        XCTAssertFalse(LibrarySearchManager.scopeVisible(
            backendConfigured: false, healthSawLibraryIndex: false))
        XCTAssertFalse(LibrarySearchManager.scopeVisible(
            backendConfigured: false, healthSawLibraryIndex: true))
        XCTAssertFalse(LibrarySearchManager.scopeVisible(
            backendConfigured: true, healthSawLibraryIndex: false))
        XCTAssertTrue(LibrarySearchManager.scopeVisible(
            backendConfigured: true, healthSawLibraryIndex: true))
    }

    func test_probeHealth_showsScopeOnlyWhenLibraryIndexPresent() async {
        let session = MockURLSession()
        session.dataFromHandler = { url in
            self.ok(#"{"status":"ok","library_index":{"tracks":5,"embedder":"ok"}}"#, for: url)
        }
        let manager = makeManager(session: session)
        XCTAssertFalse(manager.scopeAvailable)

        await manager.probeHealth()
        XCTAssertTrue(manager.scopeAvailable)

        // Older backend without Slice 1 -> health has no library_index block.
        session.dataFromHandler = { url in self.ok(#"{"status":"ok"}"#, for: url) }
        await manager.probeHealth()
        XCTAssertFalse(manager.scopeAvailable)
    }

    func test_probeHealth_failureOrNoBackendHidesScope() async {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.ok("down", for: url, status: 503) }
        let manager = makeManager(session: session)
        await manager.probeHealth()
        XCTAssertFalse(manager.scopeAvailable)

        let unconfigured = makeManager(session: MockURLSession(), baseURL: nil)
        await unconfigured.probeHealth()
        XCTAssertFalse(unconfigured.scopeAvailable)
    }

    // MARK: - Privacy: DELETE on backend URL change

    func test_backendURLDidChange_firesDeleteAtOldURLAndClearsState() async throws {
        let session = MockURLSession()
        var currentBase: String? = "https://old.example"
        session.dataFromHandler = { url in
            if url.path == "/api/health" {
                return self.ok(#"{"library_index":{"tracks":0,"embedder":"ok"}}"#, for: url)
            }
            return self.ok(#"{"indexed":1,"skipped":0,"deleted":0,"pending_embeddings":0}"#, for: url)
        }
        let sync = LibrarySyncService(
            store: InMemoryKeyValueStore(), session: session,
            resolveBaseURL: { currentBase }, resolveAPIKey: { nil })
        let manager = LibrarySearchManager(
            syncService: sync, session: session,
            resolveBaseURL: { currentBase }, resolveAPIKey: { nil })
        configure(manager, favorites: FavoritesManager(store: InMemoryKeyValueStore()))

        // Seed some synced state at the old backend.
        try await sync.sync(snapshot: [LibraryTrackDoc(
            trackID: "yt1", title: "Song", artist: "A", album: nil, genre: nil,
            duration: nil, playlists: [], affinity: [])])
        await manager.probeHealth()
        XCTAssertTrue(manager.scopeAvailable)
        XCTAssertFalse(sync.syncedHashes.isEmpty)

        // User clears the backend URL in Settings.
        currentBase = nil
        manager.backendURLDidChange()

        try await waitUntil { session.recordedRequestObjects.contains { $0.httpMethod == "DELETE" } }
        let deleteRequest = try XCTUnwrap(
            session.recordedRequestObjects.first { $0.httpMethod == "DELETE" })
        XCTAssertEqual(deleteRequest.url?.host, "old.example")
        XCTAssertEqual(deleteRequest.url?.path, "/api/library")
        XCTAssertTrue(
            deleteRequest.url?.query?.contains("device_id=\(sync.deviceID)") == true)
        XCTAssertTrue(sync.syncedHashes.isEmpty)
        XCTAssertFalse(manager.scopeAvailable)
    }

    func test_backendURLDidChange_sameURLDoesNotFireDelete() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in
            self.ok(#"{"library_index":{"tracks":0,"embedder":"ok"}}"#, for: url)
        }
        let manager = makeManager(session: session, baseURL: "https://api.example")
        configure(manager, favorites: FavoritesManager(store: InMemoryKeyValueStore()))
        await manager.probeHealth() // records lastKnownBaseURL

        manager.backendURLDidChange() // resolves to the same URL

        // Allow the async task to settle, then assert no DELETE went out.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(session.recordedRequestObjects.contains { $0.httpMethod == "DELETE" })
    }
}

private extension XCTSkip {
    /// A plain error for waitUntil timeouts (keeps the helper non-throwingly
    /// simple to read at call sites while still failing loudly).
    static func makeTimeoutFailure() -> Error {
        NSError(domain: "LibrarySearchManagerTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "waitUntil timed out"])
    }
}
