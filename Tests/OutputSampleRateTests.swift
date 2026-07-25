import AVFoundation
import XCTest
@testable import Aria___Music_Browser

/// iOS honors only 44.1/48 kHz for output, so the job is choosing the right
/// FAMILY (44.1 vs 48) for a given source — see
/// docs/design/2026-07-25-bit-perfect-dac-assessment.md.
final class OutputSampleRateTests: XCTestCase {

    func test_exactRates_mapToThemselves() {
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 44_100), 44_100)
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 48_000), 48_000)
    }

    func test_multiplesStayInTheirFamily() {
        // 88.2/176.4 are 44.1 multiples — must NOT be pulled to 48 kHz even
        // though 96 kHz is numerically closer to 88.2 than 44.1 is.
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 88_200), 44_100)
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 176_400), 44_100)
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 96_000), 48_000)
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 192_000), 48_000)
    }

    func test_lowRates_cleanDivisorsKeepTheirFamily() {
        // Exact divisors: 44100/22050 = 2, 48000/24000 = 2.
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 22_050), 44_100)
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 24_000), 48_000)
    }

    func test_rateInNeitherFamily_fallsBackToNearestBase() {
        // 32 kHz is NOT a clean divisor of either base (48/32 = 1.5), so there's
        // no "clean" family to preserve and the nearer base wins. 44.1 is
        // 12.1 kHz away, 48 is 16 kHz away.
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 32_000), 44_100)
        // Likewise for an oddball rate with no clean relationship either way.
        XCTAssertEqual(OutputSampleRate.preferredRate(forSource: 47_000), 48_000)
    }

    func test_unknownOrInvalidRate_returnsNil() {
        XCTAssertNil(OutputSampleRate.preferredRate(forSource: 0))
        XCTAssertNil(OutputSampleRate.preferredRate(forSource: -44_100))
    }

    func test_supportedRates_areTheOnlyOutputs() {
        // Whatever the source, the answer is always a rate iOS actually honors.
        for source in [8_000.0, 11_025, 44_100, 48_000, 64_000, 88_200, 96_000, 192_000, 384_000] {
            let rate = OutputSampleRate.preferredRate(forSource: source)
            XCTAssertNotNil(rate)
            XCTAssertTrue(OutputSampleRate.supported.contains(rate!),
                          "\(source) Hz produced unsupported \(rate!) Hz")
        }
    }

    func test_sourceRate_readsAssetFormat() async throws {
        // Build a real 44.1 kHz file and read its rate back through the same
        // path playback uses.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rate-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        try file.write(from: buffer)

        let rate = await OutputSampleRate.sourceRate(of: AVURLAsset(url: url))
        XCTAssertEqual(rate ?? 0, 44_100, accuracy: 1)
    }
}
