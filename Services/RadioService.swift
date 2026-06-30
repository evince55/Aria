import Foundation

/// Fetches tracks similar to a seed video from the backend's `/api/radio`
/// endpoint (YouTube Mix `RD<id>`). Used to seed and refill an endless
/// autoplay queue — Musi-style "play similar songs" — instead of queuing raw,
/// often-junk search results.
protocol RadioServing: Sendable {
    func similar(to videoID: String, limit: Int) async throws -> [Track]
}

actor RadioService: RadioServing {
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

    func similar(to videoID: String, limit: Int = 25) async throws -> [Track] {
        guard var components = URLComponents(string: "\(backendURL)/api/radio") else {
            throw StreamResolverError.invalidEndpoint
        }
        components.queryItems = [
            URLQueryItem(name: "seed", value: videoID),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let endpoint = components.url else {
            throw StreamResolverError.invalidEndpoint
        }

        return try await withRetry(isRetryable: StreamResolver.isRetryable) {
            let (data, response) = try await session.data(for: .backendGET(endpoint, apiKey: apiKey))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StreamResolverError.serverError(
                    status: http.statusCode,
                    body: String(data: data, encoding: .utf8) ?? "<binary>"
                )
            }

            struct RadioResult: Decodable {
                let id: String
                let title: String
                let artist: String
                let thumbnail: URL?
            }

            let results = try JSONDecoder().decode([RadioResult].self, from: data)
            return results.map {
                Track(id: $0.id, title: $0.title, artist: $0.artist, thumbnailURL: $0.thumbnail)
            }
        }
    }
}
