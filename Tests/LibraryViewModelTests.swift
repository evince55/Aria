import XCTest
import Combine
@testable import Aria___Music_Browser

@MainActor
final class LibraryViewModelTests: XCTestCase {

    private var tmpDir: URL!
    private var libraryDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library_vm_test_\(UUID().uuidString)")
        libraryDir = tmpDir.appendingPathComponent("AriaLibrary")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeLibrary(tracks: [LocalTrack] = []) -> LocalLibraryManager {
        let data = (try? JSONEncoder().encode(tracks)) ?? Data()
        let store = InMemoryKeyValueStore(seed: data)
        return LocalLibraryManager(store: store, libraryDirectory: libraryDir)
    }

    private func makeTrack(
        id: UUID = UUID(),
        title: String = "Untitled",
        artist: String? = nil,
        album: String? = nil,
        importedAt: Date = Date(),
        fileSizeBytes: Int64 = 1024,
        duration: Double? = nil
    ) -> LocalTrack {
        LocalTrack(
            id: id,
            title: title,
            artist: artist,
            artworkURL: nil,
            fileName: "\(id.uuidString).mp3",
            importedAt: importedAt,
            fileSizeBytes: fileSizeBytes,
            durationSeconds: duration,
            album: album
        )
    }

    // MARK: - Skeleton: Combine subscription

    func test_init_subscribesToLibraryTracks() {
        let library = makeLibrary(tracks: [
            makeTrack(title: "A"),
            makeTrack(title: "B"),
        ])
        let vm = LibraryViewModel(library: library)
        XCTAssertEqual(vm.tracks.count, 2)
        XCTAssertEqual(vm.tracks.map(\.title), ["A", "B"])
    }

    func test_init_propagatesLibraryUpdates() async throws {
        let library = makeLibrary()
        let vm = LibraryViewModel(library: library)
        XCTAssertTrue(vm.tracks.isEmpty)

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm_prop_\(UUID().uuidString).mp3")
        try Data(repeating: 0x42, count: 1024).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let track = try await library.importFile(at: source)

        XCTAssertEqual(vm.tracks.count, 1)
        XCTAssertEqual(vm.tracks.first?.id, track.id)
        XCTAssertTrue(vm.tracks.first?.fileName.hasSuffix(".mp3") == true)
    }

    // MARK: - Search (B3 Task 3)

    func test_searchText_matchesTitleAndArtistCaseInsensitive() {
        let library = makeLibrary(tracks: [
            makeTrack(title: "Bohemian Rhapsody", artist: "Queen"),
            makeTrack(title: "Imagine", artist: "John Lennon"),
            makeTrack(title: "Hey Jude", artist: "The Beatles"),
        ])
        let vm = LibraryViewModel(library: library, initialSortOrder: .title)

        vm.searchText = "queen"
        XCTAssertEqual(vm.filteredAndSortedTracks.map(\.title), ["Bohemian Rhapsody"])

        vm.searchText = "IMAGINE"
        XCTAssertEqual(vm.filteredAndSortedTracks.map(\.title), ["Imagine"])

        vm.searchText = "the"
        XCTAssertEqual(vm.filteredAndSortedTracks.map(\.title), ["Hey Jude"])

        vm.searchText = ""
        XCTAssertEqual(vm.filteredAndSortedTracks.map(\.title), [
            "Bohemian Rhapsody", "Hey Jude", "Imagine",
        ])

        vm.searchText = "no-match-string"
        XCTAssertTrue(vm.filteredAndSortedTracks.isEmpty)
    }

    // MARK: - Sort (B3 Task 3)

    func test_sortByTitle_isStableForEqualTitles() {
        let first  = makeTrack(id: UUID(), title: "Echoes", importedAt: Date(timeIntervalSince1970: 100))
        let second = makeTrack(id: UUID(), title: "Echoes", importedAt: Date(timeIntervalSince1970: 200))
        let third  = makeTrack(id: UUID(), title: "Alpha",  importedAt: Date(timeIntervalSince1970: 300))
        let library = makeLibrary(tracks: [first, second, third])
        let vm = LibraryViewModel(library: library, initialSortOrder: .title)

        let titles = vm.filteredAndSortedTracks.map(\.title)
        XCTAssertEqual(titles, ["Alpha", "Echoes", "Echoes"])
        let echoesOrder = vm.filteredAndSortedTracks
            .filter { $0.title == "Echoes" }
            .map { $0.id }
        XCTAssertEqual(echoesOrder, [first.id, second.id],
                       "stable sort: equal-title tracks keep their insertion order")
    }

    func test_sortByDuration_nilDurationGoesLast() {
        let withDur1 = makeTrack(id: UUID(), title: "Short", duration: 30)
        let withDur2 = makeTrack(id: UUID(), title: "Long",  duration: 300)
        let nilDur1  = makeTrack(id: UUID(), title: "Nil A", duration: nil)
        let nilDur2  = makeTrack(id: UUID(), title: "Nil B", duration: nil)
        let library = makeLibrary(tracks: [nilDur1, withDur1, nilDur2, withDur2])
        let vm = LibraryViewModel(library: library, initialSortOrder: .duration)

        let titles = vm.filteredAndSortedTracks.map(\.title)
        XCTAssertEqual(titles, ["Short", "Long", "Nil A", "Nil B"])
    }
}
