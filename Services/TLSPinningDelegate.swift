import Foundation
import Security
import CryptoKit
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "TLSPinning")

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// URLSessionDelegate that pins a bundled self-signed cert to bypass the
/// system TLS trust check for the local-dev backend on `192.0.2.1:8443`.
///
/// In Release builds, no pinning is performed — public CA-signed certs (Render,
/// Google) work normally. In Debug builds, the bundled `cert.der` is loaded
/// from the app bundle and any server chain containing a matching cert is
/// accepted.
///
/// This is the only correct way to trust a self-signed cert on iOS 14+:
/// `NSAllowsArbitraryLoads = true` disables ATS but does NOT bypass TLS
/// cert validation. Cert validation runs as a separate layer.
final class TLSPinningDelegate: NSObject, URLSessionDelegate {
    /// Raw DER bytes of the pinned cert. `nil` in Release builds (or if the
    /// resource is missing from the bundle) means the delegate passes
    /// everything through to the system trust store.
    let pinnedCertData: Data?

    override init() {
        #if DEBUG
        if let url = Bundle.main.url(forResource: "cert", withExtension: "der"),
           let data = try? Data(contentsOf: url) {
            self.pinnedCertData = data
        } else {
            self.pinnedCertData = nil
        }
        #else
        self.pinnedCertData = nil
        #endif
        super.init()
        log.notice("DEBUG-DIAG init: pinnedCertData=\(self.pinnedCertData.map { "\($0.count)B sha256=\($0.sha256Hex)" } ?? "nil", privacy: .public)")
    }

    /// Designated init for tests — allows injecting a custom DER blob.
    init(pinnedCertData: Data?) {
        self.pinnedCertData = pinnedCertData
        super.init()
        log.notice("DEBUG-DIAG init(pinnedCertData:): pinnedCertData=\(self.pinnedCertData.map { "\($0.count)B sha256=\($0.sha256Hex)" } ?? "nil", privacy: .public)")
    }

    /// Load the bundled cert.der. Returns nil in Release builds or if the
    /// resource is missing. Public so tests can probe bundle wiring without
    /// constructing a delegate.
    static func loadBundledCert() -> Data? {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "cert", withExtension: "der"),
              let data = try? Data(contentsOf: url) else { return nil }
        return data
        #else
        return nil
        #endif
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        let method = challenge.protectionSpace.authenticationMethod
        log.notice("DEBUG-DIAG challenge: host=\(host, privacy: .public) method=\(method, privacy: .public)")

        // Not a server-trust challenge (e.g., basic auth, client cert).
        // Defer to default handling.
        guard method == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            log.notice("DEBUG-DIAG non-server-trust: deferring to default")
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1) System trust. Real CAs (googlevideo.com, Render) pass through.
        // Self-signed fails here, but that's fine — we have a pin to fall
        // back on for the dev backend.
        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            log.notice("DEBUG-DIAG system trust accepted, using system credential")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // 2) Hostname gate. Pin only fires for the dev backend, never for
        // arbitrary self-signed hosts on the open internet.
        guard host == "192.0.2.1" else {
            log.error("DEBUG-DIAG system trust failed and host=\(host, privacy: .public) is not pinned: cancelling")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 3) Pin fallback. Get the leaf cert directly — works on both
        // evaluated and unevaluated trust objects.
        guard let pinnedData = pinnedCertData,
              let leaf = SecTrustGetCertificateAtIndex(serverTrust, 0) else {
            log.error("DEBUG-DIAG no pinned cert available, cancelling")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let leafData = SecCertificateCopyData(leaf) as Data
        guard leafData == pinnedData else {
            let leafSha = leafData.sha256Hex
            let pinSha = pinnedData.sha256Hex
            log.error("DEBUG-DIAG leaf cert does not match pin. leaf sha256=\(leafSha, privacy: .public) pin sha256=\(pinSha, privacy: .public)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 4) Modify the original server trust in place to anchor our
        // pinned cert. The URLSession holds a reference to this trust
        // object — modifying it directly affects the actual TLS
        // validation, not just the credential we hand back.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(serverTrust, [policy] as CFArray)
        SecTrustSetAnchorCertificates(serverTrust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)
        log.notice("DEBUG-DIAG pinned cert accepted, anchored on original serverTrust (host=\(host, privacy: .public))")
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
