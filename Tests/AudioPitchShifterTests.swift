import XCTest
import AVFoundation
@testable import Aria___Music_Browser

/// Pitch shifting has to be proven on real audio: a pure tone goes in, and its
/// energy must come out at the shifted frequency. Same isolation approach as
/// `AudioEQTests` — no player, no tap.
final class AudioPitchShifterTests: XCTestCase {

    private let sampleRate = 44100.0
    private lazy var format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!

    /// Renders `totalFrames` of a sine through `shifter` in `sliceFrames` slices.
    /// Returns channel 0 of the output.
    private func render(_ shifter: AudioPitchShifter, tone hz: Double,
                        totalFrames: Int = 44100, sliceFrames: AVAudioFrameCount = 1024) -> [Float] {
        var phase = 0.0
        var pulled = 0
        let increment = 2 * .pi * hz / sampleRate
        shifter.setSourceProvider { frames, buffers in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for i in 0..<Int(frames) {
                let value = Float(sin(phase + Double(i) * increment)) * 0.5
                for buffer in list { buffer.mData!.assumingMemoryBound(to: Float.self)[i] = value }
            }
            phase += Double(frames) * increment
            pulled += Int(frames)
            return noErr
        }

        var output = [Float]()
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sliceFrames)!
        while output.count < totalFrames {
            buf.frameLength = sliceFrames
            let status = shifter.render(into: buf.mutableAudioBufferList, frames: sliceFrames)
            XCTAssertEqual(status, noErr)
            output.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(sliceFrames)))
        }
        return output
    }

    /// Goertzel power of `signal` at `hz`, skipping the unit's start-up latency.
    private func power(of signal: [Float], at hz: Double) -> Double {
        let tail = signal.suffix(signal.count / 2)
        let coeff = 2 * cos(2 * .pi * hz / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for x in tail { let s = Double(x) + coeff * s1 - s2; s2 = s1; s1 = s }
        return s1 * s1 + s2 * s2 - coeff * s1 * s2
    }

    private func makeShifter(semitones: Float) throws -> AudioPitchShifter {
        let shifter = AudioPitchShifter()
        try shifter.prepare(format: format.streamDescription.pointee, maximumFrames: 8192)
        shifter.setPitch(semitones: semitones)
        return shifter
    }

    func test_upAnOctave_movesTheToneToDoubleItsFrequency() throws {
        let out = render(try makeShifter(semitones: 12), tone: 1000)
        XCTAssertGreaterThan(power(of: out, at: 2000), power(of: out, at: 1000) * 20)
    }

    func test_downAnOctave_movesTheToneToHalfItsFrequency() throws {
        let out = render(try makeShifter(semitones: -12), tone: 1000)
        XCTAssertGreaterThan(power(of: out, at: 500), power(of: out, at: 1000) * 20)
    }

    func test_smallShift_landsOnTheFineValue() throws {
        // Fine control has to mean something: +0.5 st of 1 kHz is 1029.3 Hz.
        let out = render(try makeShifter(semitones: 0.5), tone: 1000)
        XCTAssertGreaterThan(power(of: out, at: 1029.3), power(of: out, at: 1000) * 5)
    }

    func test_consumesSourceAtTheSameRateItProduces() throws {
        // At rate 1 a pitch shift must not change duration, or AVPlayer's clock
        // and the audio would drift apart over a track.
        let shifter = try makeShifter(semitones: 7)
        var pulled = 0
        shifter.setSourceProvider { frames, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                memset(buffer.mData!, 0, Int(buffer.mDataByteSize))
            }
            pulled += Int(frames)
            return noErr
        }
        let slice: AVAudioFrameCount = 1024, slices = 200
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: slice)!
        for _ in 0..<slices {
            buf.frameLength = slice
            XCTAssertEqual(shifter.render(into: buf.mutableAudioBufferList, frames: slice), noErr)
        }
        let produced = Int(slice) * slices
        XCTAssertEqual(Double(pulled), Double(produced), accuracy: Double(produced) * 0.05)
    }

    func test_renderBeforePrepare_failsCleanly() {
        let shifter = AudioPitchShifter()
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        buf.frameLength = 512
        XCTAssertNotEqual(shifter.render(into: buf.mutableAudioBufferList, frames: 512), noErr)
    }
}
