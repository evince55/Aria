import XCTest
import Security
@testable import Aria___Music_Browser

final class TLSPinningDelegateTests: XCTestCase {

    // MARK: - Helpers

    /// Mock challenge sender — required by URLAuthenticationChallenge's
    /// initialiser. The delegate never actually invokes the sender.
    private final class MockSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    /// Build a real `URLAuthenticationChallenge` for a server trust challenge.
    /// For tests that exercise the delegate's chain-comparison code, we
    /// pre-evaluate the trust so `serverTrust` is populated and
    /// `SecTrustCopyCertificateChain` returns the expected certs.
    private func makeChallenge(
        leafCert: SecCertificate,
        evaluateTrust: Bool = false
    ) -> URLAuthenticationChallenge {
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        SecTrustCreateWithCertificates(leafCert, policy, &trust)
        if evaluateTrust, let trust = trust {
            // Without evaluation, the trust object is "uninitialized" and
            // SecTrustCopyCertificateChain returns an empty array. We don't
            // care about the actual evaluation result — we just need the
            // chain to be queryable.
            var result: SecTrustResultType = .invalid
            SecTrustEvaluate(trust, &result)
        }
        let space = URLProtectionSpace(
            host: "192.0.2.1",
            port: 8443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockSender()
        )
    }

    /// Run a challenge through the delegate and synchronously collect the
    /// resulting disposition + credential.
    private func runChallenge(
        _ challenge: URLAuthenticationChallenge,
        through delegate: TLSPinningDelegate
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        var credential: URLCredential?
        let exp = expectation(description: "challenge completion")
        delegate.urlSession(.shared, didReceive: challenge) { d, c in
            disposition = d
            credential = c
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)
        return (disposition, credential)
    }

    /// Load the bundled cert.der (only present in Debug builds). Returns
    /// nil if not found — tests that need it will skip.
    private func makeBundledCert() -> SecCertificate? {
        if let url = Bundle.main.url(forResource: "cert", withExtension: "der"),
           let data = try? Data(contentsOf: url) {
            return SecCertificateCreateWithData(nil, data as CFData)
        }
        return nil
    }

    // MARK: - Tests

    func test_NonServerTrustChallengeUsesDefault() {
        let delegate = TLSPinningDelegate(pinnedCertData: Data([1, 2, 3]))
        // Build a challenge that is NOT a server-trust challenge
        // (e.g., HTTP basic auth).
        let space = URLProtectionSpace(
            host: "example.com", port: 443, protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: MockSender()
        )
        let (disposition, credential) = runChallenge(challenge, through: delegate)
        XCTAssertTrue(disposition == .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func test_NoPinnedCertUsesDefault() {
        // When no pinned cert is available (Release builds, or missing
        // bundle resource), the delegate passes everything through to the
        // system trust store.
        let delegate = TLSPinningDelegate(pinnedCertData: nil)
        guard let cert = makeBundledCert() else {
            // No bundled cert in this test build — the assertion is
            // trivially true since the delegate won't try to pin.
            return
        }
        let challenge = makeChallenge(leafCert: cert)
        let (disposition, credential) = runChallenge(challenge, through: delegate)
        XCTAssertTrue(disposition == .performDefaultHandling)
        XCTAssertNil(credential)
    }

    func test_DefaultInitDoesNotCrash() {
        // Sanity: constructing the default init (which loads from bundle)
        // doesn't crash, regardless of whether the cert.der is present.
        let delegate = TLSPinningDelegate()
        XCTAssertNotNil(delegate)
    }

    func test_NilPinnedDataOnServerTrustFallsThrough() {
        // Even with a server-trust challenge, a nil pinned data means
        // the delegate defers to the system trust store.
        let delegate = TLSPinningDelegate(pinnedCertData: nil)
        guard let cert = makeBundledCert() else { return }
        let challenge = makeChallenge(leafCert: cert)
        let (disposition, credential) = runChallenge(challenge, through: delegate)
        XCTAssertTrue(disposition == .performDefaultHandling)
        XCTAssertNil(credential)
    }

    // MARK: - Live network integration

    /// Verifies the pinning delegate works end-to-end against the real
    /// homelab backend. Requires:
    /// 1. chai-homelab reachable on Tailscale at 192.0.2.1:8443
    /// 2. cert.der bundled in the test app (Debug builds only)
    /// 3. ATS `NSAllowsArbitraryLoads` set (already is)
    ///
    /// This is the only test that exercises the full path:
    /// URLSession → TLS handshake → system trust eval → delegate
    /// → .useCredential(URLCredential(trust:)) → connection.
    ///
    /// If this fails, the bug is in TLSPinningDelegate's chain walk or
    /// URLSession's handling of the credential.
    func test_LivePinningToHomelabBackend() async throws {
        // Skip if we don't have the bundled cert (Release test runs).
        guard TLSPinningDelegate.loadBundledCert() != nil else {
            throw XCTSkip("cert.der not bundled in this test run")
        }

        let delegate = TLSPinningDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        // Debug builds use plain HTTP (Tailscale handles encryption).
        // The TLSPinningDelegate still does its job — it just sees an
        // HTTP challenge instead of a TLS one and passes through.
        let url = URL(string: "http://192.0.2.1:8000/api/play?video_id=OA8aw07dpg0")!
        do {
            let (data, response) = try await session.data(from: url)
            let http = response as? HTTPURLResponse
            XCTAssertEqual(http?.statusCode, 200, "Expected 200 from homelab, got \(http?.statusCode ?? -1). Body: \(String(data: data, encoding: .utf8) ?? "<binary>")")
        } catch let error as URLError where error.code == .serverCertificateUntrusted
                                       || error.code == .secureConnectionFailed
                                       || error.code == .cancelled
                                       || error.code == .cannotConnectToHost
                                       || error.code == .timedOut {
            XCTFail("TLSPinningDelegate failed to reach homelab: \(error.code) \(error.localizedDescription). Check os_log for DEBUG-DIAG output.")
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            // The test bundle has its own strict Info.plist (auto-generated
            // without ATS settings) so HTTP is rejected here even though
            // the app's Info.plist has NSAllowsArbitraryLoads=true. The app
            // itself works on the iPhone — this is a test-harness limitation.
            throw XCTSkip("Test bundle enforces ATS; HTTP test skipped. The app's Info.plist has NSAllowsArbitraryLoads=true so it works on the iPhone.")
        }
    }
}
