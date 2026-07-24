import XCTest
@testable import Aria___Music_Browser

final class SmartPlaylistEngineTests: XCTestCase {

    private typealias Candidate = SmartPlaylistEngine.SmartCandidate

    private func track(_ id: String, title: String = "Title", artist: String = "Artist",
                       localFile: String? = nil) -> Track {
        Track(id: id, title: title, artist: artist, thumbnailURL: nil,
              localFileURL: localFile.map { URL(fileURLWithPath: "/tmp/\($0)") })
    }

    private func candidate(_ id: String, source: SmartSource = .localFile,
                           title: String = "Title", artist: String = "Artist",
                           addedAt: Date? = nil, fileName: String? = nil,
                           duration: Double? = nil, album: String? = nil) -> Candidate {
        Candidate(track: track(id, title: title, artist: artist),
                  source: source, addedAt: addedAt, fileName: fileName,
                  durationSeconds: duration, album: album)
    }

    private func playlist(rules: SmartPlaylistRules, sort: SmartSort = .title,
                          limit: Int? = nil) -> SmartPlaylist {
        SmartPlaylist(name: "test", rules: rules, sort: sort, limit: limit)
    }

    private func evaluate(_ p: SmartPlaylist, _ candidates: [Candidate],
                          favorites: Set<String> = [], recents: Set<String> = [],
                          now: Date = Date(timeIntervalSince1970: 1_000_000)) -> [String] {
        SmartPlaylistEngine.evaluate(p, candidates: candidates, favoriteIDs: favorites,
                                     recentlyPlayedIDs: recents, now: now).map(\.id)
    }

    // MARK: - Rules

    func test_sourceFilter() {
        let cands = [candidate("a", source: .localFile),
                     candidate("b", source: .download),
                     candidate("c", source: .favorite)]
        var rules = SmartPlaylistRules(); rules.sources = [.download]
        XCTAssertEqual(evaluate(playlist(rules: rules), cands), ["b"])
    }

    func test_textFilters_caseInsensitive_andComposed() {
        let cands = [candidate("a", title: "Purple Rain", artist: "Prince"),
                     candidate("b", title: "Purple Haze", artist: "Hendrix")]
        var rules = SmartPlaylistRules()
        rules.titleContains = "purple"
        rules.artistContains = "PRIN"
        XCTAssertEqual(evaluate(playlist(rules: rules), cands), ["a"])
    }

    func test_albumFilter_matchesCandidateAlbum() {
        let cands = [candidate("a", album: "4:44"), candidate("b", album: "Lemonade")]
        var rules = SmartPlaylistRules(); rules.albumContains = "4:44"
        XCTAssertEqual(evaluate(playlist(rules: rules), cands), ["a"])
    }

    func test_losslessOnly_byExtension_andUnknownFileFails() {
        let cands = [candidate("a", fileName: "x.flac"),
                     candidate("b", fileName: "y.m4a"),
                     candidate("c", fileName: nil)]
        var rules = SmartPlaylistRules(); rules.losslessOnly = true
        XCTAssertEqual(evaluate(playlist(rules: rules), cands), ["a"])
    }

    func test_favoritesOnly_intersectsAnySource() {
        let cands = [candidate("a", source: .localFile), candidate("b", source: .localFile)]
        var rules = SmartPlaylistRules(); rules.favoritesOnly = true
        XCTAssertEqual(evaluate(playlist(rules: rules), cands, favorites: ["b"]), ["b"])
    }

    func test_recency_bothDirections() {
        let cands = [candidate("a"), candidate("b")]
        var recent = SmartPlaylistRules(); recent.recency = .recentlyPlayed
        XCTAssertEqual(evaluate(playlist(rules: recent), cands, recents: ["a"]), ["a"])
        var forgotten = SmartPlaylistRules(); forgotten.recency = .notRecentlyPlayed
        XCTAssertEqual(evaluate(playlist(rules: forgotten), cands, recents: ["a"]), ["b"])
    }

    func test_addedWithinDays_boundary_andNilAddedFails() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cands = [
            candidate("fresh", addedAt: now.addingTimeInterval(-6 * 86_400)),
            candidate("stale", addedAt: now.addingTimeInterval(-8 * 86_400)),
            candidate("undated", addedAt: nil),
        ]
        var rules = SmartPlaylistRules(); rules.addedWithinDays = 7
        XCTAssertEqual(evaluate(playlist(rules: rules), cands, now: now), ["fresh"])
    }

    func test_durationBounds_unknownDurationExcludedWhenBounded() {
        let cands = [candidate("short", duration: 120),
                     candidate("long", duration: 900),
                     candidate("unknown", duration: nil)]
        var over = SmartPlaylistRules(); over.minMinutes = 5
        XCTAssertEqual(evaluate(playlist(rules: over), cands), ["long"])
        var under = SmartPlaylistRules(); under.maxMinutes = 5
        XCTAssertEqual(evaluate(playlist(rules: under), cands), ["short"])
    }

    // MARK: - Dedupe / sort / limit

    func test_dedupe_prefersLocalOverDownloadOverFavorite() {
        var rules = SmartPlaylistRules(); rules.sources = [.localFile, .download, .favorite]
        let cands = [candidate("x", source: .favorite),
                     candidate("x", source: .download),
                     candidate("x", source: .localFile),
                     candidate("y", source: .download)]
        let result = SmartPlaylistEngine.evaluate(
            playlist(rules: rules), candidates: cands, favoriteIDs: [], recentlyPlayedIDs: [])
        XCTAssertEqual(result.map(\.id).sorted(), ["x", "y"])
    }

    func test_sort_newestAdded_nilsSinkToEnd() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var rules = SmartPlaylistRules(); rules.sources = [.localFile, .favorite]
        let cands = [candidate("old", addedAt: now.addingTimeInterval(-100)),
                     candidate("undated", source: .favorite, addedAt: nil),
                     candidate("new", addedAt: now)]
        let ids = evaluate(playlist(rules: rules, sort: .newestAdded), cands, now: now)
        XCTAssertEqual(ids, ["new", "old", "undated"])
    }

    func test_sort_longest() {
        let cands = [candidate("a", duration: 100), candidate("b", duration: 300)]
        XCTAssertEqual(evaluate(playlist(rules: SmartPlaylistRules(), sort: .longest), cands),
                       ["b", "a"])
    }

    func test_limit_appliesAfterSort() {
        let cands = [candidate("b", title: "B"), candidate("a", title: "A"), candidate("c", title: "C")]
        XCTAssertEqual(evaluate(playlist(rules: SmartPlaylistRules(), sort: .title, limit: 2), cands),
                       ["a", "b"])
    }

    func test_shuffle_preservesMembership() {
        let cands = (0..<20).map { candidate("id\($0)") }
        let ids = evaluate(playlist(rules: SmartPlaylistRules(), sort: .shuffle), cands)
        XCTAssertEqual(Set(ids), Set(cands.map(\.track.id)))
    }

    // MARK: - Candidate assembly

    func test_candidates_skipMissingLocals_andCarryMetadata() {
        let ok = LocalTrack(id: UUID(), title: "Song", artist: "Artist",
                            artworkFileName: nil, fileName: "song.flac",
                            importedAt: Date(timeIntervalSince1970: 500),
                            fileSizeBytes: 10, durationSeconds: 200, album: "Album")
        let missing = LocalTrack(id: UUID(), title: "Gone", artist: nil,
                                 artworkFileName: nil, fileName: "gone.mp3",
                                 importedAt: Date(), fileSizeBytes: 1,
                                 durationSeconds: nil, isMissing: true)
        let rec = DownloadRecord(videoID: "vid00000001", fileName: "vid00000001.m4a",
                                 sizeBytes: 5, downloadedAt: Date(timeIntervalSince1970: 600),
                                 title: "DL", artist: "A", thumbnailURL: nil)

        let cands = SmartPlaylistEngine.candidates(
            localTracks: [ok, missing],
            fileURL: { URL(fileURLWithPath: "/tmp/\($0.fileName)") },
            downloads: [rec],
            favorites: [track("fav1")]
        )

        XCTAssertEqual(cands.count, 3, "missing local files must be skipped")
        let local = cands.first { $0.source == .localFile }!
        XCTAssertEqual(local.fileName, "song.flac")
        XCTAssertEqual(local.album, "Album")
        XCTAssertEqual(local.addedAt, Date(timeIntervalSince1970: 500))
        XCTAssertNotNil(local.track.localFileURL)
        let dl = cands.first { $0.source == .download }!
        XCTAssertEqual(dl.track.id, "vid00000001")
        XCTAssertEqual(dl.addedAt, Date(timeIntervalSince1970: 600))
    }
}
