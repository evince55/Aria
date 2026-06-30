import Foundation
import AVFoundation
import Combine
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "LocalLibraryManager")

/// Owns the on-disk "imported from Files" library. Tracks the metadata
/// of every file the user has imported (UUID, title, file size,
/// import date) and copies the actual audio files into a stable
/// in-sandbox directory so security-scoped access doesn't expire.
///
/// The file contents are stored at `libraryDirectory/<uuid>.<ext>`.
/// The metadata list is persisted via `KeyValueStore` (debounced,
/// same pattern as `FavoritesManager` / `PlaylistsManager`).
@MainActor
final class LocalLibraryManager: ObservableObject {

    /// Bump when `LocalTrack`'s on-disk shape needs a migration. v1 = first
    /// versioned envelope (migrated from the legacy bare-array file).
    static let schemaVersion = 1

    @Published private(set) var tracks: [LocalTrack] = []

    private let store: KeyValueStore
    private let libraryDirectory: URL
    private let fileManager: FileManager
    private let isCloudFileNotDownloaded: (URL) -> Bool
    private var saveDebouncer: Debouncer!

    /// Runtime location for sample-data files. Sibling to
    /// `libraryDirectory` (i.e. `Documents/AriaLibrary.sampleData/`).
    /// The corresponding repo-side template lives at
    /// `LocalLibraryManager.sampleData/` and is gitignored. See the
    /// README in that directory for the import workflow.
    let sampleDataDirectory: URL

    init(
        store: KeyValueStore,
        libraryDirectory: URL,
        fileManager: FileManager = .default,
        isCloudFileNotDownloaded: @escaping (URL) -> Bool = LocalLibraryManager.defaultIsCloudFileNotDownloaded(_:)
    ) {
        self.store = store
        self.libraryDirectory = libraryDirectory
        self.sampleDataDirectory = libraryDirectory.deletingLastPathComponent()
            .appendingPathComponent(libraryDirectory.lastPathComponent + ".sampleData")
        self.fileManager = fileManager
        self.isCloudFileNotDownloaded = isCloudFileNotDownloaded
        self.saveDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
        try? fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: sampleDataDirectory, withIntermediateDirectories: true)
        load()
        auditMissingFlags()
        cleanupOrphans()
        importSampleDataIfPresent()
    }

    nonisolated static func defaultIsCloudFileNotDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        ) else {
            return false
        }
        guard values.isUbiquitousItem == true else { return false }
        return values.ubiquitousItemDownloadingStatus != .current
    }

    /// Flush any pending debounced save. Call from scenePhase
    /// transitions so the metadata is durable before the app backgrounds.
    func flushPendingWrites() {
        saveDebouncer?.flush()
    }

    /// Imports any audio files present in `sampleDataDirectory` that
    /// are not already in the library (matched by `fileName`).
    /// Idempotent: re-running on the same set of files is a no-op.
    /// Source files are not deleted after import.
    ///
    /// Called from `init` as fire-and-forget; failures are logged but
    /// do not block startup. The user sees imported tracks in the
    /// Library tab once the import completes (typically within a
    /// second of launch).
    private func importSampleDataIfPresent() {
        let sampleDir = sampleDataDirectory
        let fm = fileManager
        guard let entries = try? fm.contentsOfDirectory(
            at: sampleDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let knownNames = Set(tracks.map(\.fileName))
        let audioExtensions: Set<String> = [
            "mp3", "aac", "alac", "flac", "aiff", "wav", "m4a"
        ]
        let newSources = entries.filter { url in
            let ext = url.pathExtension.lowercased()
            return audioExtensions.contains(ext) && !knownNames.contains(url.lastPathComponent)
        }
        guard !newSources.isEmpty else { return }

        log.notice("importSampleDataIfPresent: importing \(newSources.count) sample file(s)")
        for source in newSources {
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.importFile(at: source)
                } catch {
                    log.error("importSampleDataIfPresent: failed to import \(source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Copies the file at `sourceURL` into the library directory and
    /// adds a `LocalTrack` entry. The caller must hold a security-scoped
    /// reference (start/stop are managed here) so the read can succeed
    /// even if the picker URL is from outside the app sandbox.
    func importFile(at sourceURL: URL) async throws -> LocalTrack {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        if isCloudFileNotDownloaded(sourceURL) {
            throw ImportError.fileNotDownloaded
        }

        let size = (try? fileManager.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
        if size == 0 {
            throw ImportError.zeroByteFile
        }

        let format = await AudioFormat.probe(url: sourceURL)
        guard format.isSupported else {
            throw ImportError.unsupportedFormat(format: format)
        }

        let original = try Data(contentsOf: sourceURL)
        let id = UUID()
        let ext = sourceURL.pathExtension
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destURL = libraryDirectory.appendingPathComponent(fileName)
        try AtomicFileWriter.writeAtomically(original, to: destURL)

        let title = (await Self.readTitle(at: destURL, fallback: sourceURL.deletingPathExtension().lastPathComponent))
        let artist = await Self.readArtist(at: destURL)
        let album = await Self.readAlbum(at: destURL)
        let storedSize = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? Int64(original.count)
        let duration = await Self.readDuration(at: destURL)
        let artworkURL = await extractArtwork(from: destURL, trackID: id)

        let track = LocalTrack(
            id: id,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            fileName: fileName,
            importedAt: Date(),
            fileSizeBytes: storedSize,
            durationSeconds: duration,
            album: album
        )
        tracks.insert(track, at: 0)
        save()
        return track
    }

    /// Removes the file and the track entry. No-op if the track isn't
    /// in the library.
    func remove(_ track: LocalTrack) {
        let url = fileURL(for: track)
        try? fileManager.removeItem(at: url)
        if let artworkURL = track.artworkURL {
            try? fileManager.removeItem(at: artworkURL)
        }
        tracks.removeAll { $0.id == track.id }
        save()
    }

    /// Replaces a missing track's on-disk file with a new one the user
    /// just picked, keeping the track's identity (id) so playlist /
    /// recently-played references stay valid. The new file is copied
    /// into the library directory under a fresh on-disk name; the
    /// `fileName` field is updated to match.
    func repairMissing(trackID: UUID, newFileURL: URL) throws -> LocalTrack {
        guard let idx = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw NSError(domain: "AriaLibrary", code: 404, userInfo: [NSLocalizedDescriptionKey: "Track not found"])
        }
        let old = tracks[idx]

        let oldFileURL = fileURL(for: old)
        if fileManager.fileExists(atPath: oldFileURL.path) {
            try? fileManager.removeItem(at: oldFileURL)
        }
        if let art = old.artworkURL, fileManager.fileExists(atPath: art.path) {
            try? fileManager.removeItem(at: art)
        }

        let newDiskID = UUID()
        let ext = newFileURL.pathExtension.isEmpty ? "mp3" : newFileURL.pathExtension
        let newFileName = "\(newDiskID.uuidString).\(ext)"
        let newFile = libraryDirectory.appendingPathComponent(newFileName)
        try? fileManager.removeItem(at: newFile)
        let didStart = newFileURL.startAccessingSecurityScopedResource()
        defer { if didStart { newFileURL.stopAccessingSecurityScopedResource() } }
        try fileManager.copyItem(at: newFileURL, to: newFile)

        let repaired = LocalTrack(
            id: old.id,
            title: newFileURL.deletingPathExtension().lastPathComponent,
            artist: old.artist,
            artworkURL: nil,
            fileName: newFileName,
            importedAt: Date(),
            fileSizeBytes: (try? fileManager.attributesOfItem(atPath: newFile.path)[.size] as? Int64) ?? 0,
            durationSeconds: old.durationSeconds,
            isMissing: false
        )

        tracks[idx] = repaired
        save()
        return repaired
    }

    /// Reconstructs the absolute file URL for a track. The file is
    /// guaranteed to exist in `libraryDirectory` while the track is in
    /// the list; callers should not retain the URL beyond the track's
    /// lifetime.
    func fileURL(for track: LocalTrack) -> URL {
        libraryDirectory.appendingPathComponent(track.fileName)
    }

    /// Walks the library and updates each track's `isMissing` flag based
    /// on whether the file still exists on disk. O(n). Persists only if
    /// any flag changed.
    func auditMissingFlags() {
        var changed = false
        let updated = tracks.map { track -> LocalTrack in
            let url = fileURL(for: track)
            let exists = FileManager.default.fileExists(atPath: url.path)
            if exists != track.isMissing {
                return track
            }
            changed = true
            return LocalTrack(
                id: track.id,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                fileName: track.fileName,
                importedAt: track.importedAt,
                fileSizeBytes: track.fileSizeBytes,
                durationSeconds: track.durationSeconds,
                album: track.album,
                isMissing: !exists
            )
        }
        if changed {
            tracks = updated
            save()
        }
    }

    /// Reconciles the on-disk library directory with the in-memory track list.
    /// Any file under `libraryDirectory/` (or its `artwork/` subdir) whose UUID
    /// prefix doesn't match a known on-disk identifier is removed. Used to
    /// clean up partial imports (kill mid-write) and stale artwork after a
    /// track is removed. Idempotent.
    ///
    /// The live set is keyed on `track.fileName.prefix(36)` (the actual
    /// on-disk UUID), not `track.id.uuidString` (the stable identity). The
    /// two can diverge after `repairMissing`, which keeps the original `id`
    /// but writes the replacement file under a fresh on-disk UUID.
    func cleanupOrphans() {
        let uuidPrefixLength = 36  // canonical UUID string length
        let liveFileUUIDs = Set(tracks.compactMap { track -> String? in
            track.fileName.count >= uuidPrefixLength
                ? String(track.fileName.prefix(uuidPrefixLength))
                : nil
        })

        let liveArtworkFileNames = Set(tracks.compactMap { track -> String? in
            guard let url = track.artworkURL else { return nil }
            return url.lastPathComponent
        })

        func removeOrphans(in directory: URL, knownNames: Set<String>) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                guard !entry.hasDirectoryPath else { continue }
                let name = entry.lastPathComponent
                let uuidPrefix = String(name.prefix(uuidPrefixLength))
                let isKnownByName = knownNames.contains(name)
                let isKnownByUUID = uuidPrefix.count == uuidPrefixLength
                    && liveFileUUIDs.contains(uuidPrefix)
                if !isKnownByName && !isKnownByUUID {
                    try? fileManager.removeItem(at: entry)
                }
            }
        }

        removeOrphans(in: libraryDirectory, knownNames: [])
        let artworkDir = libraryDirectory.appendingPathComponent("artwork", isDirectory: true)
        removeOrphans(in: artworkDir, knownNames: liveArtworkFileNames)
    }

    // MARK: - Metadata extraction

    private static func readTitle(at url: URL, fallback: String) async -> String {
        let asset = AVURLAsset(url: url)
        if let md = try? await asset.load(.commonMetadata),
           let title = md.first(where: { $0.commonKey?.rawValue == "title" })?.stringValue,
           !title.isEmpty {
            return title
        }
        return fallback
    }

    private static func readArtist(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        if let md = try? await asset.load(.commonMetadata),
           let artist = md.first(where: { $0.commonKey?.rawValue == "artist" })?.stringValue,
           !artist.isEmpty {
            return artist
        }
        return "This Device"
    }

    private static func readAlbum(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let md = try? await asset.load(.commonMetadata) else { return nil }
        return md.first(where: { $0.commonKey?.rawValue == "albumName" })?.stringValue
    }

    private static func readDuration(at url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite && seconds > 0 {
                return seconds
            }
        }
        return 0
    }

    /// Extracts embedded artwork (ID3 APIC for MP3, PICTURE for FLAC,
    /// etc.) and writes it to `libraryDirectory/artwork/<uuid>.<ext>`.
    /// Returns the file URL, or nil if the file has no artwork or the
    /// extraction failed. Best-effort; a missing artwork file is not
    /// considered an error.
    private func extractArtwork(from fileURL: URL, trackID: UUID) async -> URL? {
        let asset = AVURLAsset(url: fileURL)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        let artworkItem = metadata.first { item in
            item.commonKey?.rawValue == "artwork"
        }
        guard let artworkItem else { return nil }
        guard let data = try? await artworkItem.load(.dataValue), !data.isEmpty else { return nil }

        let artworkDir = libraryDirectory.appendingPathComponent("artwork", isDirectory: true)
        do {
            try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // JPEG starts with FF D8 FF; PNG starts with 89 50 4E 47.
        let ext: String
        if data.starts(with: [0xFF, 0xD8]) {
            ext = "jpg"
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            ext = "png"
        } else {
            ext = "img"
        }
        let dest = artworkDir.appendingPathComponent("\(trackID.uuidString).\(ext)")
        do {
            try AtomicFileWriter.writeAtomically(data, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - Persistence

    private func save() { saveDebouncer.call() }

    private func performSave() {
        guard let data = try? SchemaStore.encode(tracks, schemaVersion: Self.schemaVersion) else { return }
        try? store.save(data)
    }

    private func load() {
        guard let saved = SchemaStore.loadItems(LocalTrack.self, from: store, currentVersion: Self.schemaVersion) else { return }
        tracks = saved
    }
}
