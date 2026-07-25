import XCTest
@testable import Aria___Music_Browser

final class M3UPlaylistTests: XCTestCase {

    private func local(_ title: String, artist: String?, fileName: String,
                       missing: Bool = false) -> LocalTrack {
        LocalTrack(id: UUID(), title: title, artist: artist, artworkFileName: nil,
                   fileName: fileName, importedAt: Date(), fileSizeBytes: 100,
                   durationSeconds: 200, album: nil, isMissing: missing)
    }

    private func url(_ t: LocalTrack) -> URL { URL(fileURLWithPath: "/lib/\(t.fileName)") }

    // MARK: - Parse

    func test_parse_extendedM3U_withMetadata() throws {
        let text = """
        #EXTM3U
        #EXTINF:213,Prince - Purple Rain
        /Users/me/Music/purple.flac
        #EXTINF:180,Jay-Z - 4:44
        444.m4a
        """
        let entries = try M3UPlaylist.parse(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].artist, "Prince")
        XCTAssertEqual(entries[0].title, "Purple Rain")
        XCTAssertEqual(entries[0].durationSeconds, 213)
        XCTAssertEqual(entries[0].fileName, "purple.flac")
        XCTAssertEqual(entries[1].fileName, "444.m4a")
    }

    func test_parse_simpleM3U_pathsOnly() throws {
        let entries = try M3UPlaylist.parse("a.mp3\nb.flac\n")
        XCTAssertEqual(entries.map(\.fileName), ["a.mp3", "b.flac"])
        XCTAssertNil(entries[0].title)
    }

    func test_parse_handlesCRLF_blankLines_andUnknownDirectives() throws {
        let text = "#EXTM3U\r\n\r\n#PLAYLIST:Mine\r\n#EXTINF:-1,No Duration\r\nx.mp3\r\n"
        let entries = try M3UPlaylist.parse(text)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fileName, "x.mp3")
        XCTAssertNil(entries[0].durationSeconds, "-1 means unknown, not a real duration")
        XCTAssertEqual(entries[0].title, "No Duration")
    }

    func test_parse_metadataDoesNotLeakToLaterEntries() throws {
        let text = """
        #EXTINF:100,A - One
        one.mp3
        two.mp3
        """
        let entries = try M3UPlaylist.parse(text)
        XCTAssertEqual(entries[0].title, "One")
        XCTAssertNil(entries[1].title, "EXTINF applies only to the next path")
        XCTAssertNil(entries[1].durationSeconds)
    }

    func test_parse_emptyOrCommentsOnly_throws() {
        XCTAssertThrowsError(try M3UPlaylist.parse("#EXTM3U\n\n")) { error in
            XCTAssertEqual(error as? M3UPlaylist.ParseError, .noEntries)
        }
    }

    // MARK: - Resolve

    func test_resolve_matchesByFileName_caseInsensitive() {
        let track = local("Purple Rain", artist: "Prince", fileName: "Purple.flac")
        let entries = [M3UPlaylist.Entry(path: "/elsewhere/PURPLE.FLAC", title: nil,
                                         artist: nil, durationSeconds: nil)]
        let (tracks, unmatched) = M3UPlaylist.resolve(entries: entries,
                                                      libraryTracks: [track], fileURL: url)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(unmatched.isEmpty)
        XCTAssertNotNil(tracks[0].localFileURL)
    }

    func test_resolve_fallsBackToTitleArtist() {
        let track = local("Purple Rain", artist: "Prince", fileName: "renamed-on-import.flac")
        let entries = [M3UPlaylist.Entry(path: "old/path/purple.flac", title: "Purple Rain",
                                         artist: "Prince", durationSeconds: nil)]
        let (tracks, unmatched) = M3UPlaylist.resolve(entries: entries,
                                                      libraryTracks: [track], fileURL: url)
        XCTAssertEqual(tracks.count, 1, "file renamed on import should still resolve by metadata")
        XCTAssertTrue(unmatched.isEmpty)
    }

    func test_resolve_reportsUnmatched_andPreservesOrder() {
        let a = local("A", artist: "X", fileName: "a.mp3")
        let b = local("B", artist: "X", fileName: "b.mp3")
        let entries = [
            M3UPlaylist.Entry(path: "b.mp3", title: nil, artist: nil, durationSeconds: nil),
            M3UPlaylist.Entry(path: "missing.mp3", title: nil, artist: nil, durationSeconds: nil),
            M3UPlaylist.Entry(path: "a.mp3", title: nil, artist: nil, durationSeconds: nil),
        ]
        let (tracks, unmatched) = M3UPlaylist.resolve(entries: entries,
                                                      libraryTracks: [a, b], fileURL: url)
        XCTAssertEqual(tracks.map(\.title), ["B", "A"], "playlist order wins over library order")
        XCTAssertEqual(unmatched.map(\.fileName), ["missing.mp3"])
    }

    func test_resolve_skipsMissingFilesAndDuplicates() {
        let gone = local("Gone", artist: nil, fileName: "gone.mp3", missing: true)
        let ok = local("Here", artist: nil, fileName: "here.mp3")
        let entries = [
            M3UPlaylist.Entry(path: "gone.mp3", title: nil, artist: nil, durationSeconds: nil),
            M3UPlaylist.Entry(path: "here.mp3", title: nil, artist: nil, durationSeconds: nil),
            M3UPlaylist.Entry(path: "here.mp3", title: nil, artist: nil, durationSeconds: nil),
        ]
        let (tracks, unmatched) = M3UPlaylist.resolve(entries: entries,
                                                      libraryTracks: [gone, ok], fileURL: url)
        XCTAssertEqual(tracks.count, 1, "missing-file tracks aren't candidates; dupes collapse")
        XCTAssertEqual(unmatched.count, 1)
    }

    // MARK: - Write + round trip

    func test_write_producesExtendedM3U_withBareFileNames() {
        let track = Track(id: "local:ABC", title: "Purple Rain", artist: "Prince",
                          thumbnailURL: nil, duration: 213)
        let text = M3UPlaylist.write(tracks: [track]) { _ in "purple.flac" }
        XCTAssertTrue(text.hasPrefix("#EXTM3U\n"))
        XCTAssertTrue(text.contains("#EXTINF:213,Prince - Purple Rain"))
        XCTAssertTrue(text.contains("\npurple.flac\n"))
    }

    func test_write_unknownDuration_usesMinusOne_andFallsBackToID() {
        let track = Track(id: "vid00000001", title: "T", artist: "A", thumbnailURL: nil)
        let text = M3UPlaylist.write(tracks: [track]) { _ in nil }
        XCTAssertTrue(text.contains("#EXTINF:-1,A - T"))
        XCTAssertTrue(text.contains("\nvid00000001\n"), "non-file tracks keep their identity")
    }

    func test_roundTrip_exportThenImportResolvesSameTracks() throws {
        let lib = [local("One", artist: "A", fileName: "one.flac"),
                   local("Two", artist: "B", fileName: "two.mp3")]
        let exported = M3UPlaylist.write(
            tracks: lib.map { $0.asPlayerTrack(fileURL: url($0)) },
            fileName: { t in lib.first { "local:\($0.id.uuidString)" == t.id }?.fileName }
        )
        let entries = try M3UPlaylist.parse(exported)
        let (tracks, unmatched) = M3UPlaylist.resolve(entries: entries,
                                                      libraryTracks: lib, fileURL: url)
        XCTAssertEqual(tracks.map(\.title), ["One", "Two"])
        XCTAssertTrue(unmatched.isEmpty)
    }
}
