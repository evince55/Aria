import XCTest
@testable import Aria___Music_Browser

final class YouTubeThumbnailRewriterTests: XCTestCase {
    private let base = URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/default.jpg")!

    private func firstVariant(_ targetSize: CGFloat) -> String? {
        YouTubeThumbnailRewriter.upgradedURLs(for: base, targetSize: targetSize)
            .first?.deletingPathExtension().lastPathComponent
    }

    func test_smallRowPullsMqdefault() {
        XCTAssertEqual(firstVariant(48), "mqdefault")
    }

    func test_mediumPullsHqdefault() {
        XCTAssertEqual(firstVariant(130), "hqdefault")
    }

    func test_largeHeroPullsSddefault() {
        XCTAssertEqual(firstVariant(180), "sddefault")
    }

    func test_fullScreenPullsMaxres() {
        XCTAssertEqual(firstVariant(290), "maxresdefault")
    }

    func test_alwaysAppendsHqdefaultFallback() {
        let urls = YouTubeThumbnailRewriter.upgradedURLs(for: base, targetSize: 290)
        XCTAssertEqual(urls.last?.deletingPathExtension().lastPathComponent, "hqdefault")
    }

    func test_zeroTargetKeepsLegacyMaxresFirst() {
        XCTAssertEqual(firstVariant(0), "maxresdefault")
    }

    func test_nonYouTubeURLUnchanged() {
        let other = URL(string: "https://example.com/cover.jpg")!
        XCTAssertEqual(YouTubeThumbnailRewriter.upgradedURLs(for: other, targetSize: 48), [other])
    }
}

final class TrackAlbumCodableTests: XCTestCase {
    func test_albumRoundTrips() throws {
        let track = Track(id: "a", title: "T", artist: "A", duration: 200, album: "Greatest Hits")
        let data = try JSONEncoder().encode(track)
        let back = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(back.album, "Greatest Hits")
        XCTAssertEqual(back.duration, 200)
    }

    func test_legacyJSONWithoutAlbumDecodesToNil() throws {
        let legacy = #"{"id":"a","title":"T","artist":"A","isMissing":false}"#.data(using: .utf8)!
        let back = try JSONDecoder().decode(Track.self, from: legacy)
        XCTAssertNil(back.album)
    }

    func test_asPlayerTrackCarriesDurationAndAlbum() {
        let local = LocalTrack(
            id: UUID(),
            title: "Song",
            artist: "Artist",
            artworkFileName: nil,
            fileName: "x.mp3",
            importedAt: Date(),
            fileSizeBytes: 1024,
            durationSeconds: 215,
            album: "The Album"
        )
        let track = local.asPlayerTrack(fileURL: URL(fileURLWithPath: "/tmp/x.mp3"))
        XCTAssertEqual(track.duration, 215)
        XCTAssertEqual(track.album, "The Album")
    }
}
