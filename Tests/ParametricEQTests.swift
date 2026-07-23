import XCTest
import AVFoundation
@testable import Aria___Music_Browser

/// Model, controller, and render coverage for the parametric EQ (Pro).
final class ParametricEQTests: XCTestCase {

    private func preset(_ bands: [ParametricBand], preamp: Float = 0) -> ParametricEQPreset {
        ParametricEQPreset(name: "test", preamp: preamp, bands: bands)
    }

    // MARK: - Q → bandwidth conversion

    func test_bandwidthOctaves_standardValues() {
        // BW = (2/ln2)·asinh(1/(2Q)): Q 0.7 ≈ 1.92 oct, Q 1.41 ≈ 1.0 oct.
        let wide = ParametricBand(type: .peak, frequency: 1000, gain: 0, q: 0.7)
        XCTAssertEqual(wide.bandwidthOctaves, 1.917, accuracy: 0.01)
        let unit = ParametricBand(type: .peak, frequency: 1000, gain: 0, q: 1.41)
        XCTAssertEqual(unit.bandwidthOctaves, 1.0, accuracy: 0.01)
    }

    func test_bandwidthOctaves_zeroQ_fallsBackToDefault() {
        let b = ParametricBand(type: .peak, frequency: 1000, gain: 0, q: 0)
        XCTAssertEqual(b.bandwidthOctaves, 0.5)
    }

    // MARK: - Codable

    func test_preset_codableRoundTrip() throws {
        let original = preset([
            ParametricBand(type: .peak, frequency: 105, gain: -4.9, q: 0.7),
            ParametricBand(type: .lowShelf, frequency: 80, gain: 2, q: 0.7),
            ParametricBand(type: .highShelf, frequency: 10_000, gain: -3.2, q: 0.7),
        ], preamp: -6.4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ParametricEQPreset.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - EQController parametric mode

    func test_setParametric_enablesAndPublishes() {
        let eq = EQController()
        let outcome = eq.setParametric(preset([ParametricBand(type: .peak, frequency: 100, gain: 3, q: 1)]))
        XCTAssertEqual(outcome, .becameEnabled)
        XCTAssertTrue(eq.isEnabled)
        XCTAssertNotNil(eq.parametric)
    }

    func test_apply_isNoOpWhileParametricActive() {
        let eq = EQController()
        eq.setParametric(preset([ParametricBand(type: .peak, frequency: 100, gain: 3, q: 1)]))
        let outcome = eq.apply([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(outcome, .noChange, "graphic edits are dormant in parametric mode")
        XCTAssertEqual(eq.bands, Array(repeating: 0, count: 10))
    }

    func test_clearParametric_fallsBackToGraphicState() {
        let eq = EQController()
        eq.apply([3, 0, 0, 0, 0, 0, 0, 0, 0, 0])   // non-flat graphic
        eq.setParametric(preset([ParametricBand(type: .peak, frequency: 100, gain: 3, q: 1)]))
        let outcome = eq.clearParametric()
        XCTAssertEqual(outcome, .stillEnabled, "non-flat graphic bands keep EQ on")
        XCTAssertNil(eq.parametric)

        let eq2 = EQController()
        eq2.setParametric(preset([ParametricBand(type: .peak, frequency: 100, gain: 3, q: 1)]))
        XCTAssertEqual(eq2.clearParametric(), .becameDisabled, "flat graphic bands turn EQ off")
    }

    func test_reset_clearsParametricToo() {
        let eq = EQController()
        eq.setParametric(preset([ParametricBand(type: .peak, frequency: 100, gain: 3, q: 1)]))
        XCTAssertTrue(eq.reset())
        XCTAssertNil(eq.parametric)
        XCTAssertFalse(eq.isEnabled)
    }

    func test_persistence_roundTripsThroughStore() {
        let store = InMemoryKeyValueStore()
        let eq = EQController(store: store)
        let p = preset([ParametricBand(type: .highShelf, frequency: 8000, gain: -2, q: 0.7)], preamp: -1.5)
        eq.setParametric(p)
        eq.flushPendingWrites()

        let revived = EQController(store: store)
        XCTAssertEqual(revived.parametric, p)
        XCTAssertTrue(revived.isEnabled, "restored parametric preset must re-enable EQ")
    }

    func test_persistence_restoresGraphicBands() {
        let store = InMemoryKeyValueStore()
        let eq = EQController(store: store)
        eq.apply([2, 0, 0, 0, 0, 0, 0, 0, -3, 0])
        eq.flushPendingWrites()

        let revived = EQController(store: store)
        XCTAssertEqual(revived.bands[0], 2)
        XCTAssertEqual(revived.bands[8], -3)
        XCTAssertTrue(revived.isEnabled)
    }

    // MARK: - AudioEQ render smoke

    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!

    private func makeBuffer(frames: AVAudioFrameCount, _ sample: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for f in 0..<Int(frames) { p[f] = sample(ch, f) }
        }
        return buf
    }

    private func energy(_ buf: AVAudioPCMBuffer) -> Float {
        var e: Float = 0
        let p = buf.floatChannelData![0]
        for f in 0..<Int(buf.frameLength) { e += p[f] * p[f] }
        return e
    }

    /// `startTime` must advance between renders on the SAME AudioEQ instance —
    /// AudioUnits short-circuit a non-advancing timestamp to silence. (The live
    /// tap advances its sample clock monotonically for the same reason.)
    private func render(_ eq: AudioEQ, _ src: AVAudioPCMBuffer,
                        startTime: Float64 = 0) throws -> AVAudioPCMBuffer {
        let out = makeBuffer(frames: src.frameLength) { _, _ in 0 }
        var ts = AudioTimeStamp(); ts.mSampleTime = startTime; ts.mFlags = .sampleTimeValid
        let status = eq.process(source: src.audioBufferList,
                                output: out.mutableAudioBufferList,
                                frames: src.frameLength, timeStamp: ts)
        XCTAssertEqual(status, noErr, "AudioUnitRender failed: \(status)")
        return out
    }

    func test_parametricBoostAtToneFrequency_increasesEnergy() throws {
        let frames: AVAudioFrameCount = 4096
        let tone: Float = 1000
        let src = makeBuffer(frames: frames) { _, f in sinf(2 * .pi * tone * Float(f) / 44100) * 0.5 }

        let flat = AudioEQ()
        try flat.prepare(format: format.streamDescription.pointee,
                         frequencies: PlayerManager.eqFrequencies)
        let flatOut = try render(flat, src)

        let boosted = AudioEQ()
        try boosted.prepare(format: format.streamDescription.pointee,
                            frequencies: PlayerManager.eqFrequencies)
        boosted.applyParametric(ParametricEQPreset(
            name: "boost", preamp: 0,
            bands: [ParametricBand(type: .peak, frequency: tone, gain: 12, q: 1.0)]))
        let boostOut = try render(boosted, src)

        XCTAssertGreaterThan(energy(boostOut), energy(flatOut) * 1.5,
                             "a +12 dB parametric peak at the tone frequency should raise energy")
    }

    func test_parametricThenGraphicRestore_returnsToUnity() throws {
        let frames: AVAudioFrameCount = 4096
        let tone: Float = 1000
        let src = makeBuffer(frames: frames) { _, f in sinf(2 * .pi * tone * Float(f) / 44100) * 0.5 }

        let eq = AudioEQ()
        try eq.prepare(format: format.streamDescription.pointee,
                       frequencies: PlayerManager.eqFrequencies)
        eq.applyParametric(ParametricEQPreset(
            name: "cut", preamp: -6,
            bands: [ParametricBand(type: .peak, frequency: tone, gain: -12, q: 1.0)]))
        _ = try render(eq, src)

        // Back to flat graphic — energy should be comparable to input again.
        eq.applyGraphic(frequencies: PlayerManager.eqFrequencies,
                        gains: Array(repeating: 0, count: 10))
        let restored = try render(eq, src, startTime: Float64(frames))
        let ein = energy(src), eout = energy(restored)
        XCTAssertGreaterThan(eout, ein * 0.4, "graphic restore shouldn't keep the parametric cut")
        XCTAssertLessThan(eout, ein * 2.5)
    }
}
