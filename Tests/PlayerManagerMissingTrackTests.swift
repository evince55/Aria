import XCTest
@testable import Aria___Music_Browser

@MainActor
final class PlayerManagerMissingTrackTests: XCTestCase {
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

    func test_playSlice_skipsMissingTracks() throws {
        let presentURL = FileManager.default.temporaryDirectory.appendingPathComponent("p_\(UUID().uuidString).mp3")
        try Data(repeating: 0, count: 100).write(to: presentURL)
        defer { try? FileManager.default.removeItem(at: presentURL) }
        let presentLocal = LocalTrack(
            id: UUID(), title: "Present", artist: "A", artworkFileName: nil,
            fileName: presentURL.lastPathComponent, importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30
        )
        let missingLocal = LocalTrack(
            id: UUID(), title: "Missing", artist: "A", artworkFileName: nil,
            fileName: "nope.mp3", importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30,
            isMissing: true
        )
        let presentTrack = presentLocal.asPlayerTrack(fileURL: presentURL)
        let missingTrack = missingLocal.asPlayerTrack(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("nope.mp3")
        )

        player.playSlice([missingTrack, presentTrack], startIndex: 0)

        XCTAssertEqual(player.currentTrack?.title, "Present")
        XCTAssertTrue(player.queue.isEmpty, "queue should not contain skipped missing track")
    }

    func test_playSlice_skippedMissingTracks_preservesStartIndex() throws {
        // Library layout (missing tracks bookend the playable list):
        //   [M1, P1, P2, P3, M2]
        // User taps P2, the SECOND playable track, which sits at
        // unfiltered index 2. The filtered (playable) list is
        //   [P1, P2, P3]   (length 3)
        // so the unfiltered index (2) equals `playable.count - 1`
        // — the exact boundary where the pre-fix bug surfaces.
        //
        // Pre-fix bug: `LibraryView.playTrack` called
        //   playSlice(unfilteredLibrary, startIndex: 2)
        // and playSlice's internal filter + clamp computed
        //   max(0, min(2, 2)) = 2
        // which is filtered[2] = P3 (WRONG) with an empty queue.
        //
        // Post-fix: `LibraryView.playTrack` pre-filters missing
        // tracks FIRST, then locates P2 at filtered index 1, and
        // calls
        //   playSlice(playable, startIndex: 1)
        // which plays P2 and queues [P3] (the track that follows
        // P2 in the *playable* list, not the unfiltered list).
        //
        // The queue assertion is what nails the bug down: under
        // the pre-fix code, the queue after `playSlice([M1, P1,
        // P2, P3, M2], startIndex: 2)` is `[]` (no playable
        // tracks after filtered[2] = P3). Under the post-fix
        // code, the queue is `[P3]`. Together with the
        // currentTrack assertion (P2 vs P3), the test pins both
        // the "what plays now" and "what plays next" contracts.
        let presentURL1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("p1_\(UUID().uuidString).mp3")
        let presentURL2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2_\(UUID().uuidString).mp3")
        let presentURL3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3_\(UUID().uuidString).mp3")
        try Data(repeating: 0, count: 100).write(to: presentURL1)
        try Data(repeating: 0, count: 100).write(to: presentURL2)
        try Data(repeating: 0, count: 100).write(to: presentURL3)
        defer {
            try? FileManager.default.removeItem(at: presentURL1)
            try? FileManager.default.removeItem(at: presentURL2)
            try? FileManager.default.removeItem(at: presentURL3)
        }
        let m1 = LocalTrack(
            id: UUID(), title: "M1", artist: "A", artworkFileName: nil,
            fileName: "m1.mp3", importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30,
            isMissing: true
        )
        let p1 = LocalTrack(
            id: UUID(), title: "P1", artist: "A", artworkFileName: nil,
            fileName: presentURL1.lastPathComponent, importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30
        )
        let p2 = LocalTrack(
            id: UUID(), title: "P2", artist: "A", artworkFileName: nil,
            fileName: presentURL2.lastPathComponent, importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30
        )
        let p3 = LocalTrack(
            id: UUID(), title: "P3", artist: "A", artworkFileName: nil,
            fileName: presentURL3.lastPathComponent, importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30
        )
        let m2 = LocalTrack(
            id: UUID(), title: "M2", artist: "A", artworkFileName: nil,
            fileName: "m2.mp3", importedAt: Date(),
            fileSizeBytes: 100, durationSeconds: 30,
            isMissing: true
        )
        let library = [m1, p1, p2, p3, m2]
        // In production, `LocalLibraryManager.fileURL(for:)` returns a
        // URL for *every* track (it appends `fileName` to the library
        // directory and never checks existence). Mirror that here so
        // the test's `fileURL` closure doesn't crash on missing tracks
        // when the OLD pre-filter-free `playableStartIndex` is in
        // effect — we want a clean assertion failure, not a nil
        // force-unwrap, when the bug regresses.
        let missingURL1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1_\(UUID().uuidString).mp3")
        let missingURL2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("m2_\(UUID().uuidString).mp3")
        let urls: [UUID: URL] = [
            m1.id: missingURL1,
            p1.id: presentURL1,
            p2.id: presentURL2,
            p3.id: presentURL3,
            m2.id: missingURL2
        ]
        let playable = library
            .filter { !$0.isMissing }
            .map { local in
                local.asPlayerTrack(fileURL: urls[local.id]!)
            }

        // Sanity checks: the test setup must actually distinguish
        // the OLD pre-fix code path from the NEW post-fix code path,
        // otherwise the assertions below would pass against either
        // implementation and the test would not be a true regression
        // test for the off-by-index bug.
        let tappedUnfilteredIndex = library.firstIndex { $0.id == p2.id }
        let tappedFilteredIndex = playable.firstIndex { $0.id == "local:\(p2.id.uuidString)" }
        XCTAssertEqual(tappedUnfilteredIndex, 2, "P2 must sit at unfiltered index 2 in [M1, P1, P2, P3, M2]")
        XCTAssertEqual(tappedFilteredIndex, 1, "P2 must sit at filtered index 1 in [P1, P2, P3]")
        XCTAssertNotEqual(
            tappedUnfilteredIndex, tappedFilteredIndex,
            "test setup must make the OLD unfiltered index differ from the NEW filtered index — otherwise the bug is invisible"
        )
        // The OLD pre-fix code passed the unfiltered index into
        // playSlice, which would clamp it to max(0, min(2, 2)) = 2.
        // That clamped value must point at a DIFFERENT track than
        // the tapped one — otherwise the bug would not surface even
        // under the pre-fix code.
        let oldClampedIndex = max(0, min(tappedUnfilteredIndex!, playable.count - 1))
        XCTAssertEqual(
            oldClampedIndex, tappedUnfilteredIndex,
            "pre-fix clamp must be a no-op in this layout, so the bug surfaces in the picked track"
        )
        XCTAssertNotEqual(
            playable[oldClampedIndex].id, "local:\(p2.id.uuidString)",
            "the OLD clamped index must point at a different track than the tapped one — this is the bug"
        )

        // The fix: `LibraryView.playTrack` resolves the tapped
        // track's index AFTER pre-filtering missing entries. This
        // test pins the resulting `playSlice` contract: start on
        // the tapped track, queue the tracks that follow it in the
        // *playable* list.
        //
        // We call the production `LibraryView.playableStartIndex`
        // helper (the same entry point `playTrack` uses) so the
        // test fails if the pre-filter step is ever removed or
        // regressed — the helper would then return the unfiltered
        // library + unfiltered index, and `playSlice`'s internal
        // clamp would land on the wrong track.
        let urlsClosure: (LocalTrack) -> URL = { local in urls[local.id]! }
        guard let result = LibraryView.playableStartIndex(
            in: library,
            tappedTrack: p2,
            fileURL: urlsClosure
        ) else {
            XCTFail("LibraryView.playableStartIndex returned nil for a present track")
            return
        }
        player.playSlice(result.playable, startIndex: result.startIndex)

        XCTAssertEqual(
            player.currentTrack?.id, "local:\(p2.id.uuidString)",
            "playback must start on P2 (filtered index 1), not P3 (the track the OLD pre-fix code would have picked via its unfiltered-index clamp)"
        )
        XCTAssertEqual(
            player.queue.map { $0.title }, ["P3"],
            "queue must be [P3] — the track that follows P2 in the playable list. Under the OLD pre-fix code the queue is [] (P3 is the last playable track, so there is nothing after the wrongly-picked filtered[2]). The differing queue shapes are how this test catches the off-by-index bug even if someone re-adds a missing track or shifts indices."
        )
    }

    func test_playLocalTrack_missingFile_setsPlayerError() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing_\(UUID().uuidString).mp3")
        // Intentionally do NOT write the file — it does not exist on disk.
        defer { /* no-op: file was never created */ }

        let local = LocalTrack(
            id: UUID(),
            title: "Ghost",
            artist: "A",
            artworkFileName: nil,
            fileName: url.lastPathComponent,
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30,
            isMissing: true
        )

        player.play(localTrack: local, fileURL: url)

        XCTAssertEqual(player.playerError, .trackMissing(trackID: "local:\(local.id.uuidString)"))
        XCTAssertEqual(player.playbackState, .ended)
        XCTAssertFalse(player.isPlaying)
    }
}
