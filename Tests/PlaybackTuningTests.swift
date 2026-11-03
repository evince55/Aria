import XCTest
@testable import Aria___Music_Browser

final class PlaybackTuningTests: XCTestCase {

    func test_valuesClampToTheirRanges() {
        XCTAssertEqual(PlaybackTuning.speed(5), 2.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackTuning.speed(0.1), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PlaybackTuning.pitch(40), 12, accuracy: 0.0001)
        XCTAssertEqual(PlaybackTuning.pitch(-40), -12, accuracy: 0.0001)
    }

    func test_valuesRoundToWholeSteps() {
        XCTAssertEqual(PlaybackTuning.speed(0.754), 0.75, accuracy: 0.0001)
        XCTAssertEqual(PlaybackTuning.pitch(2.04), 2.0, accuracy: 0.0001)
    }

    func test_steppingManyTimesDoesNotDrift() {
        // The +/- buttons repeatedly add a step to the current value.
        var pitch: Float = 0
        for _ in 0..<50 { pitch = PlaybackTuning.pitch(pitch + PlaybackTuning.pitchStep) }
        XCTAssertEqual(pitch, 5.0, accuracy: 0.001)
        for _ in 0..<50 { pitch = PlaybackTuning.pitch(pitch - PlaybackTuning.pitchStep) }
        XCTAssertEqual(pitch, 0, "back at zero must be exactly zero: 0 is what turns the shifter off")
    }

    func test_netSemitones_speedMovesPitchLikeARecord() {
        XCTAssertEqual(PlaybackTuning.netSemitones(speed: 1, pitch: 0), 0, accuracy: 0.001)
        XCTAssertEqual(PlaybackTuning.netSemitones(speed: 0.5, pitch: 0), -12, accuracy: 0.001)
        XCTAssertEqual(PlaybackTuning.netSemitones(speed: 2, pitch: 0), 12, accuracy: 0.001)
        XCTAssertEqual(PlaybackTuning.netSemitones(speed: 0.75, pitch: 0), -4.98, accuracy: 0.01)
    }

    func test_netSemitones_pitchOffsetAddsOnTop() {
        // +12 at half speed cancels out: slower, at the original pitch.
        XCTAssertEqual(PlaybackTuning.netSemitones(speed: 0.5, pitch: 12), 0, accuracy: 0.001)
    }
}
