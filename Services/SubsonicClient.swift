import CryptoKit
import Foundation

/// Client for the Subsonic REST API (Navidrome, Airsonic, Gonic, Astiga, …).
///
/// Conforms to both `StreamResolving` and `MusicSearching`, so pointing Aria at
/// a Subsonic server is a matter of constructing this instead of
/// `StreamResolver` + `YouTubeSearchService` — the player, prefetcher, EQ tap,
/// queue, and search UI are all unchanged.
///
/// **Why resolving is trivial here:** a Subsonic stream URL is deterministic
/// and never expires — `stream.view?id=…` plus auth params, which the server
/// serves as `audio/*` with byte-range support (verified: HTTP 206 +
/// `accept-ranges`). AVPlayer plays and seeks it directly. So none of the
/// YouTube-path machinery applies: no signed-URL expiry, no resolve cache, no
/// `fresh` bust, no extraction latency.
///
/// **Auth** uses the salted-token scheme (API 1.13.0+): `t = md5(password +
/// salt)` with a fresh random salt per request, so the password itself is never
/// transmitted. It is read from the Keychain, never `UserDefaults`.
actor SubsonicClient: StreamResolving, MusicSearching {
    /// Protocol version we claim. 1.16.1 is what Navidrome/Airsonic advertise
    /// and is the floor for `search3` + token auth.
    static let apiVersion = "1.16.1"
    /// `c` — client identifier the server logs.
    static let clientName = "Aria"

    let baseURL: String
    private let username: String
    private let password: String
    private let session: URLSessionProtocol
    /// One salt for this client's lifetime, not one per request.
    ///
    /// A per-request salt would make every generated URL unique, and
    /// `getCoverArt` URLs are handed to the image cache — a fresh salt on each
    /// render means a cache miss and a re-download of artwork the app already
    /// has (which a rate-limited server answers with HTTP 429). The salt is
    /// sent in the clear either way, so reusing it within a session costs
    /// nothing: it exists to stop precomputed tables against the password
    /// hash, which a per-session value still does.
    private let salt: String

    enum ClientError: LocalizedError, Equatable {
        case notConfigured
        case badURL
        case api(SubsonicError)
        case malformedResponse
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No Subsonic server is configured."
            case .badURL:
                return "That server URL isn't valid."
            case .api(let error):
                return error.friendlyMessage
            case .malformedResponse:
                return "The server's response wasn't valid Subsonic JSON. Check that the URL points at the server root (not /rest)."
            case .httpStatus(let code):
                return "The server returned HTTP \(code)."
            }
        }
    }

    init(
        baseURL: String,
        username: String,
        password: String,
        session: URLSessionProtocol,
        saltProvider: @escaping @Sendable () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased() }
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
        self.salt = saltProvider()
    }

    // MARK: - URL building

    /// Builds `<base>/rest/<method>.view` with auth + the caller's params.
    /// `nonisolated` because stream URLs must be constructible synchronously
    /// from the player path.
    nonisolated func endpoint(_ method: String, _ params: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(string: "\(baseURL)/rest/\(method).view") else { return nil }
        let token = Self.token(password: password, salt: salt)

        var items = [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: Self.clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
        items.append(contentsOf: params.map { URLQueryItem(name: $0.key, value: $0.value) }
                                       .sorted { $0.name < $1.name })
        components.queryItems = items
        return components.url
    }

    /// `t = md5(password + salt)`, lowercase hex — the Subsonic token scheme.
    nonisolated static func token(password: String, salt: String) -> String {
        Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ method: String, _ params: [String: String] = [:],
                                   as type: T.Type) async throws -> T {
        guard let url = endpoint(method, params) else { throw ClientError.badURL }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.httpStatus(http.statusCode)
        }
        guard let envelope = try? JSONDecoder().decode(SubsonicEnvelope<T>.self, from: data) else {
            throw ClientError.malformedResponse
        }
        return envelope.response
    }

    /// Verifies the server is reachable and the credentials work. Returns the
    /// server's self-reported identity for the Settings "Test Connection" row.
    func ping() async throws -> String {
        let status = try await get("ping", as: SubsonicStatus.self)
        guard status.isOK else {
            throw ClientError.api(status.error ?? SubsonicError(code: 0, message: nil))
        }
        let kind = status.type ?? "Subsonic"
        let version = status.serverVersion ?? status.version ?? ""
        return version.isEmpty ? kind : "\(kind) \(version)"
    }

    // MARK: - MusicSearching

    func search(query: String, limit: Int, offset: Int) async throws -> [Track] {
        let result = try await get("search3", [
            "query": query,
            "songCount": String(limit),
            "songOffset": String(offset),
            // Aria's search surface is songs-only; asking for 0 artists/albums
            // keeps the payload small on large libraries.
            "artistCount": "0",
            "albumCount": "0",
        ], as: SubsonicSearchResponse.self)

        guard result.status == "ok" else {
            throw ClientError.api(result.error ?? SubsonicError(code: 0, message: nil))
        }
        return (result.searchResult3?.song ?? []).map { song in
            song.asTrack(coverArtURL: song.coverArt.flatMap { coverArtURL(for: $0) })
        }
    }

    nonisolated func coverArtURL(for coverArtID: String, size: Int = 512) -> URL? {
        endpoint("getCoverArt", ["id": coverArtID, "size": String(size)])
    }

    // MARK: - StreamResolving

    /// No network call: the stream URL is deterministic. `duration` is nil
    /// because AVPlayer reads it from the stream itself (and search already
    /// supplied it on the `Track`).
    func resolve(for trackID: String) async throws -> ResolvedStream {
        guard let songID = SubsonicSong.serverID(fromTrackID: trackID) ?? optionalRawID(trackID),
              let url = endpoint("stream", ["id": songID]) else {
            throw ClientError.badURL
        }
        return ResolvedStream(url: url, duration: nil)
    }

    /// Nothing to bust — a Subsonic stream URL never goes stale.
    func resolve(for trackID: String, fresh: Bool) async throws -> ResolvedStream {
        try await resolve(for: trackID)
    }

    /// The download path is the same URL; the caller decides whether to persist
    /// the bytes.
    func stream(for trackID: String) async throws -> URL {
        try await resolve(for: trackID).url
    }

    /// Accept a bare server id too, so callers that already stripped the
    /// namespace still work.
    private nonisolated func optionalRawID(_ trackID: String) -> String? {
        trackID.contains(":") ? nil : trackID
    }
}
