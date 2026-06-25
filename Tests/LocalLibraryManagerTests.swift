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
            artworkURL: nil,
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
        try Data(repeating: 0x00, count: 1024).write(to: url)
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

    // MARK: - Artwork

    func test_import_fileWithoutArtworkSetsArtworkURLNil() async throws {
        // The synthetic test fixture has no embedded artwork.
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        XCTAssertNil(track.artworkURL, "no embedded artwork -> artworkURL is nil")
    }

    func test_remove_deletesArtworkFile() async throws {
        // Set up an artwork file on disk for a track, then remove.
        let source = try makeSourceFile()
        var track = try await manager.importFile(at: source)
        let artworkURL = libraryDir.appendingPathComponent("artwork").appendingPathComponent("\(track.id.uuidString).jpg")
        try FileManager.default.createDirectory(at: artworkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A 1x1 JPEG.
        let jpegBytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        try Data(jpegBytes).write(to: artworkURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artworkURL.path))

        // Mutate the track in-memory to attach the artwork URL, then remove.
        track = LocalTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            artworkURL: artworkURL,
            fileName: track.fileName,
            importedAt: track.importedAt,
            fileSizeBytes: track.fileSizeBytes,
            durationSeconds: track.durationSeconds
        )
        // Replace the in-memory track: the manager's `tracks` array
        // holds the unmodified track, so we re-add with the artwork
        // baked in.
        manager.remove(track)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artworkURL.path))
    }

    // MARK: - Album metadata (B3)

    func test_import_populatesAlbumField() async throws {
        // The synthetic fixture is not a real audio file, so AVAsset.load
        // returns no metadata. The field is populated (the readAlbum call
        // runs without crashing) and the fallback is nil. This confirms the
        // importFile plumbing reaches the LocalTrack initializer; a
        // positive case requires a real .mp3/.flac fixture which is out of
        // scope for this test file.
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        // album is Optional<String>; the absence of a crash is the assertion.
        XCTAssertNil(track.album, "synthetic fixture has no album metadata")
    }

    // MARK: - auditMissingFlags (B1 Task 2)

    func test_audit_emptyLibrary_noError() {
        manager.auditMissingFlags()
        XCTAssertTrue(manager.tracks.allSatisfy { !$0.isMissing })
    }

    func test_audit_marksFileGoneAfterDeletion() async throws {
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        let dest = manager.fileURL(for: track)

        XCTAssertFalse(manager.tracks[0].isMissing)

        try FileManager.default.removeItem(at: dest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))

        manager.auditMissingFlags()
        XCTAssertTrue(manager.tracks[0].isMissing)
    }

    func test_audit_idempotent() async throws {
        let source = try makeSourceFile()
        _ = try await manager.importFile(at: source)

        manager.auditMissingFlags()
        let first = manager.tracks.map(\.isMissing)
        manager.auditMissingFlags()
        let second = manager.tracks.map(\.isMissing)
        XCTAssertEqual(first, second)
    }

    // MARK: - LocalTrack fields (B1 Task 1)

    func test_localTrack_isMissingDefaultsFalse() {
        let track = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkURL: nil,
            fileName: "f.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        XCTAssertFalse(track.isMissing)
        XCTAssertNil(track.album)
    }

    func test_localTrack_codableRoundTrip_preservesIsMissingAndAlbum() throws {
        let original = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkURL: nil,
            fileName: "f.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30,
            album: "Greatest Hits",
            isMissing: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LocalTrack.self, from: data)
        XCTAssertEqual(decoded.album, "Greatest Hits")
        XCTAssertTrue(decoded.isMissing)
    }

    // MARK: - repairMissing (B1 Task 6)

    func test_repairMissing_replacesFileAndClearsFlag() async throws {
        let source = try makeSourceFile(data: Data(repeating: 0, count: 100), ext: "mp3")
        _ = try await manager.importFile(at: source)
        let original = manager.tracks[0]
        XCTAssertFalse(original.isMissing)

        let libraryFile = manager.fileURL(for: original)
        try FileManager.default.removeItem(at: libraryFile)
        manager.auditMissingFlags()
        XCTAssertTrue(manager.tracks[0].isMissing)

        let newSource = try makeSourceFile(data: Data(repeating: 0, count: 200), ext: "mp3")
        let repaired = try manager.repairMissing(trackID: original.id, newFileURL: newSource)
        XCTAssertFalse(repaired.isMissing)
        XCTAssertEqual(repaired.id, original.id, "repair preserves identity")
        XCTAssertGreaterThan(repaired.fileSizeBytes, 0)
        XCTAssertNotEqual(repaired.fileName, original.fileName, "repair generates a new on-disk file")
    }

    func test_repairMissing_actuallyCopiesFileIntoLibrary() async throws {
        let source = try makeSourceFile(data: Data(repeating: 0, count: 100), ext: "mp3")
        _ = try await manager.importFile(at: source)
        let original = manager.tracks[0]

        let oldLibraryFile = manager.fileURL(for: original)
        try FileManager.default.removeItem(at: oldLibraryFile)
        manager.auditMissingFlags()
        XCTAssertTrue(manager.tracks[0].isMissing)

        let newSourceBytes = Data(repeating: 0xAB, count: 256)
        let newSource = try makeSourceFile(data: newSourceBytes, ext: "mp3")
        let repaired = try manager.repairMissing(trackID: original.id, newFileURL: newSource)

        let repairedURL = manager.fileURL(for: repaired)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repairedURL.path),
            "repaired file should exist on disk at the new library path"
        )
        XCTAssertEqual(repairedURL.deletingLastPathComponent().path, libraryDir.path)
        let onDisk = try Data(contentsOf: repairedURL)
        XCTAssertEqual(onDisk, newSourceBytes, "repaired file contents should match the new source")
    }

    /// Regression test for the cleanupOrphans bug: after `repairMissing`,
    /// the track keeps its original `id` but the on-disk file is written
    /// under a fresh UUID. A `cleanupOrphans` keyed on `track.id.uuidString`
    /// would treat the freshly-repaired file as an orphan and delete it.
    func test_repairMissing_thenReinit_preservesFile() async throws {
        let source = try makeSourceFile(data: Data(repeating: 0, count: 100), ext: "mp3")
        _ = try await manager.importFile(at: source)
        let original = manager.tracks[0]

        let oldLibraryFile = manager.fileURL(for: original)
        try FileManager.default.removeItem(at: oldLibraryFile)
        manager.auditMissingFlags()
        XCTAssertTrue(manager.tracks[0].isMissing)

        let newSource = try makeSourceFile(data: Data(repeating: 0xAB, count: 256), ext: "mp3")
        let repaired = try manager.repairMissing(trackID: original.id, newFileURL: newSource)
        let repairedURL = manager.fileURL(for: repaired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repairedURL.path),
                      "precondition: repaired file is on disk before reinit")

        manager.flushPendingWrites()

        // Recreate the manager — this triggers cleanupOrphans().
        manager = LocalLibraryManager(store: store, libraryDirectory: libraryDir)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: repairedURL.path),
            "repaired file must survive cleanupOrphans() on the next init"
        )
        XCTAssertEqual(manager.tracks.count, 1)
        XCTAssertFalse(
            manager.tracks[0].isMissing,
            "repaired track must not be flagged missing after reinit"
        )
        XCTAssertEqual(
            manager.tracks[0].fileName, repaired.fileName,
            "fileName should match the on-disk file (repaired UUID, not original id)"
        )
    }

    // MARK: - AudioFormat (B2)

    func test_formatDetect_mp3() {
        let format = AudioFormat.detect(extension: "mp3")
        XCTAssertEqual(format, .mp3)
        XCTAssertTrue(format.isSupported)
        XCTAssertEqual(format.displayName, "MP3")
    }

    func test_formatDetect_flac() {
        let format = AudioFormat.detect(extension: "flac")
        XCTAssertEqual(format, .flac)
        XCTAssertTrue(format.isSupported)
        XCTAssertEqual(format.displayName, "FLAC")
    }

    func test_formatDetect_ogg_rejected() {
        let format = AudioFormat.detect(extension: "ogg")
        XCTAssertEqual(format, .ogg)
        XCTAssertFalse(format.isSupported)
        XCTAssertEqual(format.displayName, "OGG")
    }

    func test_formatDetect_unknownExtension_probesAVURLAsset() async throws {
        let url = tmpDir.appendingPathComponent("weird_\(UUID().uuidString).dat")
        try Data(repeating: 0, count: 64).write(to: url)
        let format = await AudioFormat.probe(url: url)
        XCTAssertEqual(format, .unknown)
        XCTAssertFalse(format.isSupported)
    }

    // MARK: - Format gate (B2 Task 3)

    func test_import_unsupportedFormat_doesNotCopyFile() async throws {
        let source = try makeSourceFile(data: Data(repeating: 0x42, count: 256), ext: "ogg")
        let filesBefore = (try? FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)) ?? []

        do {
            _ = try await manager.importFile(at: source)
            XCTFail("expected ImportError.unsupportedFormat, but import succeeded")
        } catch let error as ImportError {
            guard case .unsupportedFormat(let format) = error else {
                XCTFail("expected .unsupportedFormat, got \(error)")
                return
            }
            XCTAssertEqual(format, .ogg)
        } catch {
            XCTFail("expected ImportError, got \(error)")
        }

        let filesAfter = (try? FileManager.default.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(filesAfter.count, filesBefore.count, "no file should have been copied into the library directory")
        XCTAssertTrue(manager.tracks.isEmpty, "no track should have been added to the library")
    }

    // MARK: - AtomicFileWriter (B4)

    func test_atomicWrite_noTempOnSuccess() throws {
        let target = tmpDir.appendingPathComponent("payload_\(UUID().uuidString).bin")
        let payload = Data(repeating: 0x42, count: 256)
        try AtomicFileWriter.writeAtomically(payload, to: target)

        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "target file should exist after a successful write")
        XCTAssertEqual(try Data(contentsOf: target), payload,
                       "written bytes should match the input")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.appendingPathExtension("tmp").path),
            "no .tmp file should be left alongside a successful write"
        )
    }

    func test_atomicWrite_rollsBackOnFailure() throws {
        // `libraryDir` is a directory (set up in setUp). moveItem cannot replace
        // a directory with a file, so the rename step must fail. The wrapper
        // must remove the .tmp it created before rethrowing.
        let tempSibling = libraryDir.appendingPathExtension("tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempSibling.path),
                       "precondition: no leftover .tmp from a prior run")

        XCTAssertThrowsError(
            try AtomicFileWriter.writeAtomically(Data(repeating: 0x42, count: 256), to: libraryDir)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempSibling.path),
                       "the .tmp file must be removed when the rename fails")
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryDir.path),
                      "the original directory must be untouched")
    }

    // MARK: - Orphan cleanup (B4)

    func test_orphanAudioFile_removedOnInit() throws {
        let orphanName = "orphan-\(UUID().uuidString).mp3"
        let orphanPath = libraryDir.appendingPathComponent(orphanName)
        try Data(repeating: 0, count: 100).write(to: orphanPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanPath.path),
                      "precondition: orphan planted on disk")

        manager = LocalLibraryManager(store: store, libraryDirectory: libraryDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath.path),
                       "orphan audio file should be removed by cleanup on init")
        XCTAssertTrue(manager.tracks.isEmpty)
    }

    func test_orphanArtworkFile_removedOnInit() throws {
        let artworkDir = libraryDir.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let orphanName = "orphan-\(UUID().uuidString).jpg"
        let orphanPath = artworkDir.appendingPathComponent(orphanName)
        try Data(repeating: 0, count: 100).write(to: orphanPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanPath.path),
                      "precondition: orphan artwork planted on disk")

        manager = LocalLibraryManager(store: store, libraryDirectory: libraryDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath.path),
                       "orphan artwork file should be removed by cleanup on init")
    }

    // MARK: - Import gates (B4)

    func test_import_zeroByteFile_rejected() async throws {
        let source = try makeSourceFile(data: Data(), ext: "mp3")
        do {
            _ = try await manager.importFile(at: source)
            XCTFail("expected ImportError.zeroByteFile, but import succeeded")
        } catch let error as ImportError {
            guard case .zeroByteFile = error else {
                XCTFail("expected .zeroByteFile, got \(error)")
                return
            }
        } catch {
            XCTFail("expected ImportError, got \(error)")
        }
        XCTAssertTrue(manager.tracks.isEmpty,
                      "no track should be added when the file is empty")
    }

    func test_import_cloudFileNotDownloaded_rejected() async throws {
        let cloudManager = LocalLibraryManager(
            store: store,
            libraryDirectory: libraryDir,
            isCloudFileNotDownloaded: { _ in true }
        )
        let source = try makeSourceFile()
        do {
            _ = try await cloudManager.importFile(at: source)
            XCTFail("expected ImportError.fileNotDownloaded, but import succeeded")
        } catch let error as ImportError {
            guard case .fileNotDownloaded = error else {
                XCTFail("expected .fileNotDownloaded, got \(error)")
                return
            }
        } catch {
            XCTFail("expected ImportError, got \(error)")
        }
        XCTAssertTrue(cloudManager.tracks.isEmpty,
                      "no track should be added when the file is an un-downloaded cloud file")
    }

    // MARK: - Metadata fallbacks (B4)

    func test_import_metadataFailure_usesFilenameFallback() async throws {
        // 1024 bytes of 0x00 with a .mp3 extension: not a valid audio stream,
        // so AVAsset.load(.commonMetadata) and .duration both fail.
        let url = try makeSourceFile(data: Data(repeating: 0x00, count: 1024), ext: "mp3")
        let track = try await manager.importFile(at: url)

        XCTAssertEqual(track.title, url.deletingPathExtension().lastPathComponent,
                       "title should fall back to the filename when metadata extraction fails")
        XCTAssertNotNil(track.artist, "artist should never be nil after import — the B4 fallback is \"This Device\"")
        XCTAssertEqual(track.artist, "This Device",
                       "artist should fall back to \"This Device\" when metadata extraction fails")
        XCTAssertNotNil(track.durationSeconds, "duration should never be nil after import — the B4 fallback is 0")
        XCTAssertEqual(track.durationSeconds, 0,
                       "duration should fall back to 0 when metadata extraction fails")
    }
}
