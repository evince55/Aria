import Foundation

/// Client for `GET /api/library/query` — natural-language search over the
/// device's synced library index ("Ask Your Library").
///
/// Constructed per-request by `LibrarySearchManager` with the *currently*
/// resolved backend URL/key (never freeze `BackendConfig` values — the user
/// can change the server in Settings at any time). Network goes through the
/// `URLSessionProtocol` seam so tests stub it (hermeticity rule: the suite
/// must pass with no network, including on a real-IP device worktree).
final class LibrarySearchService {
    let backendURL: String
    let apiKey: String?
    private let session: URLSessionProtocol

    /// One ranked hit. `matched` ("lexical" | "vector" | "both") is the
    /// explanation seam — unused by the UI in v1, consumed by the evals.
    struct Result: Decodable, Equatable {
        let trackID: String
        let score: Double
        let matched: String?

        private enum CodingKeys: String, CodingKey {
            case trackID = "track_id"
            case score, matched
        }
    }

    /// `mode` is "hybrid" when the server's embedder answered, "lexical" when
    /// it degraded to BM25-only (e.g. the GPU box is asleep). The client
    /// proceeds silently either way (spec §2 degradation rule).
    struct QueryResponse: Decodable, Equatable {
        let results: [Result]
        let mode: String
    }

    enum ServiceError: LocalizedError {
        case serverError(Int)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .serverError(let code): return "Library search failed (server error \(code))"
            case .decodingFailed: return "Failed to process library search response"
            }
        }
    }

    init(
        backendURL: String,
        session: URLSessionProtocol = URLSessionAdapter(session: .shared),
        apiKey: String? = BackendConfig.apiKey
    ) {
        self.backendURL = backendURL
        self.session = session
        self.apiKey = apiKey
    }

    func query(deviceID: String, q: String, k: Int = 25) async throws -> QueryResponse {
        guard var components = URLComponents(string: "\(backendURL)/api/library/query") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "device_id", value: deviceID),
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "k", value: String(k)),
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await session.data(for: .backendGET(url, apiKey: apiKey))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw ServiceError.serverError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(QueryResponse.self, from: data)
        } catch {
            throw ServiceError.decodingFailed
        }
    }
}
