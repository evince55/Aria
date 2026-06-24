import Foundation
import AVFoundation
import Combine

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

    @Published private(set) var tracks: [LocalTrack] = []

    private let store: KeyValueStore
    private let libraryDirectory: URL
    private let fileManager: FileManager
    private var saveDebouncer: Debouncer!

    init(
        store: KeyValueStore,
        libraryDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.store = store
        self.libraryDirectory = libraryDirectory
        self.fileManager = fileManager
        self.saveDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
        try? fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        load()
    }

    /// Flush any pending debounced save. Call from scenePhase
    /// transitions so the metadata is durable before the app backgrounds.
    func flushPendingWrites() {
        saveDebouncer?.flush()
    }

    /// Copies the file at `sourceURL` into the library directory and
    /// adds a `LocalTrack` entry. The caller must hold a security-scoped
    /// reference (start/stop are managed here) so the read can succeed
    /// even if the picker URL is from outside the app sandbox.
    func importFile(at sourceURL: URL) async throws -> LocalTrack {
        let didStart = sourceURL.startAccessingSecurityScopedResource()
        defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }

        let original = try Data(contentsOf: sourceURL)
        let id = UUID()
        let ext = sourceURL.pathExtension
        let fileName = ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
        let destURL = libraryDirectory.appendingPathComponent(fileName)
        try original.write(to: destURL, options: .atomic)

        let title = (await Self.readTitle(at: destURL, fallback: sourceURL.deletingPathExtension().lastPathComponent))
        let artist = await Self.readArtist(at: destURL)
        let size = (try? fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? Int64(original.count)
        let duration = await Self.readDuration(at: destURL)
        let artworkURL = await extractArtwork(from: destURL, trackID: id)

        let track = LocalTrack(
            id: id,
            title: title,
            artist: artist,
            artworkURL: artworkURL,
            fileName: fileName,
            importedAt: Date(),
            fileSizeBytes: size,
            durationSeconds: duration
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

    /// Reconstructs the absolute file URL for a track. The file is
    /// guaranteed to exist in `libraryDirectory` while the track is in
    /// the list; callers should not retain the URL beyond the track's
    /// lifetime.
    func fileURL(for track: LocalTrack) -> URL {
        libraryDirectory.appendingPathComponent(track.fileName)
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
        guard let md = try? await asset.load(.commonMetadata) else { return nil }
        return md.first(where: { $0.commonKey?.rawValue == "artist" })?.stringValue
    }

    private static func readDuration(at url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : nil
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
            try data.write(to: dest, options: .atomic)
            return dest
        } catch {
            return nil
        }
    }

    // MARK: - Persistence

    private func save() { saveDebouncer.call() }

    private func performSave() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? store.save(data)
    }

    private func load() {
        guard let data = store.load(),
              let saved = try? JSONDecoder().decode([LocalTrack].self, from: data) else { return }
        tracks = saved
    }
}
