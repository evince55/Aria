import Foundation

/// Minimal protocol that `PlayerManager` (and other code) depends on for
/// network access. Exists so tests can substitute a mock that records calls
/// and returns canned responses without hitting the network.
protocol URLSessionProtocol: AnyObject {
    @discardableResult
    func dataTask(
        with url: URL,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTaskProtocol

    func data(from url: URL) async throws -> (Data, URLResponse)

    /// Downloads the body of `url` and reports fractional progress
    /// (`0.0...1.0`) as bytes arrive. Returns the on-disk URL of the
    /// downloaded file on success. The progress closure may be invoked
    /// from any queue; callers that need main-actor semantics must
    /// dispatch themselves.
    ///
    /// Used by the EQ engine path to show a "preparing" indicator on
    /// the player while the source stream is downloaded to `EQCache`
    /// before the first buffer can be scheduled.
    func downloadWithProgress(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
}

protocol URLSessionDataTaskProtocol: AnyObject {
    func resume()
    func cancel()
}

extension URLSessionDataTask: URLSessionDataTaskProtocol {}

/// Production implementation backed by a real `URLSession`. Mocks in tests
/// conform to `URLSessionProtocol` directly without going through this.
final class URLSessionAdapter: URLSessionProtocol {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    @discardableResult
    func dataTask(
        with url: URL,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTaskProtocol {
        session.dataTask(with: url, completionHandler: completionHandler)
    }

    func data(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }

    func downloadWithProgress(
        from url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: url)
        let total = response.expectedContentLength

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aria_download_\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        // Flush to disk in fixed-size chunks instead of accumulating the whole
        // file in memory. The previous `Data.append(byte)` per byte held the
        // entire (potentially 100s of MB) download in RAM — an OOM/jetsam kill
        // on long tracks or hi-res audio. Memory is now bounded to the chunk.
        let chunkSize = 64 * 1024
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        var received = Int64(0)

        func flush() throws {
            guard !chunk.isEmpty else { return }
            try handle.write(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
            // Only report progress when the server told us how big the payload
            // is. Chunked-encoding responses (no `Content-Length`) report 0
            // until completion, which the UI treats as indeterminate.
            if total > 0 {
                onProgress(min(1.0, Double(received) / Double(total)))
            }
        }

        for try await byte in bytes {
            chunk.append(byte)
            received += 1
            if chunk.count >= chunkSize {
                try flush()
            }
        }
        try flush()
        if total > 0 { onProgress(1.0) }
        return tempURL
    }
}
