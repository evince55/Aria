import Foundation

/// Which library surface a candidate track came from. Also the dedupe
/// priority when the same track id appears in several (local wins — it has
/// the richest metadata and needs no network).
enum SmartSource: String, Codable, CaseIterable, Hashable {
    case localFile
    case download
    case favorite

    var label: String {
        switch self {
        case .localFile: return "Local files"
        case .download: return "Downloads"
        case .favorite: return "Favorites"
        }
    }
}

/// Membership-based play recency. The recently-played store is a capped list
/// without timestamps, so rules are "in the list" / "not in the list" rather
/// than time-windowed.
enum SmartRecency: String, Codable, CaseIterable, Hashable {
    case any
    case recentlyPlayed
    case notRecentlyPlayed

    var label: String {
        switch self {
        case .any: return "Any"
        case .recentlyPlayed: return "Recently played"
        case .notRecentlyPlayed: return "Not recently played"
        }
    }
}

enum SmartSort: String, Codable, CaseIterable, Hashable {
    case newestAdded
    case title
    case artist
    case longest
    case shuffle

    var label: String {
        switch self {
        case .newestAdded: return "Newest first"
        case .title: return "Title"
        case .artist: return "Artist"
        case .longest: return "Longest first"
        case .shuffle: return "Shuffle"
        }
    }
}

/// AND-composed rule set: a track must satisfy every configured rule.
/// Unset/empty rules don't constrain.
struct SmartPlaylistRules: Codable, Hashable {
    var sources: Set<SmartSource> = [.localFile, .download]
    var titleContains: String = ""
    var artistContains: String = ""
    var albumContains: String = ""
    /// Keep only lossless files (FLAC/ALAC/WAV/AIFF…, by file extension).
    /// Tracks with no file on device (streamed favorites) never match.
    var losslessOnly: Bool = false
    /// Intersect with the favorites list regardless of source.
    var favoritesOnly: Bool = false
    var recency: SmartRecency = .any
    /// Only tracks imported/downloaded within the last N days. Tracks without
    /// an added-date (favorites) never match while this is set.
    var addedWithinDays: Int?
    /// Duration bounds in minutes. Tracks with unknown duration never match
    /// while a bound is set.
    var minMinutes: Double?
    var maxMinutes: Double?
}

/// A rule-defined playlist that re-evaluates against the live library every
/// time it's opened — nothing is snapshotted, so it stays current as files
/// are imported, downloaded, favorited, and played.
struct SmartPlaylist: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var rules: SmartPlaylistRules = SmartPlaylistRules()
    var sort: SmartSort = .newestAdded
    /// Cap the result to the first N tracks after sorting; nil = no cap.
    var limit: Int?
    var createdAt: Date = Date()
}
