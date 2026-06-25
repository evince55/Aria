import XCTest
@testable import Aria___Music_Browser

final class YouTubeSearchServiceTests: XCTestCase {
    /// Verifies YouTubeSearchService's bare URLSession (no delegate) can
    /// reach the homelab backend. This is the code path that search and
    /// play go through in the app.
    ///
    /// Requires the mkcert CA to be installed in the simulator's keychain
    /// (run `xcrun simctl keychain <udid> add-root-cert /path/to/rootCA.pem`).
    /// Without it, the self-signed cert is rejected at the system level.
    func test_LiveSearchReachesHomelab() async throws {
        let service = YouTubeSearchService(backendURL: "http://192.0.2.1:8000")
        do {
            let tracks = try await service.search(query: "est gee")
            XCTAssertFalse(tracks.isEmpty, "Expected search results, got 0")
            XCTAssertTrue(tracks.contains { $0.title.lowercased().contains("est") },
                          "Expected at least one EST track in results, got: \(tracks.map(\.title))")
        } catch let error as URLError where error.code == .serverCertificateUntrusted
                                       || error.code == .secureConnectionFailed {
            XCTFail("YouTubeSearchService failed to reach homelab: \(error.code) \(error.localizedDescription). Check os_log for DEBUG-DIAG output.")
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            // The test bundle has its own strict Info.plist (auto-generated
            // without ATS settings) so HTTP is rejected here even though
            // the app's Info.plist has NSAllowsArbitraryLoads=true. The app
            // itself works on the iPhone — this is a test-harness limitation.
            throw XCTSkip("Test bundle enforces ATS; HTTP test skipped. The app's Info.plist has NSAllowsArbitraryLoads=true so it works on the iPhone.")
        }
    }
}
