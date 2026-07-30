import XCTest
@testable import Aria___Music_Browser

/// Snapshot assembly, delta computation, the 60 s sync gate, and the sync /
/// privacy-delete network calls — all with the network stubbed through
/// `MockURLSession` (hermeticity rule: passes with no network).
@MainActor
final class LibrarySyncServiceTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_753_000_000)

    private func track(_ id: String, title: String = "T", artist: String = "A",
                       album: String? = nil, duration: Double? = nil) -> Track {
        Track(id: id, title: title, artist: artist, duration: duration, album: album)
    }

    private func stat(daysAgo: Double, count: Int) -> RecentlyPlayedManager.PlayStat {
        .init(lastPlayedAt: now.addingTimeInterval(-daysAgo * 86400), playCount: count)
    }

    private func makeService(
        session: MockURLSession = MockURLSession(),
        store: InMemoryKeyValueStore = InMemoryKeyValueStore(),
        baseURL: String? = "https://api.example",
        apiKey: String? = nil
    ) -> LibrarySyncService {
        LibrarySyncService(
            store: store,
            session: session,
            resolveBaseURL: { baseURL },
            resolveAPIKey: { apiKey },
            now: { self.now })
    }

    // MARK: - Snapshot assembly

    func test_snapshot_unionsAllSourcesAndDeduplicates() {
        let fav = track("yt1", title: "Song One")
        let playlist = Playlist(name: "Mix", tracks: [fav, track("yt2", title: "Song Two")])
        let local = LocalTrack(
            id: UUID(), title: "Imported", artist: "Me", artworkFileName: nil,
            fileName: "f.mp3", importedAt: now, fileSizeBytes: 1,
            durationSeconds: 100, album: "Alb")
        let snapshot = LibrarySyncService.buildSnapshot(
            favorites: [fav], playlists: [playlist], localTracks: [local],
            recentlyPlayed: [fav], playStats: [:], now: now)

        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(Set(snapshot.map(\.trackID)),
                       ["yt1", "yt2", "local:\(local.id.uuidString)"])
    }

    func test_snapshot_playlistMembership_sortedByCleanedName() {
        let t = track("yt1")
        let snapshot = LibrarySyncService.buildSnapshot(
            favorites: [],
            playlists: [
                Playlist(name: "zebra", tracks: [t]),
                Playlist(name: "  Alpha  Mix ", tracks: [t]),
            ],
            localTracks: [], recentlyPlayed: [], playStats: [:], now: now)

        XCTAssertEqual(snapshot.first?.playlists, ["  Alpha  Mix ", "zebra"])
        XCTAssertTrue(snapshot.first?.docText.contains("playlists: alpha mix zebra") == true)
    }

    func test_snapshot_affinityFlags() {
        let favorite = track("fav")
        let recent = track("rec")
        let dormant = track("dor")
        let frequent = track("frq")
        let neverPlayed = track("nvr")
        let stats: [String: RecentlyPlayedManager.PlayStat] = [
            "fav": stat(daysAgo: 3, count: 1),
            "rec": stat(daysAgo: 6.9, count: 1),
            "dor": stat(daysAgo: 61, count: 1),
            "frq": stat(daysAgo: 30, count: 10),
        ]
        let snapshot = LibrarySyncService.buildSnapshot(
            favorites: [favorite],
            playlists: [Playlist(name: "P", tracks: [recent, dormant, frequent, neverPlayed])],
            localTracks: [], recentlyPlayed: [], playStats: stats, now: now)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.trackID, $0) })

        XCTAssertEqual(byID["fav"]?.affinity, ["favorite", "recent"])
        XCTAssertEqual(byID["rec"]?.affinity, ["recent"])
        XCTAssertEqual(byID["dor"]?.affinity, ["dormant"])
        // threshold = max(2, p75 of [1,1,1,10]) = max(2, 10) = 10
        XCTAssertEqual(byID["frq"]?.affinity, ["frequent"])
        XCTAssertEqual(byID["nvr"]?.affinity, [])
    }

    func test_frequentThreshold_topQuartileNeverBelowTwo() {
        XCTAssertNil(LibrarySyncService.frequentThreshold(playStats: [:]))
        // All single plays: p75 = 1, clamped to 2 -> nothing qualifies.
        let singles = Dictionary(uniqueKeysWithValues: (0..<4).map {
            ("t\($0)", stat(daysAgo: 1, count: 1))
        })
        XCTAssertEqual(LibrarySyncService.frequentThreshold(playStats: singles), 2)
    }

    func test_snapshot_skipsMissingTracks() {
        var missing = track("gone")
        missing.isMissing = true
        let snapshot = LibrarySyncService.buildSnapshot(
            favorites: [missing, track("here")], playlists: [], localTracks: [],
            recentlyPlayed: [], playStats: [:], now: now)
        XCTAssertEqual(snapshot.map(\.trackID), ["here"])
    }

    // MARK: - Delta

    func test_delta_changedUnchangedDeleted() {
        let a = LibraryTrackDoc(trackID: "a", title: "Same", artist: "X", album: nil,
                                genre: nil, duration: nil, playlists: [], affinity: [])
        let b = LibraryTrackDoc(trackID: "b", title: "Changed", artist: "X", album: nil,
                                genre: nil, duration: nil, playlists: [], affinity: [])
        let c = LibraryTrackDoc(trackID: "c", title: "New", artist: "X", album: nil,
                                genre: nil, duration: nil, playlists: [], affinity: [])
        let lastSynced = [
            "a": a.docHash,           // unchanged -> skipped
            "b": "old-hash",          // changed -> sent
            "gone": "whatever",       // no longer in library -> deleted
        ]
        let delta = LibrarySyncService.computeDelta(current: [a, b, c], lastSynced: lastSynced)

        XCTAssertEqual(delta.changed.map(\.trackID), ["b", "c"])
        XCTAssertEqual(delta.deletedIDs, ["gone"])
        XCTAssertFalse(delta.isEmpty)
    }

    func test_delta_emptyWhenNothingChanged() {
        let a = LibraryTrackDoc(trackID: "a", title: "Same", artist: "X", album: nil,
                                genre: nil, duration: nil, playlists: [], affinity: [])
        let delta = LibrarySyncService.computeDelta(
            current: [a], lastSynced: ["a": a.docHash])
        XCTAssertTrue(delta.isEmpty)
    }

    // MARK: - Sync gate

    func test_gate_allowsFirstSyncAndAfterInterval() {
        XCTAssertTrue(LibrarySyncService.shouldSync(now: now, lastAttempt: nil))
        XCTAssertFalse(LibrarySyncService.shouldSync(
            now: now, lastAttempt: now.addingTimeInterval(-59)))
        XCTAssertTrue(LibrarySyncService.shouldSync(
            now: now, lastAttempt: now.addingTimeInterval(-60)))
        XCTAssertEqual(LibrarySyncService.secondsUntilSyncAllowed(
            now: now, lastAttempt: now.addingTimeInterval(-45)), 15, accuracy: 0.001)
        XCTAssertEqual(LibrarySyncService.secondsUntilSyncAllowed(
            now: now, lastAttempt: nil), 0)
    }

    // MARK: - Device ID

    func test_deviceID_stableAcrossReloads_andServerShaped() throws {
        let store = InMemoryKeyValueStore()
        let first = makeService(store: store)
        first.flushPendingWrites()
        let second = makeService(store: store)

        XCTAssertEqual(first.deviceID, second.deviceID)
        // Server validates ^[A-Za-z0-9_-]{1,64}$
        let range = first.deviceID.range(
            of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression)
        XCTAssertNotNil(range)
    }

    // MARK: - Network

    private func okResponse(_ url: URL, status: Int = 200, json: String = #"{"indexed":1,"skipped":0,"deleted":0,"pending_embeddings":0}"#) -> (Data, URLResponse) {
        (Data(json.utf8),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func test_sync_postsDeltaAndRecordsHashes() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.okResponse(url) }
        let service = makeService(session: session, apiKey: "sekret")
        let doc = LibraryTrackDoc(trackID: "yt1", title: "Song", artist: "Artist",
                                  album: "Alb", genre: nil, duration: 200,
                                  playlists: ["Mix"], affinity: ["favorite"])

        try await service.sync(snapshot: [doc])

        let request = try XCTUnwrap(session.recordedRequestObjects.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/library/sync")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "sekret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["device_id"] as? String, service.deviceID)
        let tracks = try XCTUnwrap(json["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0]["track_id"] as? String, "yt1")
        XCTAssertEqual(tracks[0]["doc_hash"] as? String, doc.docHash)
        XCTAssertEqual(tracks[0]["playlists"] as? [String], ["Mix"])
        XCTAssertEqual(tracks[0]["affinity"] as? [String], ["favorite"])
        XCTAssertEqual(json["deleted_track_ids"] as? [String], [])

        XCTAssertEqual(service.syncedHashes, ["yt1": doc.docHash])
    }

    func test_sync_skipsNetworkWhenNothingChanged() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.okResponse(url) }
        let service = makeService(session: session)
        let doc = LibraryTrackDoc(trackID: "yt1", title: "Song", artist: "Artist",
                                  album: nil, genre: nil, duration: nil,
                                  playlists: [], affinity: [])
        try await service.sync(snapshot: [doc])
        let requestsAfterFirst = session.recordedRequestObjects.count

        try await service.sync(snapshot: [doc]) // identical snapshot

        XCTAssertEqual(session.recordedRequestObjects.count, requestsAfterFirst)
    }

    func test_sync_failureKeepsHashesForRetry() async {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.okResponse(url, status: 500) }
        let service = makeService(session: session)
        let doc = LibraryTrackDoc(trackID: "yt1", title: "Song", artist: "Artist",
                                  album: nil, genre: nil, duration: nil,
                                  playlists: [], affinity: [])

        do {
            try await service.sync(snapshot: [doc])
            XCTFail("expected httpStatus error")
        } catch {}

        // Hashes not advanced -> the same delta is retried next time.
        XCTAssertTrue(service.syncedHashes.isEmpty)
        // But the attempt still armed the gate.
        XCTAssertNotNil(service.lastSyncAttemptAt)
    }

    func test_deleteRemoteAndReset_firesDeleteAtOldURLAndClearsState() async throws {
        let session = MockURLSession()
        session.dataFromHandler = { url in self.okResponse(url, json: #"{"deleted":3}"#) }
        let service = makeService(session: session, apiKey: "sekret")
        let doc = LibraryTrackDoc(trackID: "yt1", title: "Song", artist: "Artist",
                                  album: nil, genre: nil, duration: nil,
                                  playlists: [], affinity: [])
        try await service.sync(snapshot: [doc])
        XCTAssertFalse(service.syncedHashes.isEmpty)

        await service.deleteRemoteAndReset(oldBaseURL: "https://old.example")

        let request = try XCTUnwrap(session.recordedRequestObjects.last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.host, "old.example")
        XCTAssertEqual(request.url?.path, "/api/library")
        XCTAssertTrue(request.url?.query?.contains("device_id=\(service.deviceID)") == true)
        XCTAssertTrue(service.syncedHashes.isEmpty)
    }

    func test_deleteRemoteAndReset_nilOldURL_clearsStateWithoutNetwork() async {
        let session = MockURLSession()
        let service = makeService(session: session)

        await service.deleteRemoteAndReset(oldBaseURL: nil)

        XCTAssertTrue(session.recordedRequestObjects.isEmpty)
        XCTAssertTrue(service.syncedHashes.isEmpty)
    }
}
