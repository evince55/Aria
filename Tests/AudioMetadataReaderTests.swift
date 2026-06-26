import XCTest
@testable import Aria___Music_Browser

final class AudioMetadataReaderTests: XCTestCase {

    private var sampleDataDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("AriaLibrary.sampleData")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        // All sample-data-dependent tests skip if fixtures aren't present.
        // The fixtures live in `LocalLibraryManager.sampleData/` (gitignored)
        // and are NOT shipped with the repo. Generate them with:
        //   ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -ac 2 -ar 44100 \
        //     -c:a flac sample-flac-16-44.flac
        //   ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -ac 2 -ar 44100 \
        //     -b:a 320k sample-mp3-320.mp3
        //   ffmpeg -f lavfi -i "sine=frequency=440:duration=1" -ac 2 -ar 96000 \
        //     -sample_fmt s32 -c:a flac sample-flac-24-96.flac
    }

    func test_readAll_unreadableURL_returnsNilNil() async {
        let url = URL(fileURLWithPath: "/nonexistent.flac")
        let (format, quality) = await AudioMetadataReader.readAll(at: url)
        XCTAssertNil(format)
        XCTAssertNil(quality)
    }

    func test_readAll_flac16_44_returnsLosslessFormatAndQuality() async throws {
        guard let url = findFile(named: "sample-flac-16-44.flac") else {
            throw XCTSkip("sample-flac-16-44.flac not present in AriaLibrary.sampleData")
        }
        let (format, quality) = await AudioMetadataReader.readAll(at: url)
        XCTAssertEqual(format?.codec, "FLAC")
        XCTAssertEqual(format?.lossless, true)
        XCTAssertEqual(quality?.bitDepth, 16)
        XCTAssertEqual(quality?.sampleRateHz, 44100)
        XCTAssertNil(quality?.bitrateKbps)
    }

    func test_readAll_mp3_320_returnsLossyFormatAndBitrate() async throws {
        guard let url = findFile(named: "sample-mp3-320.mp3") else {
            throw XCTSkip("sample-mp3-320.mp3 not present in AriaLibrary.sampleData")
        }
        let (format, quality) = await AudioMetadataReader.readAll(at: url)
        XCTAssertEqual(format?.codec, "MP3")
        XCTAssertEqual(format?.lossless, false)
        XCTAssertEqual(quality?.bitrateKbps, 320)
        XCTAssertNil(quality?.bitDepth)
    }

    func test_readAll_flac24_96_marksIsHiRes() async throws {
        guard let url = findFile(named: "sample-flac-24-96.flac") else {
            throw XCTSkip("sample-flac-24-96.flac not present in AriaLibrary.sampleData")
        }
        let (_, quality) = await AudioMetadataReader.readAll(at: url)
        XCTAssertEqual(quality?.bitDepth, 24)
        XCTAssertEqual(quality?.sampleRateHz, 96000)
        XCTAssertEqual(quality?.isHiRes, true)
    }

    private func findFile(named: String) -> URL? {
        let candidate = sampleDataDir.appendingPathComponent(named)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
