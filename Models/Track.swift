import Foundation

struct Track: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let thumbnailURL: URL?

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
