import Foundation
import AVFoundation
import Combine
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "LocalLibraryManager")

/// The subset of `AVURLAsset`'s async metadata-loading surface that
/// `LocalLibraryManager.loadArtworkData(from:)` needs, expressed as plain
/// async functions (rather than `AVAsset`'s `load(_:)` key-path API) so
/// tests can conform a synthetic double without needing real audio
/// fixtures. `AVURLAsset` conforms via the adapter extension below.
protocol MetadataLoading {
    /// All metadata items for every identifier the asset exposes
    /// (`AVAsset.load(.metadata)`).
    func loadAllMetadataItems() async throws -> [AVMetadataItem]
    /// The legacy common-metadata items (`AVAsset.load(.commonMetadata)`).
    func loadCommonMetadataItems() async throws -> [AVMetadataItem]
    /// The format-specific metadata containers the asset advertises
    /// (`AVAsset.load(.availableMetadataFormats)`).
    func loadAvailableMetadataFormats() async throws -> [AVMetadataFormat]
    /// The metadata items for one specific format
    /// (`AVAsset.loadMetadata(for:)`).
    func loadMetadataItems(for format: AVMetadataFormat) async throws -> [AVMetadataItem]
}

extension AVURLAsset: MetadataLoading {
    func loadAllMetadataItems() async throws -> [AVMetadataItem] {
        try await load(.metadata)
    }

    func loadCommonMetadataItems() async throws -> [AVMetadataItem] {
        try await load(.commonMetadata)
    }

    func loadAvailableMetadataFormats() async throws -> [AVMetadataFormat] {
        try await load(.availableMetadataFormats)
    }

    func loadMetadataItems(for format: AVMetadataFormat) async throws -> [AVMetadataItem] {
        try await loadMetadata(for: format)
    }
}

/// The result of a remote cover lookup, mirroring the backend's
/// `GET /api/cover` JSON shape (`{"cover_url": <url>|null, "source":
/// "itunes"|"youtube"|null}`). `source` is decoded but currently unused by
/// the caller; kept for parity/debuggability.
struct RemoteCoverResult: Decodable, Equatable {
    let coverURL: URL?
    let source: String?

    private enum CodingKeys: String, CodingKey {
        case coverURL = "cover_url"
        case source
    }
}

/// Fetches a best-effort remote cover image for a (title, artist, duration)
/// triple, expressed as a plain async function so tests can inject a double
/// that never touches the network (mirroring `MetadataLoading` /
/// `loadArtworkData`'s testability seam). Returns raw image bytes, or nil on
/// any miss/failure — this seam never throws.
protocol CoverFetching {
    func fetchCoverImageData(title: String, artist: String?, durationSeconds: Double?) async -> Data?
}

/// Production implementation: calls the backend's `/api/cover` endpoint,
/// then downloads the returned image URL. Best-effort end to end — any
/// network/decode error along the way yields `nil` rather than throwing.
struct BackendCoverFetcher: CoverFetching {
    /// Short timeout so a slow/unreachable backend never blocks import or
    /// the self-heal pass for long.
    private static let requestTimeout: TimeInterval = 8

    func fetchCoverImageData(title: String, artist: String?, durationSeconds: Double?) async -> Data? {
        guard let coverURL = await lookupCoverURL(title: title, artist: artist, durationSeconds: durationSeconds) else {
            return nil
        }
        return await downloadImageData(from: coverURL)
    }

    private func lookupCoverURL(title: String, artist: String?, durationSeconds: Double?) async -> URL? {
        var components = URLComponents(string: "\(PlayerManager.backendURL)/api/cover")
        var queryItems = [URLQueryItem(name: "title", value: title)]
        // A title-only query is low quality; still attempt it if the track
        // genuinely has no usable artist (nil / empty / the local-import
        // placeholder "This Device"), since a title-only hit is still better
        // than no cover at all.
        if let artist, !artist.isEmpty, artist != "This Device" {
            queryItems.append(URLQueryItem(name: "artist", value: artist))
        }
        if let durationSeconds, durationSeconds > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(durationSeconds)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        if let apiKey = PlayerManager.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(RemoteCoverResult.self, from: data)
            return decoded.coverURL
        } catch {
            return nil
        }
    }

    private func downloadImageData(from url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        if let apiKey = PlayerManager.apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

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

    /// Bump when `LocalTrack`'s on-disk shape needs a migration.
    /// - v1 = first versioned envelope (migrated from the legacy bare-array file).
    /// - v2 = artwork stored as a stable relative `artworkFileName` instead of an
    ///   absolute `artworkURL` (which went stale across app-container UUID
    ///   changes). `LocalTrack.init(from:)` migrates old `artworkURL` entries by
    ///   keeping only the file name; the next save rewrites in the new shape.
    static let schemaVersion = 2

    @Published private(set) var tracks: [LocalTrack] = []

    private let store: KeyValueStore
    private let libraryDirectory: URL
    private let fileManager: FileManager
    private let isCloudFileNotDownloaded: (URL) -> Bool
    /// Loads embedded artwork bytes from an audio file URL. Injectable so
    /// the self-heal path is unit-testable without real audio fixtures; the
    /// default reads the file via `AVURLAsset` + `loadArtworkData`.
    private let loadArtworkData: (URL) async -> Data?
    /// Fetches a best-effort remote cover for tracks with no embedded
    /// artwork. Injectable so tests never hit the network; the default is
    /// `BackendCoverFetcher`, which calls the `/api/cover` backend endpoint.
    private let coverFetcher: CoverFetching
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
        isCloudFileNotDownloaded: @escaping (URL) -> Bool = LocalLibraryManager.defaultIsCloudFileNotDownloaded(_:),
        loadArtworkData: @escaping (URL) async -> Data? = LocalLibraryManager.defaultLoadArtworkData(from:),
        coverFetcher: CoverFetching = BackendCoverFetcher()
    ) {
        self.store = store
        self.libraryDirectory = libraryDirectory
        self.sampleDataDirectory = libraryDirectory.deletingLastPathComponent()
            .appendingPathComponent(libraryDirectory.lastPathComponent + ".sampleData")
        self.fileManager = fileManager
        self.isCloudFileNotDownloaded = isCloudFileNotDownloaded
        self.loadArtworkData = loadArtworkData
        self.coverFetcher = coverFetcher
        self.saveDebouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
        try? fileManager.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: sampleDataDirectory, withIntermediateDirectories: true)
        load()
        auditMissingFlags()
        cleanupOrphans()
        healMissingArtwork()
        backfillRemoteCovers()
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

    /// Default artwork-data loader: reads the audio file at `url` via
    /// `AVURLAsset` and extracts embedded artwork bytes. Injected so the
    /// self-heal/extraction paths can be tested without real audio files.
    nonisolated static func defaultLoadArtworkData(from url: URL) async -> Data? {
        await loadArtworkData(from: AVURLAsset(url: url))
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
        var artworkFileName = await extractArtwork(from: destURL, trackID: id)
        if artworkFileName == nil {
            artworkFileName = await fetchRemoteCover(
                trackID: id, title: title, artist: artist, durationSeconds: duration
            )
        }

        let track = LocalTrack(
            id: id,
            title: title,
            artist: artist,
            artworkFileName: artworkFileName,
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
        if let artworkURL = artworkURL(for: track) {
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
        if let art = artworkURL(for: old), fileManager.fileExists(atPath: art.path) {
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
            artworkFileName: nil,
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

    /// Reconstructs the absolute artwork URL for a track by resolving its
    /// stable `artworkFileName` against the *current* `libraryDirectory`'s
    /// `artwork/` subdir. Returns `nil` if the track has no artwork.
    ///
    /// Mirrors `fileURL(for:)`: the absolute path is re-derived at access
    /// time, so it stays valid across app-container UUID changes (reinstall
    /// / dev-rebuild) — the bug that left persisted absolute artwork URLs
    /// dangling. Note the file may still be absent on disk (e.g. after a
    /// container change wiped the old `artwork/` dir); `healMissingArtwork`
    /// re-extracts those from the still-present audio file.
    func artworkURL(for track: LocalTrack) -> URL? {
        guard let name = track.artworkFileName, !name.isEmpty else { return nil }
        return libraryDirectory
            .appendingPathComponent("artwork", isDirectory: true)
            .appendingPathComponent(name)
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
                artworkFileName: track.artworkFileName,
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
            guard let name = track.artworkFileName, !name.isEmpty else { return nil }
            return name
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

    /// Extracts embedded artwork from the audio file at `fileURL` and
    /// writes it to `libraryDirectory/artwork/<uuid>.<ext>`. Returns the
    /// bare on-disk **file name** (`"<uuid>.<ext>"`, never an absolute
    /// path — see `LocalTrack`'s doc), or nil if the file has no artwork
    /// or the extraction failed. Best-effort; a missing artwork file is
    /// not considered an error.
    ///
    /// Checks, in order, until artwork bytes are found:
    /// 1. The common-identifier artwork item (`AVMetadataIdentifier
    ///    .commonIdentifierArtwork`) — covers most containers in one shot.
    /// 2. Every format-specific metadata set the asset exposes (ID3 `APIC`,
    ///    iTunes `covr`, QuickTime/ISO user data, etc.) — covers MP3/FLAC/
    ///    MP4 files whose artwork isn't surfaced as common metadata.
    /// 3. The legacy `.commonMetadata` / `commonKey == "artwork"` path, kept
    ///    as a final fallback for older/unusual assets.
    private func extractArtwork(from fileURL: URL, trackID: UUID) async -> String? {
        guard let data = await loadArtworkData(fileURL), !data.isEmpty else { return nil }
        return writeArtwork(data: data, trackID: trackID)
    }

    /// Writes artwork `data` to `libraryDirectory/artwork/<uuid>.<ext>`
    /// (ext sniffed from magic bytes) and returns the bare file name, or
    /// nil on empty data / a write failure. Synchronous and side-effecting
    /// but does not touch the `tracks` array — callers update the model.
    private func writeArtwork(data: Data, trackID: UUID) -> String? {
        guard !data.isEmpty else { return nil }
        let artworkDir = libraryDirectory.appendingPathComponent("artwork", isDirectory: true)
        do {
            try fileManager.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let ext = Self.artworkFileExtension(for: data)
        let name = "\(trackID.uuidString).\(ext)"
        let dest = artworkDir.appendingPathComponent(name)
        do {
            try AtomicFileWriter.writeAtomically(data, to: dest)
            return name
        } catch {
            return nil
        }
    }

    // MARK: - Artwork self-heal

    /// Recovers artwork that went missing on disk while the audio file is
    /// still present — the exact situation after an app-container UUID
    /// change (reinstall / dev-rebuild), which leaves persisted artwork
    /// pointing at a dead container whose `artwork/` dir is gone, even
    /// though audio still resolves by file name against the live container.
    ///
    /// For every track whose audio file exists but whose resolved artwork
    /// file does NOT, this re-extracts artwork from the current audio file
    /// and rewrites it into the live `artwork/` dir, updating
    /// `artworkFileName`. Fire-and-forget, best-effort, debounced save;
    /// never throws and never blocks `init`.
    private func healMissingArtwork() {
        // Snapshot the candidate IDs synchronously so we don't capture the
        // mutable array across the await boundary.
        let candidates = tracks.compactMap { track -> UUID? in
            // Only heal tracks whose audio is actually present.
            guard fileManager.fileExists(atPath: fileURL(for: track).path) else { return nil }
            // Skip tracks whose artwork is already on disk.
            if let art = artworkURL(for: track), fileManager.fileExists(atPath: art.path) {
                return nil
            }
            return track.id
        }
        guard !candidates.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            for id in candidates {
                await self.reextractArtwork(for: id)
            }
        }
    }

    /// Re-extracts artwork for a single track id from its current audio
    /// file and, on success, updates the in-memory track + persists.
    /// No-op if the track vanished, already has on-disk artwork, or has no
    /// extractable artwork. Best-effort; never throws.
    private func reextractArtwork(for id: UUID) async {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        // Re-check on-disk state (it may have been healed since snapshot).
        if let art = artworkURL(for: track), fileManager.fileExists(atPath: art.path) {
            return
        }
        let audioURL = fileURL(for: track)
        guard fileManager.fileExists(atPath: audioURL.path) else { return }

        guard let data = await loadArtworkData(audioURL), !data.isEmpty,
              let name = writeArtwork(data: data, trackID: track.id) else {
            return
        }

        // Re-find the index (array may have shifted) and patch in place.
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        let current = tracks[idx]
        tracks[idx] = LocalTrack(
            id: current.id,
            title: current.title,
            artist: current.artist,
            artworkFileName: name,
            fileName: current.fileName,
            importedAt: current.importedAt,
            fileSizeBytes: current.fileSizeBytes,
            durationSeconds: current.durationSeconds,
            album: current.album,
            isMissing: current.isMissing
        )
        save()
    }

    // MARK: - Remote cover fallback (/api/cover)

    /// Track IDs a remote-cover fetch has already been attempted for during
    /// this process lifetime. Prevents `backfillRemoteCovers` from
    /// re-attempting the same failed lookup in a loop within one launch; a
    /// track that failed here is still retried on the *next* launch (this
    /// set is not persisted), per the "best-effort, offline-safe" contract.
    private var attemptedRemoteCoverTrackIDs: Set<UUID> = []

    /// Best-effort remote cover fetch for a track that has no embedded
    /// artwork. Builds the `/api/cover` query from title/artist/duration,
    /// downloads the returned image (if any), writes it via the same
    /// `writeArtwork` helper used for embedded extraction, and returns the
    /// bare on-disk file name — or nil on any miss/failure. Never throws.
    private func fetchRemoteCover(
        trackID: UUID,
        title: String,
        artist: String?,
        durationSeconds: Double?
    ) async -> String? {
        attemptedRemoteCoverTrackIDs.insert(trackID)
        guard let data = await coverFetcher.fetchCoverImageData(
            title: title, artist: artist, durationSeconds: durationSeconds
        ), !data.isEmpty else {
            return nil
        }
        return writeArtwork(data: data, trackID: trackID)
    }

    /// Opportunistically fills in remote covers for existing tracks that
    /// have no artwork at all (no embedded art was ever extracted, and
    /// `healMissingArtwork` above didn't find any to re-extract either).
    /// Fire-and-forget, off the main actor's synchronous init path, debounced
    /// save; needs network — a no-op when offline, retried on the next
    /// launch. Guards against refetching tracks that already have a cover
    /// file, and against attempting a track more than once per launch.
    private func backfillRemoteCovers() {
        let candidates = tracks.compactMap { track -> UUID? in
            // Skip tracks that already have artwork on disk.
            if let art = artworkURL(for: track), fileManager.fileExists(atPath: art.path) {
                return nil
            }
            guard !attemptedRemoteCoverTrackIDs.contains(track.id) else { return nil }
            return track.id
        }
        guard !candidates.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }
            for id in candidates {
                await self.backfillRemoteCover(for: id)
            }
        }
    }

    /// Backfills a remote cover for a single existing track id, if it still
    /// has none. No-op if the track vanished, already has on-disk artwork,
    /// or the remote fetch misses. Best-effort; never throws.
    private func backfillRemoteCover(for id: UUID) async {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        // Re-check on-disk state (it may have been healed/backfilled since snapshot).
        if let art = artworkURL(for: track), fileManager.fileExists(atPath: art.path) {
            return
        }

        guard let name = await fetchRemoteCover(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            durationSeconds: track.durationSeconds
        ) else {
            return
        }

        // Re-find the index (array may have shifted) and patch in place.
        guard let idx = tracks.firstIndex(where: { $0.id == id }) else { return }
        let current = tracks[idx]
        // Don't clobber artwork that arrived (e.g. via healMissingArtwork)
        // while this fetch was in flight.
        if let art = artworkURL(for: current), fileManager.fileExists(atPath: art.path) {
            return
        }
        tracks[idx] = LocalTrack(
            id: current.id,
            title: current.title,
            artist: current.artist,
            artworkFileName: name,
            fileName: current.fileName,
            importedAt: current.importedAt,
            fileSizeBytes: current.fileSizeBytes,
            durationSeconds: current.durationSeconds,
            album: current.album,
            isMissing: current.isMissing
        )
        save()
    }

    /// Loads embedded artwork bytes from `asset` by trying the
    /// common-identifier item, then every format-specific metadata set
    /// the asset advertises, then the legacy common-metadata path. Returns
    /// nil if no artwork bytes can be found anywhere. Never throws.
    ///
    /// Generic over `MetadataLoading` (which `AVURLAsset` conforms to via
    /// `AVAsynchronousKeyValueLoading`) so tests can inject a synthetic
    /// asset double instead of needing real audio fixtures.
    static func loadArtworkData(from asset: some MetadataLoading) async -> Data? {
        // 1. Common-identifier artwork (works across most containers) —
        // filter the full per-asset metadata set by the well-known
        // artwork identifier.
        if let allItems = try? await asset.loadAllMetadataItems() {
            let commonArtworkItems = AVMetadataItem.metadataItems(
                from: allItems,
                filteredByIdentifier: .commonIdentifierArtwork
            )
            if let data = await Self.firstArtworkData(in: commonArtworkItems) {
                return data
            }
            // Same data, scanned via the broader identifier/key heuristics
            // (covers formats whose artwork isn't tagged with the common
            // identifier but does show up in the full metadata set).
            let heuristicItems = allItems.filter { Self.isArtworkItem($0) }
            if let data = await Self.firstArtworkData(in: heuristicItems) {
                return data
            }
        }

        // 2. Format-specific metadata sets (ID3 APIC, iTunes covr, etc.) —
        // some assets only surface artwork when queried per-format rather
        // than via the combined `.metadata` key.
        if let formats = try? await asset.loadAvailableMetadataFormats() {
            for format in formats {
                guard let items = try? await asset.loadMetadataItems(for: format) else { continue }
                let artworkItems = items.filter { Self.isArtworkItem($0) }
                if let data = await Self.firstArtworkData(in: artworkItems) {
                    return data
                }
            }
        }

        // 3. Legacy fallback: scan common metadata for `commonKey == "artwork"`.
        if let metadata = try? await asset.loadCommonMetadataItems() {
            let artworkItems = metadata.filter { $0.commonKey?.rawValue == "artwork" }
            if let data = await Self.firstArtworkData(in: artworkItems) {
                return data
            }
        }

        return nil
    }

    /// True if `item` represents embedded artwork under any of the
    /// well-known format-specific identifiers/keys: ID3 `APIC`, iTunes
    /// `covr`, QuickTime metadata artwork, or the generic common-artwork
    /// identifier/key.
    private static func isArtworkItem(_ item: AVMetadataItem) -> Bool {
        if item.commonKey?.rawValue == "artwork" { return true }
        if let identifier = item.identifier {
            switch identifier {
            case .commonIdentifierArtwork,
                 .id3MetadataAttachedPicture,
                 .iTunesMetadataCoverArt,
                 .quickTimeMetadataArtwork:
                return true
            default:
                break
            }
        }
        // ID3 keys surface as the raw frame name ("APIC") rather than via
        // `.identifier` in some asset/format combinations.
        if let keyString = item.key as? String, keyString == "APIC" { return true }
        return false
    }

    /// Returns the first non-empty artwork `Data` found among `items`,
    /// trying `dataValue` first and falling back to coercing `value` for
    /// items whose payload isn't surfaced as raw `Data` (e.g. wrapped in
    /// an `NSData`-backed `NSValue`/dictionary on some format paths).
    private static func firstArtworkData(in items: [AVMetadataItem]) async -> Data? {
        for item in items {
            if let data = try? await item.load(.dataValue), !data.isEmpty {
                return data
            }
            if let data = await Self.coerceToData(item) {
                return data
            }
        }
        return nil
    }

    /// Best-effort coercion of an `AVMetadataItem`'s loaded `value` into
    /// `Data`, for the rare items that carry artwork bytes outside
    /// `dataValue` (e.g. as raw `Data`/`NSData` in `.value`).
    private static func coerceToData(_ item: AVMetadataItem) async -> Data? {
        guard let value = try? await item.load(.value) else { return nil }
        if let data = value as? Data, !data.isEmpty { return data }
        if let nsData = value as? NSData, nsData.length > 0 { return nsData as Data }
        return nil
    }

    /// Sniffs `data`'s magic bytes to choose a file extension for the
    /// artwork file. JPEG starts with FF D8 FF; PNG starts with
    /// 89 50 4E 47; GIF starts with "GIF8"; falls back to "img" for any
    /// other (still-valid) image payload.
    static func artworkFileExtension(for data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        } else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        } else if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "gif"
        } else {
            return "img"
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
