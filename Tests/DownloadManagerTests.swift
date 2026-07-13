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
                        backendURL: "http://test.local", apiKey: nil)
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
                                backendURL: "http://t", apiKey: nil)
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
