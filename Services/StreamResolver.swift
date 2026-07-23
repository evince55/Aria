import Foundation

/// Resolves a YouTube video ID to a playable stream URL by calling the
/// backend's `/api/play?video_id=...` endpoint.
///
/// The network call is the only thing this actor does. The full
/// `PlayerManager.play(_:)` flow (state update, AVAudioEngine path,
/// Now Playing, etc.) lives in `PlayerManager`; this actor is just the
/// "give me a URL" step.
///
/// The actor gives us natural isolation: in-flight requests don't race
/// with each other, and Swift's structured concurrency handles
/// cancellation when `PlayerManager` switches tracks.
protocol StreamResolving: Sendable {
    /// Full path: `/api/play` downloads + caches the file server-side, then
    /// returns the cached `/api/stream/...` URL. Needed by the EQ engine path
    /// (which reads a local file) and for offline. Blocks until the download
    /// finishes — slow first-play.
    func stream(for videoID: String) async throws -> URL
    /// Fast path: `/api/resolve` returns the direct googlevideo URL without
    /// downloading, so AVPlayer can start immediately. The URL is signed and
    /// expires (~6h); callers should re-resolve on playback failure. `duration`
    /// is yt-dlp's true video length, used to cap the YouTube DASH
    /// 2x-with-silence streams that the download path trims server-side.
    func resolve(for videoID: String) async throws -> ResolvedStream
    /// Failure-recovery variant: bypasses every cache layer (client and
    /// backend) so a retry gets a genuinely NEW signed URL. YouTube can
    /// invalidate a URL mid-TTL; retrying through the caches would just
    /// re-fetch the same dead one.
    func resolve(for videoID: String, fresh: Bool) async throws -> ResolvedStream
}

extension StreamResolving {
    /// Resolvers with no cache of their own have no freshness distinction.
    func resolve(for videoID: String, fresh: Bool) async throws -> ResolvedStream {
        try await resolve(for: videoID)
    }
}

/// Result of `/api/resolve`: a directly-playable URL plus the authoritative
/// track duration (seconds) when the backend reported one.
struct ResolvedStream: Sendable {
    let url: URL
    let duration: TimeInterval?
}

actor StreamResolver: StreamResolving {
    let backendURL: String
    let session: URLSessionProtocol
    let apiKey: String?

    init(
        backendURL: String = PlayerManager.backendURL,
        session: URLSessionProtocol,
        apiKey: String? = PlayerManager.apiKey
    ) {
        self.backendURL = backendURL
        self.session = session
        self.apiKey = apiKey
    }

    /// Returns the absolute stream URL for a given video ID. Throws on
    /// network failure, malformed response, or unrecoverable URL parsing.
    func stream(for videoID: String) async throws -> URL {
        guard let endpoint = URL(string: "\(backendURL)/api/play?video_id=\(videoID)") else {
            throw StreamResolverError.invalidEndpoint
        }

        return try await withRetry(isRetryable: Self.isRetryable) {
            let (data, response) = try await session.data(for: .backendGET(endpoint, apiKey: apiKey))
            try Self.validate(response: response, data: data)

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let streamURLString = json["url"] as? String
            else {
                throw StreamResolverError.malformedResponse
            }

            guard
                let streamURL = URL(string: streamURLString, relativeTo: URL(string: backendURL))?.absoluteURL
            else {
                throw StreamResolverError.malformedResponse
            }

            return streamURL
        }
    }

    /// Returns the direct, immediately-playable stream URL for `videoID` via
    /// `/api/resolve` — no server-side download. The returned URL is absolute
    /// (googlevideo), signed, and short-lived.
    func resolve(for videoID: String) async throws -> ResolvedStream {
        try await resolve(for: videoID, fresh: false)
    }

    /// `fresh` adds `&fresh=1`, which makes the backend skip its resolve cache
    /// (and overwrite it with the new URL) — the escape hatch for retrying a
    /// stream whose cached URL YouTube has invalidated.
    func resolve(for videoID: String, fresh: Bool) async throws -> ResolvedStream {
        let freshSuffix = fresh ? "&fresh=1" : ""
        guard let endpoint = URL(string: "\(backendURL)/api/resolve?video_id=\(videoID)\(freshSuffix)") else {
            throw StreamResolverError.invalidEndpoint
        }

        return try await withRetry(isRetryable: Self.isRetryable) {
            let (data, response) = try await session.data(for: .backendGET(endpoint, apiKey: apiKey))
            try Self.validate(response: response, data: data)

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let urlString = json["url"] as? String,
                let url = URL(string: urlString)
            else {
                throw StreamResolverError.malformedResponse
            }

            // `duration` may arrive as Int or Double depending on yt-dlp; accept both.
            let duration = (json["duration"] as? Double) ?? (json["duration"] as? Int).map(Double.init)
            return ResolvedStream(url: url, duration: duration)
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              !(200..<300).contains(http.statusCode) else { return }
        // 429/502/503 are transient — throw the retryable status (carrying any
        // Retry-After) so withRetry backs off and retries instead of failing.
        if [429, 502, 503].contains(http.statusCode) {
            throw RetryPolicy.RetryableHTTPStatus(
                statusCode: http.statusCode,
                retryAfter: RetryPolicy.retryAfter(from: http)
            )
        }
        let body = String(data: data, encoding: .utf8) ?? "<binary>"
        throw StreamResolverError.serverError(status: http.statusCode, body: body)
    }

    /// Retry transient network errors and transient HTTP statuses (429/502/503).
    /// A persistent error surfaces unchanged.
    static func isRetryable(_ error: Error) -> Bool {
        RetryPolicy.isRetryableNetworkError(error)
    }
}

enum StreamResolverError: LocalizedError {
    case invalidEndpoint
    case malformedResponse
    case serverError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:           return "Invalid backend URL"
        case .malformedResponse:         return "Server returned an unexpected response"
        case .serverError(let s, let b): return "Server error \(s): \(b)"
        }
    }
}
