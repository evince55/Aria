import XCTest
@testable import Aria___Music_Browser

@MainActor
final class DownloadManagerTests: XCTestCase {
    private var tmp: URL!
    private var store: InMemoryKeyValueStore!
    private var session: MockURLSession!

    override func setUp() async throws {
        try await super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dl_\(UUID().uuidString)")
        store = InMemoryKeyValueStore()
        session = MockURLSession()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
        try await super.tearDown()
    }

    private func makeManager() -> DownloadManager {
        DownloadManager(store: store, downloadsDirectory: tmp, urlSession: session,
                        resolveBackendURL: { "http://test.local" }, resolveAPIKey: { nil })
    }

    private func track(_ id: String = "dQw4w9WgXcQ") -> Track {
        Track(id: id, title: "Song", artist: "Artist", thumbnailURL: nil)
    }

    private func ok(_ url: URL) -> URLResponse {
        URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }

    /// Route `/api/play` → stream-path JSON, `/api/stream/…` → audio bytes.
    private func wireHappyPath(audio: Data = Data(repeating: 0x41, count: 4096)) {
        session.dataFromHandler = { url in
            if url.absoluteString.contains("/api/play") {
                let json = try! JSONSerialization.data(
                    withJSONObject: ["url": "/api/stream/dQw4w9WgXcQ.bestaudio.m4a", "cached": false])
                return (json, self.ok(url))
            }
            return (audio, self.ok(url))
        }
    }

    /// Regression: `DownloadManager` is built once at app launch, normally before
    /// a new user has entered a server. A download must use the server and key
    /// configured now, not the placeholder resolved at launch, which iOS rejects
    /// in Release builds as an App Transport Security violation.
    func test_downloadUsesServerConfiguredAfterInit() async {
        let defaults = UserDefaults.standard
        let keys = [BackendConfig.urlOverrideKey, BackendConfig.apiKeyOverrideKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }

        wireHappyPath()
        let m = DownloadManager(store: store, downloadsDirectory: tmp, urlSession: session)

        defaults.set("https://server.example", forKey: BackendConfig.urlOverrideKey)
        defaults.set("entered-after-launch", forKey: BackendConfig.apiKeyOverrideKey)
        await m.download(track())

        let requests = session.recordedRequestObjects
        XCTAssertEqual(requests.map(\.url?.host), ["server.example", "server.example"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "X-API-Key") },
                       ["entered-after-launch", "entered-after-launch"])
        XCTAssertTrue(m.isDownloaded("dQw4w9WgXcQ"))
    }

    func test_downloadWritesRecordAndFile() async {
        wireHappyPath()
        let m = makeManager()
        await m.download(track())
        XCTAssertEqual(m.records.map(\.videoID), ["dQw4w9WgXcQ"])
        XCTAssertTrue(m.isDownloaded("dQw4w9WgXcQ"))
        XCTAssertEqual(m.state(for: "dQw4w9WgXcQ"), .downloaded)
        let url = m.localURL(for: "dQw4w9WgXcQ")
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func test_downloadGuardsLocalAndBadID() async {
        wireHappyPath()
        let m = makeManager()
        await m.download(Track(id: "local:x", title: "L", artist: "A",
                               localFileURL: URL(fileURLWithPath: "/tmp/x.mp3")))
        await m.download(Track(id: "short", title: "B", artist: "A"))  // not an 11-char id
        XCTAssertTrue(m.records.isEmpty)
    }

    func test_removeDeletesFileAndRecord() async {
        wireHappyPath()
        let m = makeManager()
        await m.download(track())
        let url = m.localURL(for: "dQw4w9WgXcQ")!
        m.remove("dQw4w9WgXcQ")
        XCTAssertTrue(m.records.isEmpty)
        XCTAssertNil(m.localURL(for: "dQw4w9WgXcQ"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_reconcileDropsRecordWhenFileMissing() {
        let rec = DownloadRecord(videoID: "dQw4w9WgXcQ", fileName: "dQw4w9WgXcQ.m4a",
                                 sizeBytes: 100, downloadedAt: Date(), title: "S", artist: "A", thumbnailURL: nil)
        let seeded = InMemoryKeyValueStore(
            seed: try! SchemaStore.encode([rec], schemaVersion: DownloadManager.schemaVersion))
        let m = DownloadManager(store: seeded, downloadsDirectory: tmp, urlSession: session,
                                resolveBackendURL: { "http://t" }, resolveAPIKey: { nil })
        XCTAssertTrue(m.records.isEmpty)  // file never existed → dropped
        XCTAssertNil(m.localURL(for: "dQw4w9WgXcQ"))
    }

    func test_downloadServerErrorSetsErrorNoRecord() async {
        session.dataFromHandler = { url in
            (Data("err".utf8), HTTPURLResponse(url: url, statusCode: 502, httpVersion: nil, headerFields: nil)!)
        }
        let m = makeManager()
        await m.download(track())
        XCTAssertTrue(m.records.isEmpty)
        XCTAssertNotNil(m.lastError)
    }
}
