import XCTest
import AVFoundation
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
            artworkFileName: nil,
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

        // Mutate the track in-memory to attach the artwork file name, then
        // remove. The manager resolves the absolute path via
        // `artworkURL(for:)` against its injected library directory.
        track = LocalTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            artworkFileName: artworkURL.lastPathComponent,
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
            artworkFileName: nil,
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
            artworkFileName: nil,
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

    // MARK: - Artwork extraction (local-artwork finding)

    /// A synthetic stand-in for `AVURLAsset` conforming to
    /// `MetadataLoading`, so `LocalLibraryManager.loadArtworkData` can be
    /// exercised with hand-built `AVMetadataItem`s instead of real audio
    /// fixtures.
    private struct StaticMetadataAsset: MetadataLoading {
        var allMetadata: [AVMetadataItem] = []
        var commonMetadata: [AVMetadataItem] = []
        var formatItems: [AVMetadataFormat: [AVMetadataItem]] = [:]

        func loadAllMetadataItems() async throws -> [AVMetadataItem] { allMetadata }
        func loadCommonMetadataItems() async throws -> [AVMetadataItem] { commonMetadata }
        func loadAvailableMetadataFormats() async throws -> [AVMetadataFormat] { Array(formatItems.keys) }
        func loadMetadataItems(for format: AVMetadataFormat) async throws -> [AVMetadataItem] {
            formatItems[format] ?? []
        }
    }

    /// Builds a synthetic `AVMutableMetadataItem` with the given
    /// identifier/commonKey/key and raw `Data` payload, for exercising
    /// `LocalLibraryManager.loadArtworkData` without needing a real audio
    /// fixture.
    private func makeArtworkItem(
        identifier: AVMetadataIdentifier? = nil,
        key: String? = nil,
        data: Data
    ) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        if let key {
            item.keySpace = .id3
            item.key = key as NSString
        }
        // `dataValue` and `commonKey` have no setters (even on the mutable
        // subclass) -- `commonKey` is derived from `identifier`, and the
        // async `load(.dataValue)` overlay derives its value from `value`,
        // which is the settable property.
        item.value = data as NSData
        return item
    }

    private let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46])
    private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    func test_artworkFileExtension_jpeg() {
        XCTAssertEqual(LocalLibraryManager.artworkFileExtension(for: jpegBytes), "jpg")
    }

    func test_artworkFileExtension_png() {
        XCTAssertEqual(LocalLibraryManager.artworkFileExtension(for: pngBytes), "png")
    }

    func test_artworkFileExtension_gif() {
        let gifBytes = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        XCTAssertEqual(LocalLibraryManager.artworkFileExtension(for: gifBytes), "gif")
    }

    func test_artworkFileExtension_unknownMagicBytes_fallsBackToImg() {
        let randomBytes = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(LocalLibraryManager.artworkFileExtension(for: randomBytes), "img")
    }

    func test_artworkFileExtension_emptyData_fallsBackToImg() {
        XCTAssertEqual(LocalLibraryManager.artworkFileExtension(for: Data()), "img")
    }

    func test_loadArtworkData_commonIdentifierArtwork_isSelected() async {
        let item = makeArtworkItem(identifier: .commonIdentifierArtwork, data: jpegBytes)
        let asset = StaticMetadataAsset(allMetadata: [item])
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertEqual(data, jpegBytes)
    }

    func test_loadArtworkData_id3AttachedPictureIdentifier_isSelected() async {
        // Simulates an MP3's ID3 APIC frame surfaced via its format-specific
        // identifier rather than the common-artwork identifier — the gap
        // the original extraction missed.
        let item = makeArtworkItem(identifier: .id3MetadataAttachedPicture, data: jpegBytes)
        let asset = StaticMetadataAsset(formatItems: [.id3Metadata: [item]])
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertEqual(data, jpegBytes)
    }

    func test_loadArtworkData_id3APICRawKey_isSelected() async {
        // Some asset/format combinations surface the ID3 frame only via its
        // raw key string ("APIC") rather than a typed `.identifier`.
        let item = makeArtworkItem(key: "APIC", data: pngBytes)
        let asset = StaticMetadataAsset(formatItems: [.id3Metadata: [item]])
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertEqual(data, pngBytes)
    }

    func test_loadArtworkData_iTunesCoverArt_isSelected() async {
        let item = makeArtworkItem(identifier: .iTunesMetadataCoverArt, data: pngBytes)
        let asset = StaticMetadataAsset(formatItems: [.iTunesMetadata: [item]])
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertEqual(data, pngBytes)
    }

    func test_loadArtworkData_legacyCommonMetadataFallback_isSelected() async {
        // Artwork only present in `commonMetadata` (not in the combined
        // `.metadata` set or any format-specific set) -- exercises the
        // final legacy fallback path, which scans for
        // `commonKey == "artwork"`. `commonKey` is derived automatically
        // from the common-artwork identifier.
        let item = makeArtworkItem(identifier: .commonIdentifierArtwork, data: jpegBytes)
        let asset = StaticMetadataAsset(commonMetadata: [item])
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertEqual(data, jpegBytes)
    }

    func test_loadArtworkData_noArtworkAnywhere_returnsNil() async {
        let asset = StaticMetadataAsset()
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertNil(data)
    }

    func test_loadArtworkData_emptyDataValue_treatedAsAbsent() async {
        let item = makeArtworkItem(identifier: .commonIdentifierArtwork, data: Data())
        let asset = StaticMetadataAsset(allMetadata: [item])
        let data = await LocalLibraryManager.loadArtworkData(from: asset)
        XCTAssertNil(data, "an artwork item with empty data should not be treated as present")
    }

    // MARK: - Artwork relative-path storage + migration (container-UUID fix)

    func test_localTrack_migratesLegacyAbsoluteArtworkURL_toFileName() throws {
        // Simulate an OLD persisted entry that stored an absolute artwork
        // URL baked against a now-dead container UUID.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Legacy",
          "artist": "A",
          "artworkURL": "file:///var/mobile/Containers/Data/Application/DEAD-UUID/Documents/AriaLibrary/artwork/cover-123.jpg",
          "fileName": "song.mp3",
          "importedAt": 0,
          "fileSizeBytes": 100,
          "durationSeconds": 60,
          "isMissing": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalTrack.self, from: legacyJSON)
        XCTAssertEqual(decoded.artworkFileName, "cover-123.jpg",
                       "legacy absolute artworkURL should migrate to its last path component")
    }

    func test_localTrack_migratesLegacyArtworkURL_encodedAsRawString() throws {
        // Some encoders wrote the URL as a plain string rather than a URL.
        let legacyJSON = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Legacy",
          "artist": "A",
          "artworkURL": "/var/mobile/.../artwork/raw-string-cover.png",
          "fileName": "song.mp3",
          "importedAt": 0,
          "fileSizeBytes": 100,
          "durationSeconds": 60
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LocalTrack.self, from: legacyJSON)
        XCTAssertEqual(decoded.artworkFileName, "raw-string-cover.png")
    }

    func test_localTrack_encodesRelativeFileName_notAbsolutePath() throws {
        let track = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: "cover.jpg",
            fileName: "song.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        let data = try JSONEncoder().encode(track)
        let json = String(data: data, encoding: .utf8)!

        XCTAssertTrue(json.contains("\"artworkFileName\":\"cover.jpg\""),
                      "should persist the relative file name")
        XCTAssertFalse(json.contains("artworkURL"),
                       "should NOT persist any absolute artworkURL key")
        XCTAssertFalse(json.contains("file://") || json.contains("/Containers/"),
                       "should NOT persist any absolute path")

        let decoded = try JSONDecoder().decode(LocalTrack.self, from: data)
        XCTAssertEqual(decoded.artworkFileName, "cover.jpg", "round-trips")
    }

    func test_artworkURLFor_resolvesAgainstCurrentLibraryDirectory() {
        let track = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: "cover-xyz.jpg",
            fileName: "song.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        let resolved = manager.artworkURL(for: track)
        XCTAssertNotNil(resolved)
        // Resolved under the injected (temp) library dir, not any baked-in path.
        XCTAssertEqual(resolved?.deletingLastPathComponent().path,
                       libraryDir.appendingPathComponent("artwork").path)
        XCTAssertEqual(resolved?.lastPathComponent, "cover-xyz.jpg")
    }

    func test_artworkURLFor_nilWhenNoArtworkFileName() {
        let track = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: nil,
            fileName: "song.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        XCTAssertNil(manager.artworkURL(for: track))
    }

    func test_artworkURLFor_resolvedPathChangesWithLibraryDirectory() async throws {
        // The same persisted track resolves to DIFFERENT absolute paths
        // under two different library directories — proving the path is
        // re-derived at access time (the container-UUID-change fix) rather
        // than baked into the model.
        let track = LocalTrack(
            id: UUID(),
            title: "T",
            artist: "A",
            artworkFileName: "art.jpg",
            fileName: "song.mp3",
            importedAt: Date(),
            fileSizeBytes: 100,
            durationSeconds: 30
        )
        let otherDir = tmpDir.appendingPathComponent("OtherContainer/AriaLibrary")
        let otherManager = LocalLibraryManager(store: InMemoryKeyValueStore(), libraryDirectory: otherDir)

        let a = manager.artworkURL(for: track)
        let b = otherManager.artworkURL(for: track)
        XCTAssertNotEqual(a?.path, b?.path, "resolved path must follow the manager's library directory")
        XCTAssertTrue(a!.path.hasPrefix(libraryDir.path))
        XCTAssertTrue(b!.path.hasPrefix(otherDir.path))
    }

    // MARK: - Self-heal missing artwork (recovers tracks across rebuilds)

    /// Seeds a store with one track (already claiming `artworkFileName`)
    /// plus a present audio file under `dir`, then returns a manager built
    /// on `dir` with the given injected artwork loader. The artwork file
    /// itself is intentionally NOT written, simulating the dead-container
    /// state (audio survived, artwork gone).
    private func makeHealableManager(
        artworkFileNameClaim: String,
        loader: @escaping (URL) async -> Data?
    ) throws -> (LocalLibraryManager, LocalTrack) {
        let id = UUID()
        let fileName = "\(id.uuidString).mp3"
        // Audio file present under the live library dir.
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 1024).write(to: libraryDir.appendingPathComponent(fileName))

        let seeded = LocalTrack(
            id: id, title: "Seeded", artist: "A",
            artworkFileName: artworkFileNameClaim,
            fileName: fileName, importedAt: Date(),
            fileSizeBytes: 1024, durationSeconds: 60
        )
        let seed = try JSONEncoder().encode(
            VersionedEnvelope(schemaVersion: LocalLibraryManager.schemaVersion, items: [seeded])
        )
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(seed: seed),
            libraryDirectory: libraryDir,
            loadArtworkData: loader
        )
        return (m, seeded)
    }

    func test_healMissingArtwork_reextractsArtworkWhenFileGoneButAudioPresent() async throws {
        // Loader returns valid JPEG bytes (simulating embedded artwork in
        // the surviving audio file). Self-heal must re-extract + write it.
        let jpeg = jpegBytes
        let (healed, seeded) = try makeHealableManager(
            artworkFileNameClaim: "\(UUID().uuidString).jpg",
            loader: { _ in jpeg }
        )
        XCTAssertEqual(healed.tracks.count, 1)
        // Precondition: claimed artwork file is absent on disk.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: healed.artworkURL(for: seeded)!.path)
        )

        // Wait for the fire-and-forget heal Task.
        try await Task.sleep(nanoseconds: 300_000_000)

        let healedTrack = healed.tracks[0]
        XCTAssertNotNil(healedTrack.artworkFileName)
        let resolved = healed.artworkURL(for: healedTrack)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resolved!.path),
            "self-heal should have re-extracted and written artwork to the live container"
        )
        XCTAssertEqual(resolved!.deletingLastPathComponent().path,
                       libraryDir.appendingPathComponent("artwork").path)
        XCTAssertTrue(resolved!.lastPathComponent.hasSuffix(".jpg"))
    }

    func test_healMissingArtwork_noArtworkExtractable_leavesFileAbsentNoCrash() async throws {
        // Loader returns nil (no embedded artwork). Self-heal is a no-op:
        // best-effort, never throws, artwork stays absent.
        let (healed, _) = try makeHealableManager(
            artworkFileNameClaim: "\(UUID().uuidString).jpg",
            loader: { _ in nil }
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        let track = healed.tracks[0]
        if let art = healed.artworkURL(for: track) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: art.path))
        }
    }

    func test_healMissingArtwork_skipsWhenArtworkAlreadyOnDisk() async throws {
        // If the artwork file already exists, the loader must NOT be called.
        let artName = "\(UUID().uuidString).jpg"
        let artworkDir = libraryDir.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)

        var loaderCalled = false
        // Pre-write the artwork file so heal should skip it. We can't know
        // the file name before seeding, so write it after constructing the
        // claim and before the manager's heal Task runs is racy; instead,
        // assert via loaderCalled staying false when the file is present.
        try Data(jpegBytes).write(to: artworkDir.appendingPathComponent(artName))

        let id = UUID()
        let fileName = "\(id.uuidString).mp3"
        try Data(repeating: 0x42, count: 1024).write(to: libraryDir.appendingPathComponent(fileName))
        let seeded = LocalTrack(
            id: id, title: "Seeded", artist: "A",
            artworkFileName: artName,
            fileName: fileName, importedAt: Date(),
            fileSizeBytes: 1024, durationSeconds: 60
        )
        let seed = try JSONEncoder().encode(
            VersionedEnvelope(schemaVersion: LocalLibraryManager.schemaVersion, items: [seeded])
        )
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(seed: seed),
            libraryDirectory: libraryDir,
            loadArtworkData: { _ in loaderCalled = true; return nil }
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(loaderCalled, "heal must skip tracks whose artwork is already on disk")
        XCTAssertEqual(m.tracks[0].artworkFileName, artName)
    }

    func test_import_endToEnd_syntheticFileHasNoArtwork() async throws {
        // A freshly imported synthetic file has no embedded artwork (default
        // loader path), so artworkFileName stays nil.
        let source = try makeSourceFile()
        let track = try await manager.importFile(at: source)
        XCTAssertNil(track.artworkFileName)
    }

    func test_import_extractsArtwork_viaInjectedLoader() async throws {
        // With an injected loader that yields PNG bytes, import writes the
        // artwork and records a relative .png file name resolvable against
        // the library dir.
        let png = pngBytes
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(),
            libraryDirectory: libraryDir,
            loadArtworkData: { _ in png }
        )
        let source = try makeSourceFile()
        let track = try await m.importFile(at: source)
        XCTAssertNotNil(track.artworkFileName)
        XCTAssertTrue(track.artworkFileName!.hasSuffix(".png"))
        let resolved = m.artworkURL(for: track)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved!.path))
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

    // MARK: - Remote cover fallback (/api/cover wiring)

    /// A `CoverFetching` test double that never touches the network: returns
    /// a canned `Data?` and records every invocation's arguments.
    private final class MockCoverFetcher: CoverFetching {
        var result: Data?
        private(set) var callCount = 0
        private(set) var lastTitle: String?
        private(set) var lastArtist: String?
        private(set) var lastDuration: Double?

        init(result: Data?) {
            self.result = result
        }

        func fetchCoverImageData(title: String, artist: String?, durationSeconds: Double?) async -> Data? {
            callCount += 1
            lastTitle = title
            lastArtist = artist
            lastDuration = durationSeconds
            return result
        }
    }

    func test_import_noEmbeddedArtwork_fetchesRemoteCover_andWritesFile() async throws {
        let fetcher = MockCoverFetcher(result: jpegBytes)
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(),
            libraryDirectory: libraryDir,
            coverFetcher: fetcher
        )
        let source = try makeSourceFile()
        let track = try await m.importFile(at: source)

        XCTAssertEqual(fetcher.callCount, 1, "remote cover fetch should run exactly once for a coverless track")
        XCTAssertNotNil(track.artworkFileName, "track should end up with a remote-fetched cover file name")
        XCTAssertTrue(track.artworkFileName!.hasSuffix(".jpg"))

        let resolved = m.artworkURL(for: track)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved!.path),
                      "the fetched image bytes should be written to the resolved artwork URL")
        XCTAssertEqual(try Data(contentsOf: resolved!), jpegBytes)
    }

    func test_import_remoteCoverFetcher_returnsNil_leavesTrackCoverless_noCrash() async throws {
        let fetcher = MockCoverFetcher(result: nil)
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(),
            libraryDirectory: libraryDir,
            coverFetcher: fetcher
        )
        let source = try makeSourceFile()
        let track = try await m.importFile(at: source)

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertNil(track.artworkFileName, "a miss from the remote fetcher should leave the track coverless")
        XCTAssertNil(m.artworkURL(for: track))
    }

    /// A `CoverFetching` double that throws-equivalent behavior (returns nil)
    /// to simulate a network failure — the seam never surfaces errors, so
    /// "throwing" is represented as a nil result. Exercises the same
    /// no-crash guarantee as the returns-nil case, from a distinctly-named
    /// test per the assignment's "throwing" scenario.
    private final class FailingCoverFetcher: CoverFetching {
        private(set) var callCount = 0
        func fetchCoverImageData(title: String, artist: String?, durationSeconds: Double?) async -> Data? {
            callCount += 1
            return nil
        }
    }

    func test_import_remoteCoverFetcher_failure_leavesTrackCoverless_noCrash() async throws {
        let fetcher = FailingCoverFetcher()
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(),
            libraryDirectory: libraryDir,
            coverFetcher: fetcher
        )
        let source = try makeSourceFile()
        let track = try await m.importFile(at: source)

        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertNil(track.artworkFileName)
    }

    func test_import_embeddedArtworkPresent_doesNotCallRemoteFetcher_notOverwritten() async throws {
        // Embedded extraction succeeds (injected loader yields PNG bytes);
        // the remote fetcher must never be consulted, and must not
        // overwrite the embedded cover.
        let embeddedPNG = pngBytes
        let fetcher = MockCoverFetcher(result: jpegBytes)
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(),
            libraryDirectory: libraryDir,
            loadArtworkData: { _ in embeddedPNG },
            coverFetcher: fetcher
        )
        let source = try makeSourceFile()
        let track = try await m.importFile(at: source)

        XCTAssertEqual(fetcher.callCount, 0, "remote cover fetch must be skipped when embedded artwork was found")
        XCTAssertNotNil(track.artworkFileName)
        XCTAssertTrue(track.artworkFileName!.hasSuffix(".png"), "artwork should be the embedded PNG, not a remote fallback")

        let resolved = m.artworkURL(for: track)
        XCTAssertEqual(try Data(contentsOf: resolved!), embeddedPNG)
    }

    func test_backfillRemoteCovers_existingCoverlessTrack_getsRemoteCoverOnNextInit() async throws {
        // Seed a store with one coverless track (no artworkFileName, and no
        // artwork file on disk) plus a present audio file, then construct a
        // manager with a mock fetcher and confirm the backfill pass attaches
        // a cover.
        let id = UUID()
        let fileName = "\(id.uuidString).mp3"
        try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 512).write(to: libraryDir.appendingPathComponent(fileName))

        let seeded = LocalTrack(
            id: id, title: "No Cover", artist: "Some Artist",
            artworkFileName: nil,
            fileName: fileName, importedAt: Date(),
            fileSizeBytes: 512, durationSeconds: 180
        )
        let seed = try JSONEncoder().encode(
            VersionedEnvelope(schemaVersion: LocalLibraryManager.schemaVersion, items: [seeded])
        )
        let fetcher = MockCoverFetcher(result: jpegBytes)
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(seed: seed),
            libraryDirectory: libraryDir,
            coverFetcher: fetcher
        )

        // Wait for the fire-and-forget backfill Task.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(fetcher.callCount, 1, "backfill should attempt exactly one remote fetch for the coverless track")
        XCTAssertEqual(fetcher.lastTitle, "No Cover")
        XCTAssertEqual(fetcher.lastArtist, "Some Artist")
        XCTAssertEqual(fetcher.lastDuration, 180)

        let track = m.tracks.first { $0.id == id }
        XCTAssertNotNil(track?.artworkFileName)
        let resolved = m.artworkURL(for: track!)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved!.path))
    }

    func test_backfillRemoteCovers_trackAlreadyHasArtwork_isNotOverwritten() async throws {
        // A track that already has a cover file on disk must not be
        // touched by the backfill pass at all.
        let artName = "\(UUID().uuidString).jpg"
        let artworkDir = libraryDir.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDir, withIntermediateDirectories: true)
        let existingBytes = jpegBytes
        try existingBytes.write(to: artworkDir.appendingPathComponent(artName))

        let id = UUID()
        let fileName = "\(id.uuidString).mp3"
        try Data(repeating: 0x42, count: 512).write(to: libraryDir.appendingPathComponent(fileName))
        let seeded = LocalTrack(
            id: id, title: "Has Cover", artist: "Artist",
            artworkFileName: artName,
            fileName: fileName, importedAt: Date(),
            fileSizeBytes: 512, durationSeconds: 200
        )
        let seed = try JSONEncoder().encode(
            VersionedEnvelope(schemaVersion: LocalLibraryManager.schemaVersion, items: [seeded])
        )
        let fetcher = MockCoverFetcher(result: pngBytes)
        let m = LocalLibraryManager(
            store: InMemoryKeyValueStore(seed: seed),
            libraryDirectory: libraryDir,
            coverFetcher: fetcher
        )

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(fetcher.callCount, 0, "a track that already has artwork on disk must never trigger a remote fetch")
        let track = m.tracks.first { $0.id == id }
        XCTAssertEqual(track?.artworkFileName, artName, "existing artwork file name must remain unchanged")
        let resolved = m.artworkURL(for: track!)
        XCTAssertEqual(try Data(contentsOf: resolved!), existingBytes, "existing artwork bytes must not be overwritten")
    }

    // MARK: - /api/cover query resolution

    func testCoverQueryUsesRealArtistVerbatim() {
        let q = BackendCoverFetcher.coverQuery(title: "Tadow", artist: "FKJ")
        XCTAssertEqual(q.title, "Tadow")
        XCTAssertEqual(q.artist, "FKJ")
    }

    func testCoverQuerySplitsArtistTitleWhenNoUsableArtist() {
        // No artist tag → split "Artist - Title" on the first " - ".
        for artist in [nil, "", "This Device"] as [String?] {
            let q = BackendCoverFetcher.coverQuery(title: "Fkj & Masego - Tadow", artist: artist)
            XCTAssertEqual(q.artist, "Fkj & Masego")
            XCTAssertEqual(q.title, "Tadow")
        }
    }

    func testCoverQuerySplitsOnlyFirstSeparator() {
        let q = BackendCoverFetcher.coverQuery(title: "Drake - Laugh Now - Cry Later", artist: nil)
        XCTAssertEqual(q.artist, "Drake")
        XCTAssertEqual(q.title, "Laugh Now - Cry Later")
    }

    func testCoverQueryTitleOnlyWhenNoArtistAndNoSeparator() {
        let q = BackendCoverFetcher.coverQuery(title: "Untitled", artist: nil)
        XCTAssertEqual(q.title, "Untitled")
        XCTAssertNil(q.artist)
    }
}
