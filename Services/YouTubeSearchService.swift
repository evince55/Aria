import Foundation

final class YouTubeSearchService {
    let backendURL: String
    let apiKey: String?

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .useProtocolCachePolicy
        let cache = URLCache(
            memoryCapacity: 10 * 1024 * 1024,
            diskCapacity: 50 * 1024 * 1024,
            diskPath: "search_cache"
        )
        config.urlCache = cache
        return URLSession(configuration: config)
    }()
    private var currentTask: URLSessionDataTask?

    enum ServiceError: LocalizedError {
        case serverError(String)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .serverError(let message): return message
            case .decodingFailed: return "Failed to process server response"
            }
        }
    }

    init(backendURL: String, apiKey: String? = PlayerManager.apiKey) {
        self.backendURL = backendURL
        self.apiKey = apiKey
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func search(query: String, limit: Int = 25, offset: Int = 0) async throws -> [Track] {
        cancel()

        guard var components = URLComponents(string: "\(backendURL)/api/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        // Retry transient failures (timeouts / 502 / 503) so a Render free-tier
        // cold start doesn't fail the user's first search.
        return try await withRetry {
            let (data, response) = try await urlSession.data(for: .backendGET(url, apiKey: apiKey))

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                if [429, 502, 503].contains(httpResponse.statusCode) {
                    throw RetryPolicy.RetryableHTTPStatus(
                        statusCode: httpResponse.statusCode,
                        retryAfter: RetryPolicy.retryAfter(from: httpResponse)
                    )
                }
                let message = String(data: data, encoding: .utf8) ?? "Server error"
                throw ServiceError.serverError(message)
            }

            struct SearchResult: Decodable {
                let id: String
                let title: String
                let artist: String
                let thumbnail: URL?
                let duration: Double?
            }

            let results: [SearchResult]
            do {
                results = try JSONDecoder().decode([SearchResult].self, from: data)
            } catch {
                throw ServiceError.decodingFailed
            }

            return results.map { item in
                Track(
                    id: item.id,
                    title: item.title,
                    artist: item.artist,
                    thumbnailURL: item.thumbnail,
                    // Backend returns 0 for unknown duration; treat that as nil.
                    duration: (item.duration ?? 0) > 0 ? item.duration : nil
                )
            }
        }
    }
}
