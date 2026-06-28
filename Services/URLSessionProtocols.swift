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
}
