import Foundation

enum AtomicFileWriter {
    /// Writes `data` to a `<url>.tmp` file in the same directory, then renames
    /// it over `url`. The temp file is removed if the rename fails. Atomicity
    /// is provided by `FileManager.moveItem` (POSIX rename) on the same volume.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let tempURL = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tempURL)
            try FileManager.default.moveItem(at: tempURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
