import Foundation

/// The search seam `SearchView` talks to, so the view is identical whether the
/// configured server is Aria's yt-dlp backend or a Subsonic server.
///
/// Offset-based paging is what both back ends expose (`offset` for Aria,
/// `songOffset` for Subsonic), and it's what the existing infinite-scroll in
/// `SearchView` already drives.
protocol MusicSearching: Sendable {
    func search(query: String, limit: Int, offset: Int) async throws -> [Track]
}
