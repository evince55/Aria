import Foundation

/// Bulk-imports every audio file in a picked folder (recursively) into the
/// local library. The alternative today is selecting files one at a time in
/// the document picker, which nobody with a real library will do.
///
/// The heavy lifting (format probe, copy into the sandbox, artwork extraction,
/// dedupe) stays in `LocalLibraryManager.importFile`; this only walks the tree
/// and reports progress.
enum FolderImporter {

    struct Progress: Equatable {
        var imported: Int = 0
        var skipped: Int = 0
        var total: Int = 0
    }

    /// Audio extensions worth attempting. The authoritative check is
    /// `AudioFormat.probe` inside `importFile`; this pre-filter just avoids
    /// walking into artwork, cue sheets, and log files.
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "alac", "wav", "wave", "aiff", "aif",
        "ogg", "oga", "opus", "wma", "ape", "mp4", "m4b",
    ]

    /// Enumerates candidate audio files under `folder`, depth-first, skipping
    /// hidden files and package contents. Sorted for a stable, predictable
    /// import order (and so progress reads sensibly).
    static func audioFiles(in folder: URL,
                           fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isFile else { continue }
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Imports every audio file under `folder`. `importFile` throws per-file
    /// (unsupported format, zero-byte, iCloud placeholder); those count as
    /// skipped rather than aborting the run — one bad file in a 500-track
    /// folder must not kill the import.
    ///
    /// `onProgress` fires after each file so the UI can show live counts.
    static func importAll(
        from folder: URL,
        importFile: (URL) async throws -> Void,
        onProgress: @MainActor (Progress) -> Void
    ) async -> Progress {
        let didStart = folder.startAccessingSecurityScopedResource()
        defer { if didStart { folder.stopAccessingSecurityScopedResource() } }

        let files = audioFiles(in: folder)
        var progress = Progress(total: files.count)
        await onProgress(progress)

        for file in files {
            do {
                try await importFile(file)
                progress.imported += 1
            } catch {
                progress.skipped += 1
            }
            await onProgress(progress)
        }
        return progress
    }
}
