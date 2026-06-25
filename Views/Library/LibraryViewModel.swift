import Foundation
import Combine

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case recentlyAdded
    case title
    case artist
    case duration
    case fileSize

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recentlyAdded: return "Recently Added"
        case .title: return "Title"
        case .artist: return "Artist"
        case .duration: return "Duration"
        case .fileSize: return "File Size"
        }
    }
}

enum LibraryGroupBy: String, CaseIterable, Identifiable {
    case none
    case album
    case artist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .album: return "Album"
        case .artist: return "Artist"
        }
    }
}

struct LibrarySection: Identifiable, Hashable {
    let id: String
    let title: String
    let tracks: [LocalTrack]
}

@MainActor
final class LibraryViewModel: ObservableObject {

    @Published var searchText: String = ""
    @Published var sortOrder: LibrarySortOrder
    @Published var groupBy: LibraryGroupBy

    @Published private(set) var tracks: [LocalTrack] = []

    private let library: LocalLibraryManager

    init(
        library: LocalLibraryManager,
        initialSortOrder: LibrarySortOrder = .recentlyAdded,
        initialGroupBy: LibraryGroupBy = .none
    ) {
        self.library = library
        self.sortOrder = initialSortOrder
        self.groupBy = initialGroupBy
        library.$tracks.assign(to: &$tracks)
    }

    var filteredAndSortedTracks: [LocalTrack] {
        let filtered: [LocalTrack]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = tracks
        } else {
            filtered = tracks.filter { track in
                track.title.range(of: query, options: .caseInsensitive) != nil
                    || (track.artist?.range(of: query, options: .caseInsensitive) != nil)
            }
        }
        return sort(filtered, by: sortOrder)
    }

    var sections: [LibrarySection] { [] }

    private func sort(_ tracks: [LocalTrack], by order: LibrarySortOrder) -> [LocalTrack] {
        switch order {
        case .recentlyAdded:
            return tracks.sorted { $0.importedAt > $1.importedAt }
        case .title:
            return tracks.sorted { lhs, rhs in
                let c = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                return c == .orderedAscending
            }
        case .artist:
            return tracks.sorted { lhs, rhs in
                switch (lhs.artist, rhs.artist) {
                case (nil, nil):
                    return false
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let l?, let r?):
                    return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
                }
            }
        case .duration:
            return tracks.sorted { lhs, rhs in
                switch (lhs.durationSeconds, rhs.durationSeconds) {
                case (nil, nil):
                    return false
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                case (let l?, let r?):
                    return l < r
                }
            }
        case .fileSize:
            return tracks.sorted { $0.fileSizeBytes > $1.fileSizeBytes }
        }
    }
}
