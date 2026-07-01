import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let thumbnailURL: URL?
    /// When non-nil, identifies this as a local file (`id` is
    /// `"local:<UUID>"`) that should be played through the engine
    /// path from the local library instead of fetched from the
    /// backend. `thumbnailURL` then holds the extracted artwork.
    let localFileURL: URL?
    /// `true` for a local file whose bytes are no longer on disk
    /// (or were never imported). Surfaced by `playSlice` /
    /// `play(localTrack:fileURL:)` so callers can skip these tracks
    /// instead of triggering a 1-by-1 playback error.
    var isMissing: Bool
    /// Track length in seconds when known (from search results or local-file
    /// metadata). Optional so legacy persisted tracks decode to `nil` without a
    /// schema migration; surfaced in lists/rows.
    var duration: Double?
    /// Album name when known (from local-file metadata). Optional so legacy
    /// persisted tracks decode to `nil` without a schema migration.
    var album: String?

    init(
        id: String,
        title: String,
        artist: String,
        thumbnailURL: URL? = nil,
        localFileURL: URL? = nil,
        isMissing: Bool = false,
        duration: Double? = nil,
        album: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.thumbnailURL = thumbnailURL
        self.localFileURL = localFileURL
        self.isMissing = isMissing
        self.duration = duration
        self.album = album
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, thumbnailURL, localFileURL, isMissing, duration, album
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.artist = try c.decode(String.self, forKey: .artist)
        self.thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        self.localFileURL = try c.decodeIfPresent(URL.self, forKey: .localFileURL)
        self.isMissing = try c.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        self.duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        self.album = try c.decodeIfPresent(String.self, forKey: .album)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(artist, forKey: .artist)
        try c.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try c.encodeIfPresent(localFileURL, forKey: .localFileURL)
        try c.encode(isMissing, forKey: .isMissing)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(album, forKey: .album)
    }

    var isLocal: Bool { localFileURL != nil }

    var firstLetter: String {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: .current)
        guard let first = normalized.first else { return "#" }
        let string = String(first).uppercased()
        return string.rangeOfCharacter(from: .letters) != nil ? string : "#"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
}
