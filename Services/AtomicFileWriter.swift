import Foundation

enum AtomicFileWriter {
    /// Writes `data` atomically to `url` using a temp-file + rename under the
    /// hood (via `NSData.write(options:.atomic)`). This correctly overwrites an
    /// existing file, unlike `FileManager.moveItem` which throws when the
    /// destination already exists.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}
