import XCTest
@testable import Aria___Music_Browser

/// Pure-function coverage for `AudioQuality.forFile`, the badge model.
final class AudioQualityTests: XCTestCase {

    func test_flac_isLosslessAndNamed() {
        let q = AudioQuality.forFile(fileName: "song.flac", sizeBytes: 50_000_000, durationSeconds: 200)
        XCTAssertEqual(q.category, .lossless)
        XCTAssertTrue(q.isLossless)
        XCTAssertEqual(q.display, "FLAC")
    }

    func test_wavAndAlac_lossless() {
        XCTAssertEqual(AudioQuality.forFile(fileName: "a.wav", sizeBytes: 1, durationSeconds: 1).display, "WAV")
        XCTAssertEqual(AudioQuality.forFile(fileName: "a.alac", sizeBytes: 1, durationSeconds: 1).display, "ALAC")
        // AIFF collapses to a generic "Lossless" label.
        XCTAssertEqual(AudioQuality.forFile(fileName: "a.aiff", sizeBytes: 1, durationSeconds: 1).display, "Lossless")
    }

    func test_lossy_withDuration_computesKbpsTier() {
        // 320 kbps over 100 s = 320_000 bits/s * 100 / 8 = 4_000_000 bytes.
        let q = AudioQuality.forFile(fileName: "track.mp3", sizeBytes: 4_000_000, durationSeconds: 100)
        XCTAssertEqual(q.category, .lossy)
        XCTAssertFalse(q.isLossless)
        XCTAssertEqual(q.display, "MP3 320")
    }

    func test_aac_kbpsTier() {
        // 256 kbps over 100 s = 3_200_000 bytes.
        let q = AudioQuality.forFile(fileName: "track.m4a", sizeBytes: 3_200_000, durationSeconds: 100)
        XCTAssertEqual(q.display, "AAC 256")
    }

    func test_highBitrate_m4a_treatedAsALAC() {
        // ~900 kbps over 100 s = 11_250_000 bytes. AAC never reaches this, so an
        // .m4a at this bitrate is really Apple Lossless.
        let q = AudioQuality.forFile(fileName: "track.m4a", sizeBytes: 11_250_000, durationSeconds: 100)
        XCTAssertEqual(q.category, .lossless)
        XCTAssertEqual(q.display, "ALAC")
    }

    func test_lossy_nilDuration_codecOnly() {
        let q = AudioQuality.forFile(fileName: "track.mp3", sizeBytes: 4_000_000, durationSeconds: nil)
        XCTAssertEqual(q.category, .lossy)
        XCTAssertEqual(q.display, "MP3")
    }

    func test_lossy_zeroDuration_codecOnly() {
        let q = AudioQuality.forFile(fileName: "track.opus", sizeBytes: 4_000_000, durationSeconds: 0)
        XCTAssertEqual(q.category, .lossy)
        XCTAssertEqual(q.display, "Opus")
    }

    func test_unknownExtension_unknown() {
        let q = AudioQuality.forFile(fileName: "track.xyz", sizeBytes: 1000, durationSeconds: 100)
        XCTAssertEqual(q.category, .unknown)
        XCTAssertEqual(q.display, "—")
    }

    func test_noExtension_unknown() {
        let q = AudioQuality.forFile(fileName: "track", sizeBytes: 1000, durationSeconds: 100)
        XCTAssertEqual(q.category, .unknown)
    }
}
