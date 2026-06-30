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

    /// Request variant used by callers that need to attach headers (e.g. the
    /// `X-API-Key` auth header). Declared as a requirement (not just an
    /// extension) so it dynamically dispatches to `URLSessionAdapter`'s real
    /// implementation through the `URLSessionProtocol` existential.
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSessionProtocol {
    /// Default bridge so existing test mocks that only implement `data(from:)`
    /// keep working unchanged — the request's URL is forwarded, headers dropped.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        return try await data(from: url)
    }
}

extension URLRequest {
    /// A GET request to `url` carrying the `X-API-Key` header when `apiKey` is
    /// non-nil. Backend services use this so the (opt-in) server auth works once
    /// a key is configured; with no key the request is a plain GET.
    static func backendGET(_ url: URL, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        return request
    }
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

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
