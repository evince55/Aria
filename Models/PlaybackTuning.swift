import Foundation

/// The rules for the Speed & Pitch controls: ranges, step sizes, and how the two
/// values combine. Pure, so it can be tested without a player.
enum PlaybackTuning {
    static let speedRange: ClosedRange<Float> = 0.5...2.0
    static let speedStep: Float = 0.01
    static let defaultSpeed: Float = 1.0

    /// Semitones, as an offset on top of the change speed causes.
    static let pitchRange: ClosedRange<Float> = -12...12
    static let pitchStep: Float = 0.1
    static let defaultPitch: Float = 0

    /// Clamps to the range and rounds to a whole step, so sliders and stepping
    /// buttons can't accumulate float error (0.75 stays exactly `speed(0.75)`).
    static func speed(_ value: Float) -> Float { snap(value, to: speedStep, in: speedRange) }
    static func pitch(_ value: Float) -> Float { snap(value, to: pitchStep, in: pitchRange) }

    /// How far the result sounds from the original recording, in semitones.
    /// Speed moves pitch by 12 semitones per octave of rate; the offset adds on.
    static func netSemitones(speed: Float, pitch: Float) -> Float {
        12 * log2(speed) + pitch
    }

    private static func snap(_ value: Float, to step: Float, in range: ClosedRange<Float>) -> Float {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        // Via whole steps per unit: 75 / 100 is exactly 0.75, 75 * 0.01 isn't.
        let stepsPerUnit = (1 / step).rounded()
        return (clamped * stepsPerUnit).rounded() / stepsPerUnit
    }
}
