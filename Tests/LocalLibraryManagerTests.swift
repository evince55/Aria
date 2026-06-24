import XCTest
@testable import Aria___Music_Browser

@MainActor
final class LocalLibraryManagerTests: XCTestCase {

    private var tmpDir: URL!
    private var libraryDir: URL!
    private var store: InMemoryKeyValueStore!
    private var manager: LocalLibraryManager!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("local_library_test_\(UUID().uuidString)")
        libraryDir = tmpDir.appendingPathComponent("AriaLibrary")
        store = InMemoryKeyValueStore()
        manager = LocalLibraryManager(store: store, libraryDirectory: libraryDir)
    }

    override func tearDown() async throws {
        manager = nil
        store = nil
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Writes `data` to a fresh temp file with the given extension and
    /// returns the URL. Caller is responsible for cleanup (the test's
    /// tearDown wipes `tmpDir`).
    private func makeSourceFile(data: Data = Data(repeating: 0x42, count: 1024), ext: String = "mp3") throws -> URL {
        let url = tmpDir.appendingPathComponent("source_\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    // MARK: - Init

    func test_init_emptyListWhenStoreIsEmpty() {
        XCTAssertTrue(manager.tracks.isEmpty)
    }

    func test_init_loadsFromStore() {
        // Pre-seed the store with a saved track list, then create a
        // fresh manager.
        let saved = LocalTrack(
            id: UUID(),
            title: "Pre-existing",
            artist: "Test",
            fileName: "abc.mp3",
            importedAt: Date(),
            fileSizeBytes: 1234,
            durationSeconds: 60
        )
        let data = try! JSONEncoder().encode([saved])
        let seedStore = InMemoryKeyValueStore(seed: data)
        let m = LocalLibraryManager(store: seedStore, libraryDirectory: libraryDir)
        XCTAssertEqual(m.tracks.count, 1)
        XCTAssertEqual(m.tracks.first?.title, "Pre-existing")
    }

    func test_init_createsLibraryDirectory() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryDir.path))
    }

    // MARK: - Import

    func test_import_copiesFileIntoLibrary() async throws {
        let source = try makeSourceFile(data: Data(repeating: 0x42, count: 2048), ext: "mp3")
        let track = try await manager.importFile(at: source)
        let dest = manager.fileURL(for: track)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "copied file should exist on disk")
        // Compare via `.path` (which normalizes trailing slashes) since
        // `URL.deletingLastPathComponent` may add a trailing slash that
        // `libraryDir` doesn't have.
        XCTAssertEqual(dest.deletingLastPathComponent().path, libraryDir.path)
    }

    func test_import_addsToFrontOfList() async throws {
        let s1 = try makeSourceFile()
        let s2 = try makeSourceFile()
        _ = try await manager.importFile(at: s1)
        let t2 = try await manager.importFile(at: s2)
        XCTAssertEqual(manager.tracks.count, 2)
        // Most recent first.
        XCTAssertEqual(manager.tracks.first?.id, t2.id)
    }

    func test_import_extractsTitleFromFilename() async throws {
        let url = tmpDir.appendingPathComponent("My Cool Track.mp3")
        try Data().write(to: url)
        let track = try await manager.importFile(at: url)
        XCTAssertEqual(track.title, "My Cool Track")
    }

    func test_import_setsImportedAt() async throws {
        let source = try makeSourceFile()
        let before = Date()
        let track = try await manager.importFile(at: source)
        let after = Date()
        XCTAssertGreaterThanOrEqual(track.importedAt, before)
        XCTAssertLessThanOrEqual(track.importedAt, after)
    }

    func test_import_persistsAcrossInstances() async throws {
        let source = try makeSourceFile()
        _ = try await manager.importFile(at: source)
        // Drain the debounced save.
        manager.flushPendingWrites()
        // Recreate with the same backing store.
        let m2 = LocalLibraryManager(store: store, libraryDirectory: libraryDir)
        XCTAssertEqual(m2.tracks.count, 1)
    }

    // MARK: - Remove

    func test_remove_deletesFileAndTrack() async throws {
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        let dest = manager.fileURL(for: track)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        manager.remove(track)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertTrue(manager.tracks.isEmpty)
    }

    func test_remove_persists() async throws {
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        manager.remove(track)
        manager.flushPendingWrites()
        let m2 = LocalLibraryManager(store: store, libraryDirectory: libraryDir)
        XCTAssertTrue(m2.tracks.isEmpty)
    }

    // MARK: - fileURL

    func test_fileURL_returnsPathInsideLibraryDirectory() async throws {
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        let url = manager.fileURL(for: track)
        XCTAssertEqual(url.deletingLastPathComponent().path, libraryDir.path)
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".mp3"))
    }
}
