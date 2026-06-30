import Foundation

/// On-disk snapshot of the player's session so "Up Next" and the now-playing
/// track survive a relaunch (routine iOS eviction otherwise wipes them).
///
/// Restored into a *paused* state on launch — never auto-resumes audio. The
/// first user play seeks to `positionSeconds` so the track picks up where it
/// left off. Carries its own `schemaVersion` for the same forward-compat
/// reason the array stores do (see `VersionedEnvelope`).
struct PersistedPlayback: Codable, Equatable {
    var schemaVersion: Int
    var currentTrack: Track?
    var queue: [Track]
    var positionSeconds: Double
    var durationSeconds: Double

    init(
        schemaVersion: Int,
        currentTrack: Track?,
        queue: [Track],
        positionSeconds: Double,
        durationSeconds: Double
    ) {
        self.schemaVersion = schemaVersion
        self.currentTrack = currentTrack
        self.queue = queue
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }

    /// True when there's nothing worth restoring (no track and an empty queue).
    var isEmpty: Bool { currentTrack == nil && queue.isEmpty }
}
