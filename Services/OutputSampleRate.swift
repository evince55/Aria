import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "OutputSampleRate")

/// Matches the audio session's output sample rate to the track being played.
///
/// iOS routes every app through a fixed-rate system mixer and honors only
/// 44.1 kHz and 48 kHz on the output side — `setPreferredSampleRate` is a hint
/// and higher rates are silently ignored (see
/// `docs/design/2026-07-25-bit-perfect-dac-assessment.md`). True hi-res
/// bit-perfect output is therefore impossible on iOS, in any app.
///
/// What IS achievable, and what this does: pick the honored rate in the SAME
/// FAMILY as the source so the OS doesn't resample unnecessarily. A 44.1 kHz
/// album played while the session sits at 48 kHz gets converted for no reason;
/// requesting 44.1 removes that step. Multiples of 44.1 (88.2/176.4) map to
/// 44.1; multiples of 48 (96/192) map to 48.
enum OutputSampleRate {
    /// The only rates iOS actually honors for output.
    static let supported: [Double] = [44_100, 48_000]

    /// Honored rate for `sourceRate`, chosen by FAMILY (44.1 vs 48) rather than
    /// absolute distance: 88.2 kHz belongs to the 44.1 family even though
    /// 96 kHz is numerically closer to it than 44.1 is, because 88.2 → 44.1 is
    /// a clean 2:1 decimation while 88.2 → 48 is a messy ratio.
    ///
    /// A source is "in a family" when it's a clean integer multiple OR divisor
    /// of that family's base (so 22.05/88.2/176.4 → 44.1; 24/32/96/192 → 48).
    /// Anything else falls back to whichever base is numerically nearer.
    /// Returns nil for a non-positive/unknown rate (caller leaves the session alone).
    static func preferredRate(forSource sourceRate: Double) -> Double? {
        guard sourceRate > 0 else { return nil }
        let inFourtyFour = isCleanlyRelated(sourceRate, to: 44_100)
        let inFourtyEight = isCleanlyRelated(sourceRate, to: 48_000)
        if inFourtyFour && !inFourtyEight { return 44_100 }
        if inFourtyEight && !inFourtyFour { return 48_000 }
        // Both (e.g. an exact base) or neither → nearest base wins.
        return abs(sourceRate - 44_100) <= abs(sourceRate - 48_000) ? 44_100 : 48_000
    }

    /// True when `rate` is an integer multiple or an integer divisor of `base`
    /// (within a rounding tolerance), i.e. resampling between them is a clean
    /// power-of-two-ish ratio rather than an arbitrary conversion.
    private static func isCleanlyRelated(_ rate: Double, to base: Double) -> Bool {
        let tolerance = 1.0
        let up = rate / base                      // 88_200 / 44_100 = 2
        if abs(up - up.rounded()) * base < tolerance, up.rounded() >= 1 { return true }
        let down = base / rate                    // 48_000 / 24_000 = 2
        if abs(down - down.rounded()) * rate < tolerance, down.rounded() >= 1 { return true }
        return false
    }

    /// Reads the asset's audio sample rate, if it exposes one.
    static func sourceRate(of asset: AVAsset) async -> Double? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions) as [CMFormatDescription]?,
              let first = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee
        else { return nil }
        return asbd.mSampleRate > 0 ? asbd.mSampleRate : nil
    }

    /// Requests the matching rate on the shared session. Best-effort: iOS may
    /// refuse (another app owns the route, hardware disagrees), which is fine —
    /// playback continues at whatever rate the system picks.
    static func apply(forSource sourceRate: Double,
                      session: AVAudioSession = .sharedInstance()) {
        guard let target = preferredRate(forSource: sourceRate) else { return }
        guard abs(session.sampleRate - target) > 1 else { return }  // already there
        do {
            try session.setPreferredSampleRate(target)
            log.notice("requested \(target, privacy: .public) Hz for \(sourceRate, privacy: .public) Hz source (session now \(session.sampleRate, privacy: .public) Hz)")
        } catch {
            log.debug("sample-rate request refused: \(error.localizedDescription, privacy: .public)")
        }
    }
}
