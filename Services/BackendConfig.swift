import Foundation

/// Resolves which backend the app talks to, and with which API key.
///
/// Precedence (first non-empty wins):
/// 1. The in-app override (Settings → Backend), stored in `UserDefaults` —
///    lets a device install point at any server without editing the plist.
/// 2. The `ARIA_BACKEND_URL` Info.plist key (TestFlight/App Store builds).
/// 3. The homelab fallback `http://<ARIA_HOMELAB_HOST>:8000` (dev default).
///
/// When nothing was ever configured the resolved URL still contains the
/// RFC 5737 TEST-NET-1 placeholder — `isConfigured` is then `false` and the
/// app runs as a local-files-only player (the Search tab is hidden).
///
/// Everything here is `nonisolated`: `UserDefaults` and `Bundle` are
/// thread-safe, and callers include nonisolated service default arguments.
enum BackendConfig {
    static let urlOverrideKey = "backend_url_override"
    static let apiKeyOverrideKey = "backend_api_key_override"
    /// RFC 5737 TEST-NET-1 — the public-source placeholder for the homelab IP.
    static let placeholderHost = "192.0.2.1"

    // MARK: - Pure resolution (unit-tested)

    /// Pure precedence logic: override → plist URL → homelab fallback.
    nonisolated static func resolve(override: String?, plistURL: String?, homelabHost: String?) -> String {
        if let url = normalize(override) { return url }
        if let url = normalize(plistURL) { return url }
        let host = normalize(homelabHost) ?? placeholderHost
        return "http://\(host):8000"
    }

    /// Trims whitespace and trailing slashes; empty/blank collapses to `nil`.
    nonisolated static func normalize(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    /// Pure key precedence: trimmed non-empty override → trimmed plist key.
    nonisolated static func resolveAPIKey(override: String?, plistKey: String?) -> String? {
        let trim = { (s: String?) -> String? in
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        return trim(override) ?? trim(plistKey)
    }

    // MARK: - Runtime values

    nonisolated static var baseURL: String {
        resolve(
            override: UserDefaults.standard.string(forKey: urlOverrideKey),
            plistURL: Bundle.main.object(forInfoDictionaryKey: "ARIA_BACKEND_URL") as? String,
            homelabHost: Bundle.main.object(forInfoDictionaryKey: "ARIA_HOMELAB_HOST") as? String
        )
    }

    nonisolated static var apiKey: String? {
        resolveAPIKey(
            override: UserDefaults.standard.string(forKey: apiKeyOverrideKey),
            plistKey: Bundle.main.object(forInfoDictionaryKey: "ARIA_API_KEY") as? String
        )
    }

    /// `false` while the resolved URL still points at the placeholder — i.e.
    /// no server was ever configured and streaming features should hide.
    nonisolated static var isConfigured: Bool {
        !baseURL.contains(placeholderHost)
    }

    /// The base URL that WOULD resolve if `override` were the in-app override
    /// value, or `nil` when that resolution is still the unconfigured
    /// placeholder. Lets Combine subscribers of the override react to the
    /// value *emitted* by the publisher instead of re-reading `UserDefaults` —
    /// which, on a willSet emission, still holds the OLD value (the persisted
    /// write lands only after MoreView's `onChange` fires `save()`).
    nonisolated static func resolvedBaseURL(forOverride override: String?) -> String? {
        let url = resolve(
            override: override,
            plistURL: Bundle.main.object(forInfoDictionaryKey: "ARIA_BACKEND_URL") as? String,
            homelabHost: Bundle.main.object(forInfoDictionaryKey: "ARIA_HOMELAB_HOST") as? String
        )
        return url.contains(placeholderHost) ? nil : url
    }
}
