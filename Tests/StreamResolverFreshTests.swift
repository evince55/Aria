import XCTest
@testable import Aria___Music_Browser

/// Verifies the failure-recovery contract: `resolve(for:fresh:)` must carry the
/// `fresh=1` cache-bypass to the backend, and the normal path must not.
final class StreamResolverFreshTests: XCTestCase {

    private final class RecordingSession: URLSessionProtocol, @unchecked Sendable {
        private(set) var requestedURLs: [URL] = []

        func dataTask(with url: URL,
                      completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTaskProtocol {
            fatalError("unused")
        }

        func data(from url: URL) async throws -> (Data, URLResponse) {
            try await data(for: URLRequest(url: url))
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requestedURLs.append(request.url!)
            let body = Data(#"{"url": "https://googlevideo.example/audio", "duration": 100}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    func test_freshResolve_sendsCacheBypassParam() async throws {
        let session = RecordingSession()
        let resolver = StreamResolver(backendURL: "https://backend.example", session: session, apiKey: nil)

        _ = try await resolver.resolve(for: "dQw4w9WgXcQ", fresh: true)

        XCTAssertEqual(session.requestedURLs.count, 1)
        let url = session.requestedURLs[0].absoluteString
        XCTAssertTrue(url.contains("/api/resolve?video_id=dQw4w9WgXcQ"), "unexpected endpoint: \(url)")
        XCTAssertTrue(url.contains("fresh=1"), "fresh retry must bypass the backend resolve cache: \(url)")
    }

    func test_normalResolve_doesNotSendFresh() async throws {
        let session = RecordingSession()
        let resolver = StreamResolver(backendURL: "https://backend.example", session: session, apiKey: nil)

        _ = try await resolver.resolve(for: "dQw4w9WgXcQ")

        XCTAssertEqual(session.requestedURLs.count, 1)
        XCTAssertFalse(session.requestedURLs[0].absoluteString.contains("fresh"),
                       "normal plays must keep the cache's latency win")
    }
}
