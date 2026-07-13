import Foundation
import Combine

/// Owns offline downloads: caches a streamed track's audio (by YouTube video id)
/// into the app sandbox and tracks which tracks are available offline.
///
/// A download is "save-offline, same track": the `Track` keeps its identity and
/// `PlayerManager` prefers the local copy at play time (see `localURL(for:)`).
///
/// v1 fetches the audio with a single buffered request through `URLSessionProtocol`
/// (a song is a few MB) and reports coarse (`.downloading`) progress. Chunked /
/// determinate-progress download is a future refinement.
final class DownloadManager: ObservableObject {
    /// Bump when `DownloadRecord`'s on-disk shape needs a migration.
    static let schemaVersion = 1

    /// Downloaded tracks, newest first. Drives the Library "YouTube Downloads" section.
    @Published private(set) var records: [DownloadRecord] = []
    /// Video ids with an in-flight download.
    @Published private(set) var active: Set<String> = []
    /// Last user-visible download error; `ContentView` surfaces + clears it.
    @Published var lastError: String?

    private let store: KeyValueStore
    private let downloadsDir: URL
    private let urlSession: URLSessionProtocol
    private let backendURL: String
    private let apiKey: String?
    private var debouncer: Debouncer!
    private var byID: [String: DownloadRecord] = [:]

    private static let minValidBytes = 1024
    private static let videoIDPattern = "^[A-Za-z0-9_-]{11}$"

    enum DownloadError: LocalizedError {
        case badEndpoint, server(Int), malformedResponse, tooSmall
        var errorDescription: String? {
            switch self {
            case .badEndpoint: return "Invalid backend URL"
            case .server(let s): return "Server error \(s)"
            case .malformedResponse: return "Unexpected server response"
            case .tooSmall: return "Downloaded file was incomplete"
            }
        }
    }

    init(
        store: KeyValueStore = JSONFileStore(filename: "downloads.json"),
        downloadsDirectory: URL? = nil,
        urlSession: URLSessionProtocol = DownloadManager.defaultSession(),
        backendURL: String = PlayerManager.backendURL,
        apiKey: String? = PlayerManager.apiKey
    ) {
        self.store = store
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.downloadsDir = downloadsDirectory ?? docs.appendingPathComponent("Downloads", isDirectory: true)
        self.urlSession = urlSession
        self.backendURL = backendURL
        self.apiKey = apiKey
        try? FileManager.default.createDirectory(at: self.downloadsDir, withIntermediateDirectories: true)
        self.debouncer = Debouncer(delay: 0.5) { [weak self] in self?.performSave() }
        load()
        reconcile()
    }

    // flush() is a no-op in deinit (its [weak self] is already nil); save direct.
    deinit { if debouncer?.isPending == true { performSave() } }

    static func defaultSession() -> URLSessionProtocol {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300  // a download can take a while
        return URLSessionAdapter(session: URLSession(configuration: config))
    }

    // MARK: - Queries

    func isDownloaded(_ videoID: String) -> Bool { byID[videoID] != nil }

    func state(for videoID: String) -> DownloadState {
        if active.contains(videoID) { return .downloading }
        return byID[videoID] != nil ? .downloaded : .none
    }

    /// The on-disk file for a downloaded track, or `nil`. `PlayerManager` calls
    /// this before resolving a streamed track and plays the file if present.
    func localURL(for videoID: String) -> URL? {
        guard let rec = byID[videoID] else { return nil }
        let url = downloadsDir.appendingPathComponent(rec.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Download / remove

    func download(_ track: Track) async {
        let id = track.id
        guard !track.isLocal,
              id.range(of: Self.videoIDPattern, options: .regularExpression) != nil,
              byID[id] == nil, !active.contains(id) else { return }

        active.insert(id)
        defer { active.remove(id) }

        do {
            // 1. Ask the backend to download + validate + cache; get the stream path.
            guard let playURL = URL(string: "\(backendURL)/api/play?video_id=\(id)") else {
                throw DownloadError.badEndpoint
            }
            let (playData, playResp) = try await withRetry {
                try await self.urlSession.data(for: .backendGET(playURL, apiKey: self.apiKey))
            }
            try Self.validate(playResp, playData)
            guard let json = try? JSONSerialization.jsonObject(with: playData) as? [String: Any],
                  let streamPath = json["url"] as? String else {
                throw DownloadError.malformedResponse
            }

            // 2. Fetch the cached audio bytes.
            guard let streamURL = URL(string: "\(backendURL)\(streamPath)") else {
                throw DownloadError.badEndpoint
            }
            let (audio, audioResp) = try await withRetry {
                try await self.urlSession.data(for: .backendGET(streamURL, apiKey: self.apiKey))
            }
            try Self.validate(audioResp, audio)
            guard audio.count >= Self.minValidBytes else { throw DownloadError.tooSmall }

            // 3. Write to disk (atomic) keyed by video id.
            let ext = (streamPath as NSString).pathExtension
            let fileName = ext.isEmpty ? "\(id).m4a" : "\(id).\(ext)"
            let fileURL = downloadsDir.appendingPathComponent(fileName)
            try audio.write(to: fileURL, options: .atomic)

            // 4. Record it.
            let rec = DownloadRecord(
                videoID: id, fileName: fileName, sizeBytes: Int64(audio.count),
                downloadedAt: Date(), title: track.title, artist: track.artist,
                thumbnailURL: track.thumbnailURL
            )
            records.removeAll { $0.videoID == id }
            records.insert(rec, at: 0)
            byID[id] = rec
            save()
        } catch is CancellationError {
            // Superseded / cancelled — leave no partial state.
        } catch {
            deleteFile(forID: id)
            lastError = "Couldn't download “\(track.title)”: \(error.localizedDescription)"
        }
    }

    func remove(_ videoID: String) {
        deleteFile(forID: videoID)
        records.removeAll { $0.videoID == videoID }
        byID[videoID] = nil
        save()
    }

    func flushPendingWrites() { debouncer?.flush() }

    // MARK: - Persistence

    private func load() {
        let loaded = SchemaStore.loadItems(DownloadRecord.self, from: store, currentVersion: Self.schemaVersion) ?? []
        records = loaded
        byID = Dictionary(loaded.map { ($0.videoID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() { debouncer.call() }

    private func performSave() {
        guard let data = try? SchemaStore.encode(records, schemaVersion: Self.schemaVersion) else { return }
        try? store.save(data)
    }

    /// Drop records whose file has vanished, and delete orphan files with no
    /// record (leaked bytes from a crash mid-write). Runs once at init.
    private func reconcile() {
        var changed = false
        for rec in records where !FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent(rec.fileName).path) {
            records.removeAll { $0.videoID == rec.videoID }
            byID[rec.videoID] = nil
            changed = true
        }
        let known = Set(records.map(\.fileName))
        if let files = try? FileManager.default.contentsOfDirectory(atPath: downloadsDir.path) {
            for f in files where !known.contains(f) {
                try? FileManager.default.removeItem(at: downloadsDir.appendingPathComponent(f))
            }
        }
        if changed { save() }
    }

    // MARK: - Helpers

    private func deleteFile(forID id: String) {
        if let rec = byID[id] {
            try? FileManager.default.removeItem(at: downloadsDir.appendingPathComponent(rec.fileName))
        }
    }

    private static func validate(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.server(http.statusCode)
        }
    }
}
