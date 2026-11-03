import XCTest
@testable import Aria___Music_Browser

/// iOS moves the app's Data container to a new UUID on reinstall and update, so
/// a `file:` URL saved by an earlier install points at a folder that's gone.
/// Every persisted `Track` must come back pointing at the current container.
@MainActor
final class TrackContainerPathTests: XCTestCase {
    private let staleContainer = "/var/mobile/Containers/Data/Application/00000000-0000-0000-0000-000000000000"

    private func decodeTrack(localFile: String?, thumbnail: String? = nil) throws -> Track {
        var json: [String: String] = ["id": "local:abc", "title": "T", "artist": "A"]
        json["localFileURL"] = localFile
        json["thumbnailURL"] = thumbnail
        return try JSONDecoder().decode(Track.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func test_decode_stalePaths_movedToCurrentContainer() throws {
        let track = try decodeTrack(
            localFile: "file://\(staleContainer)/Documents/AriaLibrary/song.mp3",
            thumbnail: "file://\(staleContainer)/Documents/AriaLibrary/artwork/song.jpg"
        )

        XCTAssertEqual(track.localFileURL?.path, NSHomeDirectory() + "/Documents/AriaLibrary/song.mp3")
        XCTAssertEqual(track.thumbnailURL?.path, NSHomeDirectory() + "/Documents/AriaLibrary/artwork/song.jpg")
    }

    func test_decode_stalePathWithEscapedCharacters_keepsFileName() throws {
        let track = try decodeTrack(localFile: "file://\(staleContainer)/Documents/My%20Song.mp3")

        XCTAssertEqual(track.localFileURL?.path, NSHomeDirectory() + "/Documents/My Song.mp3")
    }

    func test_decode_currentContainerPath_isUnchanged() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Documents/AriaLibrary/song.mp3", isDirectory: false)
        let track = try decodeTrack(localFile: url.absoluteString)

        XCTAssertEqual(track.localFileURL, url)
    }

    func test_decode_pathOutsideAppContainer_isUnchanged() throws {
        let track = try decodeTrack(localFile: "file:///tmp/song.mp3")

        XCTAssertEqual(track.localFileURL?.path, "/tmp/song.mp3")
    }

    func test_decode_remoteArtwork_isUnchanged() throws {
        let remote = "https://example.com/Containers/Data/Application/abc/cover.jpg"
        let track = try decodeTrack(localFile: nil, thumbnail: remote)

        XCTAssertEqual(track.thumbnailURL?.absoluteString, remote)
        XCTAssertNil(track.localFileURL)
    }

    /// The reported symptom end to end: a session saved by an earlier install
    /// resumes instead of reporting "That file is missing".
    func test_restoredSession_fromEarlierInstall_findsTheFile() throws {
        let name = "container_test_\(UUID().uuidString).mp3"
        let current = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: current)
        defer { try? FileManager.default.removeItem(at: current) }

        let stale = "file://\(staleContainer)/Documents/\(name)"
        let saved: [String: Any] = [
            "schemaVersion": PlayerManager.playbackSchemaVersion,
            "currentTrack": ["id": "local:abc", "title": "T", "artist": "A", "localFileURL": stale],
            "queue": [],
            "positionSeconds": 0,
            "durationSeconds": 0,
        ]
        let store = InMemoryKeyValueStore()
        try store.save(JSONSerialization.data(withJSONObject: saved))
        let player = PlayerManager(urlSession: MockURLSession(), playbackStore: store)

        player.togglePlayPause()

        XCTAssertNil(player.playerError)
        XCTAssertEqual(player.currentStreamURL?.path, current.path)
    }
}
