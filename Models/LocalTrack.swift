import Foundation

/// A track imported from the device's Files app via `UIDocumentPicker`.
///
/// The `id` is a stable UUID assigned at import time. The actual file
/// lives in the app's Documents/AriaLibrary/ directory; the on-disk
/// name is `fileName` (a UUID + extension). The `fileURL(for:)` method
/// on `LocalLibraryManager` reconstructs the absolute path from these
/// pieces.
///
/// **Artwork is referenced by file name, never by absolute URL.** iOS
/// changes the app's Data-container UUID on reinstall / dev-rebuild, so
/// any absolute path baked into persisted state (e.g.
/// `file:///var/mobile/Containers/Data/Application/<OLD-UUID>/Documents/…`)
/// goes stale and resolves to a "URL not found" error. Audio survives
/// because `LocalLibraryManager.fileURL(for:)` re-derives the absolute
/// path from `fileName` against the *current* container at access time;
/// artwork now does the same via `artworkFileName` + the computed
/// `artworkURL` (or `LocalLibraryManager.artworkURL(for:)`).
struct LocalTrack: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let artist: String?
    /// The bare on-disk file name of the extracted artwork (e.g.
    /// `"<uuid>.jpg"`), relative to `<libraryDirectory>/artwork/`. Never an
    /// absolute path — see the type doc for why. `nil` when the track has
    /// no extracted artwork.
    let artworkFileName: String?
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
        artworkFileName: String?,
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
        self.artworkFileName = artworkFileName
        self.fileName = fileName
        self.importedAt = importedAt
        self.fileSizeBytes = fileSizeBytes
        self.durationSeconds = durationSeconds
        self.album = album
        self.isMissing = isMissing
    }

    // MARK: - Codable migration

    private enum CodingKeys: String, CodingKey {
        case id, title, artist
        case artworkFileName
        /// Legacy key: older builds persisted an absolute `URL` here.
        case artworkURL
        case fileName, importedAt, fileSizeBytes, durationSeconds, album, isMissing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        fileName = try container.decode(String.self, forKey: .fileName)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        fileSizeBytes = try container.decode(Int64.self, forKey: .fileSizeBytes)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false

        // Prefer the new relative field; otherwise migrate from the legacy
        // absolute `artworkURL` by keeping only its last path component
        // (the bare file name), which is stable across containers. The
        // legacy value may have been encoded either as a URL or as a raw
        // string, so try both.
        if let relative = try container.decodeIfPresent(String.self, forKey: .artworkFileName) {
            artworkFileName = relative.isEmpty ? nil : relative
        } else if let legacyURL = try? container.decodeIfPresent(URL.self, forKey: .artworkURL) ?? nil {
            let name = legacyURL.lastPathComponent
            artworkFileName = name.isEmpty ? nil : name
        } else if let legacyString = try? container.decodeIfPresent(String.self, forKey: .artworkURL) ?? nil,
                  !legacyString.isEmpty {
            let name = (legacyString as NSString).lastPathComponent
            artworkFileName = name.isEmpty ? nil : name
        } else {
            artworkFileName = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(artist, forKey: .artist)
        try container.encodeIfPresent(artworkFileName, forKey: .artworkFileName)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(importedAt, forKey: .importedAt)
        try container.encode(fileSizeBytes, forKey: .fileSizeBytes)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encode(isMissing, forKey: .isMissing)
        // Note: the legacy `artworkURL` key is intentionally never written.
    }

    // MARK: - Artwork resolution

    /// The standard imported-library artwork directory, resolved against
    /// the *current* app Data container. Mirrors how `AriaApp` /
    /// `AppEnvironment` build the library directory
    /// (`<Documents>/AriaLibrary/artwork`). Because it's re-derived at
    /// access time, it stays valid across container UUID changes.
    private static var defaultArtworkDirectory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs
            .appendingPathComponent("AriaLibrary", isDirectory: true)
            .appendingPathComponent("artwork", isDirectory: true)
    }

    /// The absolute artwork URL resolved against the current container, or
    /// `nil` if the track has no artwork. Resolved at access time (never
    /// persisted) so it survives reinstall / dev-rebuild container changes.
    ///
    /// This keeps the existing `track.artworkURL` read sites working
    /// unchanged while fixing the stale-absolute-path bug under the hood.
    var artworkURL: URL? {
        guard let artworkFileName, !artworkFileName.isEmpty,
              let dir = Self.defaultArtworkDirectory else {
            return nil
        }
        return dir.appendingPathComponent(artworkFileName)
    }

    /// Converts this library entry to a `Track` suitable for playback
    /// and for storage in a `Playlist`. The resulting `Track` has
    /// `localFileURL` set, which `PlayerManager` uses to dispatch
    /// to the local playback path.
    ///
    /// `artworkURL` defaults to the container-resolved computed
    /// `artworkURL`; callers that already hold a manager-resolved URL
    /// (resolved against an injected library directory) may pass it
    /// explicitly. Existing call sites that omit the parameter keep
    /// working and now get a valid current-container artwork URL.
    func asPlayerTrack(fileURL: URL, artworkURL: URL? = nil) -> Track {
        Track(
            id: "local:\(id.uuidString)",
            title: title,
            artist: artist ?? "This Device",
            thumbnailURL: artworkURL ?? self.artworkURL,
            localFileURL: fileURL,
            isMissing: isMissing
        )
    }
}
