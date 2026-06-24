import Foundation

/// A track imported from the device's Files app via `UIDocumentPicker`.
///
/// The `id` is a stable UUID assigned at import time. The actual file
/// lives in the app's Documents/AriaLibrary/ directory; the on-disk
/// name is `fileName` (a UUID + extension). The `fileURL(for:)` method
/// on `LocalLibraryManager` reconstructs the absolute path from these
/// pieces.
struct LocalTrack: Identifiable, Codable, Hashable {
    let id: UUID
    let title: String
    let artist: String?
    let artworkURL: URL?
    let fileName: String
    let importedAt: Date
    let fileSizeBytes: Int64
    let durationSeconds: Double?
}
