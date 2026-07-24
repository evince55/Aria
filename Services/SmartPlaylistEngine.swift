import Foundation

/// Pure evaluation of smart-playlist rules against a snapshot of the library.
/// No manager dependencies: callers assemble `SmartCandidate`s from whatever
/// stores they hold and pass plain sets for favorites/recency — which is what
/// makes the whole rule matrix unit-testable.
enum SmartPlaylistEngine {

    /// One evaluable track with the metadata sidecar the rules need.
    struct SmartCandidate {
        let track: Track
        let source: SmartSource
        let addedAt: Date?
        let fileName: String?
        let durationSeconds: Double?
        let album: String?
    }

    // MARK: - Candidate assembly

    /// Flattens the three library surfaces into candidates. `fileURL` resolves
    /// a local track's on-disk file (injected so this stays pure and the
    /// container-relative path logic stays in `LocalLibraryManager`).
    static func candidates(
        localTracks: [LocalTrack],
        fileURL: (LocalTrack) -> URL,
        downloads: [DownloadRecord],
        favorites: [Track]
    ) -> [SmartCandidate] {
        var out: [SmartCandidate] = []
        for lt in localTracks where !lt.isMissing {
            out.append(SmartCandidate(
                track: lt.asPlayerTrack(fileURL: fileURL(lt)),
                source: .localFile,
                addedAt: lt.importedAt,
                fileName: lt.fileName,
                durationSeconds: lt.durationSeconds,
                album: lt.album
            ))
        }
        for rec in downloads {
            out.append(SmartCandidate(
                track: rec.asTrack,
                source: .download,
                addedAt: rec.downloadedAt,
                fileName: rec.fileName,
                durationSeconds: rec.durationSeconds,
                album: nil
            ))
        }
        for fav in favorites {
            out.append(SmartCandidate(
                track: fav,
                source: .favorite,
                addedAt: nil,
                fileName: fav.localFileURL?.lastPathComponent,
                durationSeconds: fav.duration,
                album: fav.album
            ))
        }
        return out
    }

    // MARK: - Evaluation

    static func evaluate(
        _ playlist: SmartPlaylist,
        candidates: [SmartCandidate],
        favoriteIDs: Set<String>,
        recentlyPlayedIDs: Set<String>,
        now: Date = Date()
    ) -> [Track] {
        let rules = playlist.rules

        var matched = candidates.filter { c in
            guard rules.sources.contains(c.source) else { return false }
            if rules.favoritesOnly && !favoriteIDs.contains(c.track.id) { return false }

            if !matchesText(rules.titleContains, in: c.track.title) { return false }
            if !matchesText(rules.artistContains, in: c.track.artist) { return false }
            if !matchesText(rules.albumContains, in: c.album ?? "") { return false }

            if rules.losslessOnly {
                guard let name = c.fileName,
                      AudioFormat.detect(extension: (name as NSString).pathExtension.lowercased()).isLossless
                else { return false }
            }

            switch rules.recency {
            case .any: break
            case .recentlyPlayed:
                if !recentlyPlayedIDs.contains(c.track.id) { return false }
            case .notRecentlyPlayed:
                if recentlyPlayedIDs.contains(c.track.id) { return false }
            }

            if let days = rules.addedWithinDays {
                guard let added = c.addedAt,
                      now.timeIntervalSince(added) <= Double(days) * 86_400 else { return false }
            }

            if let minM = rules.minMinutes {
                guard let d = c.durationSeconds, d >= minM * 60 else { return false }
            }
            if let maxM = rules.maxMinutes {
                guard let d = c.durationSeconds, d <= maxM * 60 else { return false }
            }
            return true
        }

        matched = dedupeByTrackID(matched)
        matched = sorted(matched, by: playlist.sort)

        var tracks = matched.map(\.track)
        if let limit = playlist.limit, limit > 0 {
            tracks = Array(tracks.prefix(limit))
        }
        return tracks
    }

    // MARK: - Helpers

    private static func matchesText(_ needle: String, in haystack: String) -> Bool {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return haystack.range(of: trimmed, options: .caseInsensitive) != nil
    }

    /// The same track id can appear as local file, download, and favorite —
    /// keep the richest source (local > download > favorite).
    private static func dedupeByTrackID(_ candidates: [SmartCandidate]) -> [SmartCandidate] {
        let priority: [SmartSource: Int] = [.localFile: 0, .download: 1, .favorite: 2]
        var best: [String: SmartCandidate] = [:]
        for c in candidates {
            if let existing = best[c.track.id],
               priority[existing.source, default: 9] <= priority[c.source, default: 9] {
                continue
            }
            best[c.track.id] = c
        }
        // Preserve the input's relative order for stable results.
        var seen = Set<String>()
        return candidates.compactMap { c in
            guard !seen.contains(c.track.id), let chosen = best[c.track.id] else { return nil }
            seen.insert(c.track.id)
            return chosen
        }
    }

    private static func sorted(_ candidates: [SmartCandidate], by sort: SmartSort) -> [SmartCandidate] {
        switch sort {
        case .newestAdded:
            // Unknown added-dates (favorites) sink to the end.
            return candidates.sorted {
                ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast)
            }
        case .title:
            return candidates.sorted {
                $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending
            }
        case .artist:
            return candidates.sorted {
                $0.track.artist.localizedCaseInsensitiveCompare($1.track.artist) == .orderedAscending
            }
        case .longest:
            return candidates.sorted { ($0.durationSeconds ?? 0) > ($1.durationSeconds ?? 0) }
        case .shuffle:
            return candidates.shuffled()
        }
    }
}
