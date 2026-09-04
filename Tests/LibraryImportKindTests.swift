import XCTest
import UniformTypeIdentifiers
@testable import Aria___Music_Browser

/// The Library has ONE `.fileImporter`; this enum decides what it asks for.
/// (Three stacked `.fileImporter`s only ever presented the last one, which
/// made plain "Import Files…" a dead button.) The presentation itself can
/// only be verified by driving the app; this pins the mapping it relies on.
final class LibraryImportKindTests: XCTestCase {
    func test_files_acceptsAnyAudio_andMultipleSelection() {
        XCTAssertEqual(LibraryImportKind.files.contentTypes, [.audio])
        XCTAssertTrue(LibraryImportKind.files.allowsMultipleSelection)
    }

    func test_folder_isSingleFolder() {
        XCTAssertEqual(LibraryImportKind.folder.contentTypes, [.folder])
        XCTAssertFalse(LibraryImportKind.folder.allowsMultipleSelection)
    }

    func test_m3u_acceptsPlaylistOrPlainText_single() {
        // `.m3uPlaylist` is ambiguous here (the app declares its own UTType
        // extension and the system has one); identifiers are unambiguous.
        XCTAssertEqual(LibraryImportKind.m3u.contentTypes.map(\.identifier),
                       ["public.m3u-playlist", "public.plain-text"])
        XCTAssertFalse(LibraryImportKind.m3u.allowsMultipleSelection)
    }
}
