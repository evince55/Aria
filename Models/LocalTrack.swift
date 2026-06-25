import Foundation

/// A track imported from the device's Files app via `UIDocumentPicker`.
///
/// The `id` is a stable UUID assigned at import time. The actual file
/// lives in the app's Documents/AriaLibrary/ directory; the on-disk
/// name is `fileName` (a UUID + extension). The `fileURL(for:)` method
/// on `LocalLibraryManager` reconstructs the absolute path from these
/// pieces.
struct LocalTrack: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let artist: String?
    let artworkURL: URL?
    let fileName: String
    let importedAt: Date
    let fileSizeBytes: Int64
    let durationSeconds: Double?
    let album: String?
    let isMissing: Bool

    init(
        id: UUID,
        title: String,
        artist: String?,
        artworkURL: URL?,
        fileName: String,
        importedAt: Date,
        fileSizeBytes: Int64,
        durationSeconds: Double?,
        album: String? = nil,
        isMissing: Bool = false
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.fileName = fileName
        self.importedAt = importedAt
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.album = album
        self.isMissing = isMissing
    }

    /// Converts this library entry to a `Track` suitable for playback
    /// and for storage in a `Playlist`. The resulting `Track` has
    /// `localFileURL` set, which `PlayerManager` uses to dispatch
    /// to the local playback path.
    func asPlayerTrack(fileURL: URL) -> Track {
        Track(
            id: "local:\(id.uuidString)",
            title: title,
            artist: artist ?? "This Device",
            thumbnailURL: artworkURL,
            localFileURL: fileURL
        )
    }
}
