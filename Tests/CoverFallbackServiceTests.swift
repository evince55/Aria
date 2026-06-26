import XCTest
@testable import Aria___Music_Browser

final class CoverFallbackServiceTests: XCTestCase {

    private var session: URLSession!
    private var service: CoverFallbackService!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockCoverBackend.self]
        session = URLSession(configuration: config)
        service = CoverFallbackService(
            baseURL: URL(string: "http://test.local")!,
            session: session
        )
        MockCoverBackend.reset()
    }

    func test_fetch_backendReturnsURL_downloadsAndWritesFile() async throws {
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        MockCoverBackend.nextResponse = .success(json: ["url": "http://test.local/cover.jpg"], imageData: imageData)
        let url = await service.fetch(title: "Song", artist: "Artist", album: "Album")
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func test_fetch_backendReturns404_returnsNil() async {
        MockCoverBackend.nextResponse = .notFound
        let url = await service.fetch(title: "Song", artist: "Artist", album: "Album")
        XCTAssertNil(url)
    }

    func test_fetch_backendReturns500_returnsNil() async {
        MockCoverBackend.nextResponse = .serverError
        let url = await service.fetch(title: "Song", artist: "Artist", album: "Album")
        XCTAssertNil(url)
    }

    func test_fetch_downloadFails_returnsNil() async {
        MockCoverBackend.nextResponse = .downloadFails
        let url = await service.fetch(title: "Song", artist: "Artist", album: "Album")
        XCTAssertNil(url)
    }
}

private final class MockCoverBackend: URLProtocol {
    enum Response {
        case success(json: [String: String], imageData: Data)
        case notFound
        case serverError
        case downloadFails
    }
    static var nextResponse: Response = .notFound
    static func reset() { nextResponse = .notFound }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "test.local"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch MockCoverBackend.nextResponse {
        case .success(let json, let imageData):
            if request.url?.path == "/api/cover" {
                guard let body = try? JSONSerialization.data(withJSONObject: json) else { return }
                sendResponse(statusCode: 200)
                client?.urlProtocol(self, didLoad: body)
            } else {
                sendResponse(statusCode: 200)
                client?.urlProtocol(self, didLoad: imageData)
            }
            client?.urlProtocolDidFinishLoading(self)
        case .notFound:
            sendResponse(statusCode: 404)
            client?.urlProtocolDidFinishLoading(self)
        case .serverError:
            sendResponse(statusCode: 500)
            client?.urlProtocolDidFinishLoading(self)
        case .downloadFails:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }

    private func sendResponse(statusCode: Int) {
        let c = client
        let u = request.url
        guard let c = c, let u = u else { return }
        guard let response = HTTPURLResponse(url: u, statusCode: statusCode, httpVersion: nil, headerFields: nil) else { return }
        c.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    override func stopLoading() {}
}
