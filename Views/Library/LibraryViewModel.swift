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

    /// Cached, recomputed only when tracks/search/sort/group actually change
    /// (via the Combine pipeline below) rather than re-filtered/-sorted/-grouped
    /// on every SwiftUI body pass.
    @Published private(set) var filteredAndSortedTracks: [LocalTrack] = []
    @Published private(set) var sections: [LibrarySection] = []

    private let library: LocalLibraryManager
    private var cancellables = Set<AnyCancellable>()

    init(
        library: LocalLibraryManager,
        initialSortOrder: LibrarySortOrder = .recentlyAdded,
        initialGroupBy: LibraryGroupBy = .none
    ) {
        self.library = library
        self.sortOrder = initialSortOrder
        self.groupBy = initialGroupBy
        library.$tracks.assign(to: &$tracks)

        // Recompute the derived lists once per input change. CombineLatest4
        // fires synchronously with the current values on subscription, so the
        // cached properties are populated immediately.
        Publishers.CombineLatest4($tracks, $searchText, $sortOrder, $groupBy)
            .map { tracks, query, order, group in
                let sorted = Self.filterSort(tracks, query: query, order: order)
                return (sorted, Self.makeSections(sorted, groupBy: group))
            }
            .sink { [weak self] sorted, sections in
                self?.filteredAndSortedTracks = sorted
                self?.sections = sections
            }
            .store(in: &cancellables)
    }

    private static func filterSort(
        _ tracks: [LocalTrack], query rawQuery: String, order: LibrarySortOrder
    ) -> [LocalTrack] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? tracks : tracks.filter { track in
            track.title.range(of: query, options: .caseInsensitive) != nil
                || (track.artist?.range(of: query, options: .caseInsensitive) != nil)
        }
        return sort(filtered, by: order)
    }

    private static func makeSections(
        _ tracks: [LocalTrack], groupBy: LibraryGroupBy
    ) -> [LibrarySection] {
        switch groupBy {
        case .none:
            return [LibrarySection(id: "all", title: "", tracks: tracks)]
        case .album:
            return sectionsBy(tracks, key: { $0.album })
        case .artist:
            return sectionsBy(tracks, key: { $0.artist })
        }
    }

    private static func sectionsBy(
        _ tracks: [LocalTrack],
        key: (LocalTrack) -> String?
    ) -> [LibrarySection] {
        let buckets = Dictionary(grouping: tracks) { key($0) ?? Self.unknownKey }
        let orderedKeys = buckets.keys.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == Self.unknownKey { return false }
            if rhs == Self.unknownKey { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return orderedKeys.map { key in
            let bucket = buckets[key] ?? []
            let title = key == Self.unknownKey ? "Unknown" : key
            return LibrarySection(id: title, title: title, tracks: bucket)
        }
    }

    private static let unknownKey = "\u{1F}unknown"

    private static func sort(_ tracks: [LocalTrack], by order: LibrarySortOrder) -> [LocalTrack] {
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
