import XCTest
@testable import Aria___Music_Browser

final class FolderImporterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func write(_ relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    func test_audioFiles_recursesAndFiltersByExtension() throws {
        try write("a.mp3")
        try write("Album/b.flac")
        try write("Album/Disc 2/c.m4a")
        try write("cover.jpg")
        try write("notes.txt")
        try write("Album/playlist.m3u")

        let found = FolderImporter.audioFiles(in: root).map(\.lastPathComponent)
        XCTAssertEqual(Set(found), ["a.mp3", "b.flac", "c.m4a"],
                       "only audio extensions, recursively")
    }

    func test_audioFiles_isCaseInsensitiveOnExtension() throws {
        try write("LOUD.FLAC")
        XCTAssertEqual(FolderImporter.audioFiles(in: root).count, 1)
    }

    func test_audioFiles_sortedForStableOrder() throws {
        try write("b.mp3")
        try write("a.mp3")
        try write("Album/c.mp3")
        // Full paths are compared with localizedStandardCompare, so "…/a.mp3"
        // precedes "…/Album/c.mp3" ('a' < 'A' is folded, then 'l' > '.').
        // What matters is that the order is deterministic and human-sensible.
        let names = FolderImporter.audioFiles(in: root).map(\.lastPathComponent)
        XCTAssertEqual(names, ["a.mp3", "c.mp3", "b.mp3"])
        XCTAssertEqual(names, FolderImporter.audioFiles(in: root).map(\.lastPathComponent),
                       "repeat enumeration must yield the same order")
    }

    func test_audioFiles_numericFileNamesSortNaturally() throws {
        try write("Album/2 - Track.mp3")
        try write("Album/10 - Track.mp3")
        let names = FolderImporter.audioFiles(in: root).map(\.lastPathComponent)
        XCTAssertEqual(names, ["2 - Track.mp3", "10 - Track.mp3"],
                       "track 2 before track 10, not lexicographic")
    }

    func test_audioFiles_emptyFolderReturnsEmpty() {
        XCTAssertTrue(FolderImporter.audioFiles(in: root).isEmpty)
    }

    func test_importAll_countsImportedAndSkipped_andKeepsGoingAfterFailure() async throws {
        try write("good1.mp3")
        try write("bad.flac")
        try write("good2.m4a")

        var progressUpdates: [FolderImporter.Progress] = []
        let result = await FolderImporter.importAll(
            from: root,
            importFile: { url in
                if url.lastPathComponent == "bad.flac" {
                    throw ImportError.unsupportedFormat(format: .unknown)
                }
            },
            onProgress: { progressUpdates.append($0) }
        )

        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.imported, 2, "a mid-run failure must not abort the import")
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(progressUpdates.first?.total, 3, "total is known up front")
        XCTAssertEqual(progressUpdates.count, 4, "initial + one per file")
    }

    func test_importAll_emptyFolder_reportsZeroTotal() async {
        let result = await FolderImporter.importAll(
            from: root, importFile: { _ in }, onProgress: { _ in })
        XCTAssertEqual(result, FolderImporter.Progress(imported: 0, skipped: 0, total: 0))
    }
}
