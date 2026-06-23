import Foundation
import CryptoKit

/// File-based cache for EQ-processed audio files. Files are keyed by SHA-256
/// of the source stream URL, so the same track reuses the same cached file
/// even across sessions.
final class EQCache {
    static let shared = EQCache(folderName: "aria_eq")

    private let folderName: String
    private let fileManager: FileManager

    init(folderName: String, fileManager: FileManager = .default) {
        self.folderName = folderName
        self.fileManager = fileManager
    }

    /// Returns the on-disk URL where a cached version of `stream` should live.
    /// The directory is created on demand.
    func cacheURL(for stream: URL) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent(folderName, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Self.sha256(stream.absoluteString))
    }

    /// Removes the entire cache directory.
    func clear() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = caches?.appendingPathComponent(folderName, isDirectory: true)
        if let dir = dir {
            try? fileManager.removeItem(at: dir)
        }
    }

    static func sha256(_ s: String) -> String {
        let data = Data(s.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
