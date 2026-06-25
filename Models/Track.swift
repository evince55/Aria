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

    init(
        id: String,
        title: String,
        artist: String,
        thumbnailURL: URL? = nil,
        localFileURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.thumbnailURL = thumbnailURL
        self.localFileURL = localFileURL
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
