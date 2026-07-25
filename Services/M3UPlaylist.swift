import Foundation

/// Reads and writes M3U / M3U8 playlists — the lingua franca for moving
/// playlists between music apps (foobar2000, Navidrome, Plex, Symfonium…).
///
/// Aria's library is content-addressed by file name inside its own sandbox
/// directory, so import resolves entries against the library by **file name**
/// (and falls back to a title/artist match) rather than by absolute path,
/// which is meaningless across devices and app reinstalls.
enum M3UPlaylist {

    /// One parsed entry: the path as written, plus `#EXTINF` metadata when present.
    struct Entry: Equatable {
        let path: String
        let title: String?
        let artist: String?
        let durationSeconds: Double?

        /// Bare file name of `path`, the key Aria matches on.
        var fileName: String { (path as NSString).lastPathComponent }
    }

    enum ParseError: LocalizedError, Equatable {
        case noEntries
        var errorDescription: String? {
            "No playable entries found in that playlist file."
        }
    }

    // MARK: - Parse

    /// Parses M3U/M3U8 text. Handles `#EXTINF:<secs>,<artist> - <title>`,
    /// ignores comments/directives, and accepts both LF and CRLF.
    static func parse(_ text: String) throws -> [Entry] {
        var entries: [Entry] = []
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingDuration: Double?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                guard line.uppercased().hasPrefix("#EXTINF:") else { continue }
                // "#EXTINF:213,Artist - Title" (duration may be -1 or absent)
                let payload = String(line.dropFirst("#EXTINF:".count))
                let parts = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                if let secs = Double(parts.first?.trimmingCharacters(in: .whitespaces) ?? ""), secs > 0 {
                    pendingDuration = secs
                }
                if parts.count > 1 {
                    let label = parts[1].trimmingCharacters(in: .whitespaces)
                    if let dash = label.range(of: " - ") {
                        pendingArtist = String(label[..<dash.lowerBound])
                        pendingTitle = String(label[dash.upperBound...])
                    } else if !label.isEmpty {
                        pendingTitle = label
                    }
                }
                continue
            }

            entries.append(Entry(path: line, title: pendingTitle,
                                 artist: pendingArtist, durationSeconds: pendingDuration))
            pendingTitle = nil
            pendingArtist = nil
            pendingDuration = nil
        }

        guard !entries.isEmpty else { throw ParseError.noEntries }
        return entries
    }

    // MARK: - Write

    /// Serializes tracks as extended M3U. Paths are written as bare file names
    /// for library tracks (portable, and what Aria matches on re-import) and as
    /// the stream identity for non-file tracks so the export stays lossless.
    static func write(tracks: [Track], fileName: (Track) -> String?) -> String {
        var lines = ["#EXTM3U"]
        for track in tracks {
            let secs = track.duration.map { Int($0.rounded()) } ?? -1
            lines.append("#EXTINF:\(secs),\(track.artist) - \(track.title)")
            lines.append(fileName(track) ?? track.id)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Resolve

    /// Matches parsed entries against the library. Primary key is the bare file
    /// name (case-insensitive); the fallback is an exact title+artist match, so
    /// a playlist exported from another app still lands if the files were
    /// imported into Aria under different names.
    ///
    /// Returns the resolved tracks in playlist order plus the entries that
    /// found no match, so the UI can report "added 18 of 20".
    static func resolve(
        entries: [Entry],
        libraryTracks: [LocalTrack],
        fileURL: (LocalTrack) -> URL
    ) -> (tracks: [Track], unmatched: [Entry]) {
        var byFileName: [String: LocalTrack] = [:]
        var byTitleArtist: [String: LocalTrack] = [:]
        for lt in libraryTracks where !lt.isMissing {
            byFileName[lt.fileName.lowercased()] = lt
            let key = "\(lt.title.lowercased())|\((lt.artist ?? "").lowercased())"
            byTitleArtist[key] = lt
        }

        var tracks: [Track] = []
        var unmatched: [Entry] = []
        var seen = Set<UUID>()

        for entry in entries {
            var match = byFileName[entry.fileName.lowercased()]
            if match == nil, let title = entry.title {
                let key = "\(title.lowercased())|\((entry.artist ?? "").lowercased())"
                match = byTitleArtist[key]
            }
            guard let local = match else {
                unmatched.append(entry)
                continue
            }
            guard seen.insert(local.id).inserted else { continue }  // playlist listed it twice
            tracks.append(local.asPlayerTrack(fileURL: fileURL(local)))
        }
        return (tracks, unmatched)
    }
}
