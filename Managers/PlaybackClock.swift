import Foundation
import Combine

/// Holds *only* the high-frequency playback position and the current track
/// length. Split out of `PlayerManager` so the periodic time observer
/// re-renders just the views that show the clock (the full-screen player's
/// scrubber) instead of every view that observes the much larger
/// `PlayerManager`.
///
/// `PlayerManager` owns one of these and exposes `currentTime` / `duration`
/// as plain (non-`@Published`) forwarders, so existing call sites keep working
/// while time ticks no longer fire `PlayerManager.objectWillChange`.
final class PlaybackClock: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    func reset() {
        currentTime = 0
        duration = 0
    }
}
