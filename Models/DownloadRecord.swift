import Foundation

/// A track saved for offline playback. Keyed by YouTube `videoID`; the audio
/// bytes live at `Downloads/<fileName>` in the app sandbox. Title/artist/thumb
/// are snapshotted so the Library can render downloaded rows with no network.
struct DownloadRecord: Codable, Identifiable, Hashable {
    let videoID: String
    let fileName: String
    let sizeBytes: Int64
    let downloadedAt: Date
    let title: String
    let artist: String
    let thumbnailURL: URL?
    /// Audio length in seconds, probed from the downloaded file. Optional with a
    /// `nil` default so records persisted before schema v2 decode without a
    /// migration and so `download()` can set it after writing the file. Feeds a
    /// truthful bitrate on the download's quality badge.
    var durationSeconds: Double? = nil

    var id: String { videoID }

    /// Reconstruct a playable `Track` for the Library section. It keeps the
    /// YouTube identity, so `PlayerManager` prefers the local copy at play time.
    var asTrack: Track {
        Track(id: videoID, title: title, artist: artist, thumbnailURL: thumbnailURL, duration: durationSeconds)
    }
}

/// UI-facing state for a track's download, used by `DownloadButton` and rows.
enum DownloadState: Equatable {
    case none
    case downloading
    case downloaded
}
