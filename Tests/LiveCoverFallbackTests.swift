import XCTest
@testable import Aria___Music_Browser

final class LiveCoverFallbackTests: XCTestCase {

    private static var homelabHost: String {
        (Bundle(for: PlayerManager.self).object(forInfoDictionaryKey: "ARIA_HOMELAB_HOST") as? String) ?? "192.0.2.1"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.homelabHost == "192.0.2.1" {
            throw XCTSkip("ARIA_HOMELAB_HOST is placeholder (192.0.2.1); skipping live test")
        }
    }

    func test_liveCoverEndpoint_returnsURL() async throws {
        let baseURL = URL(string: "http://\(Self.homelabHost):8000")!
        let service = CoverFallbackService(baseURL: baseURL)
        let url = await service.fetch(title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera")
        XCTAssertNotNil(url, "Expected /api/cover to return a non-nil URL for a real artist+title")
    }
}
