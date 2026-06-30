import Foundation

final class YouTubeSearchService {
    let backendURL: String

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

    init(backendURL: String) {
        self.backendURL = backendURL
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func search(query: String) async throws -> [Track] {
        cancel()

        guard var components = URLComponents(string: "\(backendURL)/api/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        // Retry transient failures (timeouts / 502 / 503) so a Render free-tier
        // cold start doesn't fail the user's first search.
        return try await withRetry {
            let (data, response) = try await urlSession.data(from: url)

            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode >= 400 {
                if httpResponse.statusCode == 502 || httpResponse.statusCode == 503 {
                    throw RetryPolicy.RetryableHTTPStatus(statusCode: httpResponse.statusCode)
                }
                let message = String(data: data, encoding: .utf8) ?? "Server error"
                throw ServiceError.serverError(message)
            }

            struct SearchResult: Decodable {
                let id: String
                let title: String
                let artist: String
                let thumbnail: URL?
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
                    thumbnailURL: item.thumbnail
                )
            }
        }
    }
}
