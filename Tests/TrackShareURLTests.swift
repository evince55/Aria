import XCTest
@testable import Aria___Music_Browser

final class TrackShareURLTests: XCTestCase {

    func test_streamedTrack_sharesWatchURL() {
        let track = Track(id: "dQw4w9WgXcQ", title: "Song", artist: "Artist", thumbnailURL: nil)
        XCTAssertEqual(track.shareURL?.absoluteString, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
    }

    func test_localTrack_hasNoShareURL() {
        let local = Track(
            id: "local:9F2C1D34-0000-0000-0000-000000000000",
            title: "Song", artist: "Artist",
            thumbnailURL: nil,
            localFileURL: URL(fileURLWithPath: "/tmp/song.flac")
        )
        XCTAssertNil(local.shareURL)
    }

    /// Defensive: even if a local track lost its file URL (missing file), the
    /// `local:` id prefix alone must still prevent a bogus YouTube link.
    func test_localIDPrefixAloneBlocksShareURL() {
        let track = Track(id: "local:ABC", title: "Song", artist: "Artist", thumbnailURL: nil)
        XCTAssertNil(track.shareURL)
    }
}
