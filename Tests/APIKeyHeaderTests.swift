import XCTest
@testable import Aria___Music_Browser

/// Verifies the iOS client attaches the `X-API-Key` header to backend requests
/// when a key is configured, and omits it otherwise (opt-in auth).
final class APIKeyHeaderTests: XCTestCase {

    private func ok(_ json: String, for url: URL) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    // MARK: - Request builder

    func test_backendGET_attachesKeyWhenPresent() {
        let req = URLRequest.backendGET(URL(string: "https://x/api/search")!, apiKey: "secret123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-API-Key"), "secret123")
    }

    func test_backendGET_omitsKeyWhenNilOrEmpty() {
        let nilReq = URLRequest.backendGET(URL(string: "https://x")!, apiKey: nil)
        XCTAssertNil(nilReq.value(forHTTPHeaderField: "X-API-Key"))
        let emptyReq = URLRequest.backendGET(URL(string: "https://x")!, apiKey: "")
        XCTAssertNil(emptyReq.value(forHTTPHeaderField: "X-API-Key"))
    }

    // MARK: - StreamResolver

    func test_streamResolver_sendsKey() async throws {
        let mock = MockURLSession()
        mock.dataFromHandler = { url in self.ok(#"{"url":"https://g/v","duration":100}"#, for: url) }
        let resolver = StreamResolver(backendURL: "https://api", session: mock, apiKey: "k-stream")

        _ = try await resolver.resolve(for: "abcdefghijk")

        XCTAssertEqual(mock.recordedRequestObjects.last?.value(forHTTPHeaderField: "X-API-Key"), "k-stream")
    }

    func test_streamResolver_noKeyMeansNoHeader() async throws {
        let mock = MockURLSession()
        mock.dataFromHandler = { url in self.ok(#"{"url":"https://g/v"}"#, for: url) }
        let resolver = StreamResolver(backendURL: "https://api", session: mock, apiKey: nil)

        _ = try await resolver.resolve(for: "abcdefghijk")

        XCTAssertNil(mock.recordedRequestObjects.last?.value(forHTTPHeaderField: "X-API-Key"))
    }

    // MARK: - RadioService

    func test_radioService_sendsKey() async throws {
        let mock = MockURLSession()
        mock.dataFromHandler = { url in self.ok("[]", for: url) }
        let radio = RadioService(backendURL: "https://api", session: mock, apiKey: "k-radio")

        _ = try await radio.similar(to: "abcdefghijk", limit: 5)

        XCTAssertEqual(mock.recordedRequestObjects.last?.value(forHTTPHeaderField: "X-API-Key"), "k-radio")
    }
}
