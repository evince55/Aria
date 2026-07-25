import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// M3U/M3U8 playlists. The system knows `audio/mpegurl` as a MIME type but
    /// exposes no standard `UTType` constant, so declare it here (exported in
    /// Info.plist would be overkill for a text sidecar format).
    static var m3uPlaylist: UTType {
        UTType(importedAs: "public.m3u-playlist", conformingTo: .plainText)
    }
}

/// Minimal `FileDocument` wrapper so `.fileExporter` can write a playlist to
/// Files/iCloud. Text-only; the heavy lifting is in `M3UPlaylist.write`.
struct M3UDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.m3uPlaylist, .plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
