import Foundation

/// Decoding for the Subsonic REST envelope.
///
/// Every response is wrapped in `{"subsonic-response": {...}}` with a
/// `status` of `"ok"` or `"failed"`; failures carry `error.code` +
/// `error.message` while still returning HTTP 200, so the status field — not
/// the status code — is what decides success.
///
/// Shapes verified live against Navidrome 0.63.2 (API 1.16.1). Everything
/// except `id` is optional on purpose: Gonic/Airsonic/Astiga each omit
/// different fields, and a missing `album` must never fail a whole search.
struct SubsonicEnvelope<Payload: Decodable>: Decodable {
    let response: Payload

    private enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

/// Fields common to every response body, used to detect API-level failures.
struct SubsonicStatus: Decodable {
    let status: String
    let version: String?
    let type: String?
    let serverVersion: String?
    let openSubsonic: Bool?
    let error: SubsonicError?

    var isOK: Bool { status == "ok" }
}

struct SubsonicError: Decodable, Equatable {
    let code: Int
    let message: String?

    /// Subsonic's documented error codes; 40/41 are the ones users actually hit.
    var friendlyMessage: String {
        switch code {
        case 40: return "Wrong username or password."
        case 41: return "This server requires LDAP authentication, which Aria doesn't support."
        case 30: return "The server's API version is older than Aria requires."
        case 50: return "That account isn't allowed to stream from this server."
        case 60: return "The server requires a Subsonic subscription that has lapsed."
        case 70: return "Not found on the server."
        default: return message ?? "The server returned error \(code)."
        }
    }
}

/// `search3` payload.
struct SubsonicSearchResponse: Decodable {
    let status: String
    let error: SubsonicError?
    let searchResult3: SearchResult3?

    struct SearchResult3: Decodable {
        let song: [SubsonicSong]?
    }
}

/// One song from `search3` / `getAlbum`. Field names match the wire format.
struct SubsonicSong: Decodable, Equatable {
    let id: String
    let title: String?
    let artist: String?
    let album: String?
    let duration: Int?
    let suffix: String?
    let bitRate: Int?
    let contentType: String?
    let coverArt: String?

    /// Maps onto Aria's `Track`. The id is namespaced so a Subsonic track can
    /// never collide with a YouTube video id or a `local:` file in favorites,
    /// playlists, or download records — including after the user switches
    /// which server they're pointed at.
    func asTrack(coverArtURL: URL?) -> Track {
        Track(
            id: "\(SubsonicSong.idPrefix)\(id)",
            title: title ?? "Unknown title",
            artist: artist ?? "Unknown artist",
            thumbnailURL: coverArtURL,
            duration: duration.map(Double.init),
            album: album
        )
    }

    static let idPrefix = "subsonic:"

    /// Recovers the server-side id from a namespaced `Track.id`.
    static func serverID(fromTrackID trackID: String) -> String? {
        guard trackID.hasPrefix(idPrefix) else { return nil }
        return String(trackID.dropFirst(idPrefix.count))
    }

    /// A `suffix`/`bitRate` pair maps straight onto the existing quality badge,
    /// so Subsonic tracks get the same FLAC / MP3 320 treatment as local files.
    var qualityFileName: String? {
        guard let suffix, !suffix.isEmpty else { return nil }
        return "\(id).\(suffix)"
    }
}
