import XCTest
import AVFoundation
@testable import Aria___Music_Browser

final class AudioEQTests: XCTestCase {

    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!

    /// Builds a non-interleaved float buffer filled by `sample(channel, frame)`.
    private func makeBuffer(frames: AVAudioFrameCount,
                            _ sample: (Int, Int) -> Float) -> AVAudioPCMBuffer {
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

    private func render(_ eq: AudioEQ, _ src: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let out = makeBuffer(frames: src.frameLength) { _, _ in 0 }
        var ts = AudioTimeStamp(); ts.mSampleTime = 0; ts.mFlags = .sampleTimeValid
        let status = eq.process(source: src.audioBufferList,
                                output: out.mutableAudioBufferList,
                                frames: src.frameLength, timeStamp: ts)
        XCTAssertEqual(status, noErr, "AudioUnitRender failed: \(status)")
        return out
    }

    private func sine(_ hz: Float, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        makeBuffer(frames: frames) { _, f in sinf(2 * .pi * hz * Float(f) / 44100) * 0.5 }
    }

    /// Issue #73: the EQ hard-coded MaximumFramesPerSlice = 8192, but the tap's
    /// prepare callback reports the real maximum and iOS can exceed 8192 (8208
    /// was observed). Rendering more than the cap fails with
    /// kAudioUnitErr_TooManyFramesToProcess — and the tap ignored the failure,
    /// so that slice played un-EQ'd. The cap must come from the caller.
    func test_rendersSlicesLargerThan8192_whenPreparedWithThatMaximum() throws {
        let frames: AVAudioFrameCount = 8208
        let eq = AudioEQ()
        try eq.prepare(format: format.streamDescription.pointee,
                       frequencies: PlayerManager.eqFrequencies,
                       maximumFrames: frames)

        let out = try render(eq, sine(1000, frames: frames))  // asserts noErr
        let p = out.floatChannelData![0]
        XCTAssertTrue((0..<Int(frames)).allSatisfy { p[$0].isFinite })
    }

    func test_maximumFramesNeverDropsBelowTheOldFloor() throws {
        // A caller reporting a tiny maximum must not shrink the cap below 8192.
        let eq = AudioEQ()
        try eq.prepare(format: format.streamDescription.pointee,
                       frequencies: PlayerManager.eqFrequencies,
                       maximumFrames: 512)
        _ = try render(eq, sine(1000, frames: 4096))  // asserts noErr
    }

    func test_flatEQ_rendersFiniteAudioAndPreservesEnergy() throws {
        let eq = AudioEQ()
        try eq.prepare(format: format.streamDescription.pointee,
                       frequencies: PlayerManager.eqFrequencies)

        let src = sine(1000, frames: 2048)
        let out = try render(eq, src)

        // Every output sample must be finite (no NaN/inf from a broken graph).
        let p = out.floatChannelData![0]
        for f in 0..<Int(out.frameLength) {
            XCTAssertTrue(p[f].isFinite, "non-finite sample at \(f)")
        }
        // Flat EQ is ~unity: output carries comparable energy to the input
        // (lenient bounds tolerate filter edge effects / latency).
        let ein = energy(src), eout = energy(out)
        XCTAssertGreaterThan(eout, ein * 0.4, "flat EQ shouldn't gut the signal")
        XCTAssertLessThan(eout, ein * 2.5, "flat EQ shouldn't amplify the signal")
    }

    func test_boostingBandAtToneFrequency_increasesEnergy() throws {
        let frames: AVAudioFrameCount = 4096
        let tone: Float = 1000  // index 5 in eqFrequencies

        let flat = AudioEQ()
        try flat.prepare(format: format.streamDescription.pointee,
                         frequencies: PlayerManager.eqFrequencies)
        let boosted = AudioEQ()
        try boosted.prepare(format: format.streamDescription.pointee,
                            frequencies: PlayerManager.eqFrequencies)
        boosted.setBand(5, gain: 12)  // +12 dB at 1 kHz

        let src = sine(tone, frames: frames)
        let flatOut = try render(flat, src)
        let boostOut = try render(boosted, src)

        XCTAssertGreaterThan(energy(boostOut), energy(flatOut) * 1.5,
                             "a +12 dB boost at the tone frequency should raise energy")
    }

    func test_bypass_passesThroughWithComparableEnergy() throws {
        let eq = AudioEQ()
        try eq.prepare(format: format.streamDescription.pointee,
                       frequencies: PlayerManager.eqFrequencies)
        eq.setBand(5, gain: 12)
        eq.setBypass(true)

        let src = sine(1000, frames: 2048)
        let out = try render(eq, src)
        // Bypassed: the +12 dB band must NOT take effect.
        XCTAssertLessThan(energy(out), energy(src) * 2.5,
                          "bypass should suppress the boost")
    }
}
