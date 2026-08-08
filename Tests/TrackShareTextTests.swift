import XCTest
@testable import Aria___Music_Browser

/// Share must never emit a URL. The old behaviour built a
/// `youtube.com/watch?v=<id>` link from the track id, which was wrong for
/// every source that isn't a YouTube video — and would have produced a
/// nonsense link for Subsonic ids, whose real stream URL carries an auth
/// token that must never leave the device.
final class TrackShareTextTests: XCTestCase {

    func test_shareText_isTitleAndArtist() {
        let track = Track(id: "dQw4w9WgXcQ", title: "Song", artist: "Artist", thumbnailURL: nil)
        XCTAssertEqual(track.shareText, "Song — Artist")
    }

    func test_shareText_isTheSameShapeForEverySource() {
        let local = Track(
            id: "local:9F2C1D34-0000-0000-0000-000000000000",
            title: "Song", artist: "Artist",
            thumbnailURL: nil,
            localFileURL: URL(fileURLWithPath: "/tmp/song.flac")
        )
        let subsonic = Track(id: "subsonic:abc123", title: "Song", artist: "Artist", thumbnailURL: nil)
        let streamed = Track(id: "dQw4w9WgXcQ", title: "Song", artist: "Artist", thumbnailURL: nil)

        for track in [local, subsonic, streamed] {
            XCTAssertEqual(track.shareText, "Song — Artist")
            XCTAssertFalse(track.shareText.contains("http"),
                           "share output must never contain a link")
            XCTAssertFalse(track.shareText.contains(track.id),
                           "share output must never leak the track id")
        }
    }

    func test_shareText_carriesUnknownArtistRatherThanGoingBlank() {
        let track = Track(id: "x", title: "Song", artist: "", thumbnailURL: nil)
        XCTAssertEqual(track.shareText, "Song — ")
    }
}
