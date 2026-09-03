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
    static let serverKindKey = "backend_server_kind"
    static let subsonicUsernameKey = "subsonic_username"
    /// RFC 5737 TEST-NET-1 — the public-source placeholder for the homelab IP.
    static let placeholderHost = "192.0.2.1"

    /// Which protocol the configured server speaks. One server at a time —
    /// multi-server profiles are a later phase.
    enum ServerKind: String, CaseIterable, Identifiable {
        /// Aria's own yt-dlp backend (`/api/search`, `/api/resolve`).
        case aria
        /// Any Subsonic-compatible server (Navidrome, Airsonic, Gonic, …).
        case subsonic

        var id: String { rawValue }

        /// Short enough to sit inline in the Settings picker without wrapping.
        var label: String {
            switch self {
            case .aria: return "Aria"
            case .subsonic: return "Subsonic"
            }
        }

        /// Placeholder for the URL field — a Subsonic URL is the server root,
        /// which is the single most common setup mistake.
        var urlPlaceholder: String {
            switch self {
            case .aria: return "Server URL (https://host:port)"
            case .subsonic: return "Server URL (https://music.example.com)"
            }
        }
    }

    nonisolated static var serverKind: ServerKind {
        ServerKind(rawValue: UserDefaults.standard.string(forKey: serverKindKey) ?? "") ?? .aria
    }

    nonisolated static var subsonicUsername: String? {
        normalize(UserDefaults.standard.string(forKey: subsonicUsernameKey))
    }

    /// Read from the Keychain — never `UserDefaults`. See `KeychainStore`.
    nonisolated static var subsonicPassword: String? {
        KeychainStore.get(account: KeychainStore.subsonicPasswordAccount)
    }

    /// A Subsonic server needs URL + username + password before it can be used;
    /// until then the app stays in local-files-only mode.
    nonisolated static var isSubsonicConfigured: Bool {
        serverKind == .subsonic && isConfigured
    }

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

    /// Pure form of `isConfigured` — takes the values rather than reading them,
    /// so a SwiftUI view can evaluate it against its *live* published state.
    /// See `SettingsManager.isServerConfigured` for why that matters.
    nonisolated static func isConfigured(kind: ServerKind, baseURL: String,
                                         subsonicUsername: String?,
                                         subsonicPassword: String?) -> Bool {
        guard !baseURL.contains(placeholderHost) else { return false }
        switch kind {
        case .aria:
            return true
        case .subsonic:
            return normalize(subsonicUsername) != nil
                && (subsonicPassword.map { !$0.isEmpty } ?? false)
        }
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
        baseURL(override: UserDefaults.standard.string(forKey: urlOverrideKey))
    }

    /// Same resolution with a caller-supplied override, so a view can compute
    /// the live URL before `save()` has written it to `UserDefaults`.
    nonisolated static func baseURL(override: String?) -> String {
        resolve(
            override: override,
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

    /// `false` while no usable server is configured — streaming features hide
    /// and the app runs as a local-files-only player. A Subsonic server counts
    /// only once it also has credentials.
    nonisolated static var isConfigured: Bool {
        isConfigured(kind: serverKind, baseURL: baseURL,
                     subsonicUsername: subsonicUsername,
                     subsonicPassword: subsonicPassword)
    }

    /// Everything needed to build a client, captured as a value.
    ///
    /// Callers that have a `SettingsManager` pass its live fields; the rest use
    /// `.current`, which reads `UserDefaults` and the Keychain. Threading a
    /// snapshot keeps the Keychain out of the per-search path and lets the app
    /// work off state the user has typed but not yet persisted.
    struct Snapshot: Sendable, Equatable {
        var kind: ServerKind
        var baseURL: String
        var subsonicUsername: String?
        var subsonicPassword: String?

        /// Read straight from `UserDefaults` + the Keychain. For code with no
        /// `SettingsManager` in scope — `PlayerManager`'s initialisers.
        nonisolated static var current: Snapshot {
            Snapshot(kind: BackendConfig.serverKind,
                     baseURL: BackendConfig.baseURL,
                     subsonicUsername: BackendConfig.subsonicUsername,
                     subsonicPassword: BackendConfig.subsonicPassword)
        }
    }

    /// Builds the search/stream client for the configured server. Returning the
    /// protocols keeps `PlayerManager` and `SearchView` unaware of which
    /// backend is in play. `nil` means "not usable yet" — a Subsonic server
    /// without credentials — and callers fall back to the Aria path.
    nonisolated static func makeClient(session: URLSessionProtocol,
                                       from snapshot: Snapshot) -> (search: MusicSearching, resolver: StreamResolving)? {
        switch snapshot.kind {
        case .aria:
            return (YouTubeSearchService(backendURL: snapshot.baseURL), StreamResolver(session: session))
        case .subsonic:
            guard let username = normalize(snapshot.subsonicUsername),
                  let password = snapshot.subsonicPassword, !password.isEmpty else {
                return nil
            }
            let client = SubsonicClient(baseURL: snapshot.baseURL, username: username,
                                        password: password, session: session)
            return (client, client)
        }
    }

    nonisolated static func makeClient(session: URLSessionProtocol) -> (search: MusicSearching, resolver: StreamResolving)? {
        makeClient(session: session, from: .current)
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
