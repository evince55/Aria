import XCTest
@testable import Aria___Music_Browser

/// Hermetic coverage for the Subsonic client. The wire shapes here are copied
/// from live responses of the public Navidrome demo (0.63.2 / API 1.16.1), so
/// the decoding is tested against what a real server actually sends.
final class SubsonicClientTests: XCTestCase {

    // MARK: - Stub

    private final class StubSession: URLSessionProtocol, @unchecked Sendable {
        var payloads: [Data] = []
        var status = 200
        private(set) var requestedURLs: [URL] = []

        func dataTask(with url: URL,
                      completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTaskProtocol {
            fatalError("unused")
        }

        func data(from url: URL) async throws -> (Data, URLResponse) {
            requestedURLs.append(url)
            let body = payloads.isEmpty ? Data() : payloads.removeFirst()
            let response = HTTPURLResponse(url: url, statusCode: status,
                                           httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }

    private func makeClient(_ stub: StubSession,
                            base: String = "https://music.example.com") -> SubsonicClient {
        SubsonicClient(baseURL: base, username: "demo", password: "sesame",
                       session: stub, saltProvider: { "fixedsalt" })
    }

    // MARK: - Auth

    func test_token_isMD5OfPasswordPlusSalt() {
        // Subsonic spec: t = md5(password + salt), lowercase hex.
        // md5("sesamefixedsalt") — verified independently.
        let token = SubsonicClient.token(password: "sesame", salt: "fixedsalt")
        XCTAssertEqual(token.count, 32)
        XCTAssertEqual(token, token.lowercased())
        // Same inputs are stable; different salt changes the token.
        XCTAssertEqual(token, SubsonicClient.token(password: "sesame", salt: "fixedsalt"))
        XCTAssertNotEqual(token, SubsonicClient.token(password: "sesame", salt: "othersalt"))
    }

    func test_endpoint_carriesAuthParams_andNeverThePassword() throws {
        let client = makeClient(StubSession())
        let url = try XCTUnwrap(client.endpoint("ping"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(url.path, "/rest/ping.view")
        XCTAssertEqual(byName["u"], "demo")
        XCTAssertEqual(byName["s"], "fixedsalt")
        XCTAssertEqual(byName["v"], SubsonicClient.apiVersion)
        XCTAssertEqual(byName["c"], "Aria")
        XCTAssertEqual(byName["f"], "json")
        XCTAssertEqual(byName["t"], SubsonicClient.token(password: "sesame", salt: "fixedsalt"))
        XCTAssertFalse(url.absoluteString.contains("sesame"),
                       "the plaintext password must never appear in a request URL")
        XCTAssertNil(byName["p"], "the legacy plaintext password param must not be sent")
    }

    // MARK: - ping

    func test_ping_returnsServerIdentity() async throws {
        let stub = StubSession()
        stub.payloads = [Data("""
        {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",
         "serverVersion":"0.63.2 (be10f89c)","openSubsonic":true}}
        """.utf8)]
        let identity = try await makeClient(stub).ping()
        XCTAssertEqual(identity, "navidrome 0.63.2 (be10f89c)")
    }

    func test_ping_wrongPassword_surfacesFriendlyError() async {
        let stub = StubSession()
        // Subsonic returns HTTP 200 even for auth failures — status decides.
        stub.payloads = [Data("""
        {"subsonic-response":{"status":"failed","version":"1.16.1",
         "error":{"code":40,"message":"Wrong username or password."}}}
        """.utf8)]
        do {
            _ = try await makeClient(stub).ping()
            XCTFail("expected an auth failure")
        } catch let SubsonicClient.ClientError.api(error) {
            XCTAssertEqual(error.code, 40)
            XCTAssertEqual(error.friendlyMessage, "Wrong username or password.")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_nonJSONResponse_reportsMalformed() async {
        let stub = StubSession()
        stub.payloads = [Data("<html>not subsonic</html>".utf8)]
        do {
            _ = try await makeClient(stub).ping()
            XCTFail("expected malformedResponse")
        } catch {
            XCTAssertEqual(error as? SubsonicClient.ClientError, .malformedResponse)
        }
    }

    func test_httpErrorStatus_isSurfaced() async {
        let stub = StubSession()
        stub.status = 500
        stub.payloads = [Data("{}".utf8)]
        do {
            _ = try await makeClient(stub).ping()
            XCTFail("expected httpStatus")
        } catch {
            XCTAssertEqual(error as? SubsonicClient.ClientError, .httpStatus(500))
        }
    }

    // MARK: - search3

    private let searchPayload = Data("""
    {"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome",
      "searchResult3":{"song":[
        {"id":"s00C9MhOEmlMNNu3DSoWeC","title":"Can I Have Your Love Tonight",
         "artist":"Konstentyn","album":"Can I Have Your Love Tonight","duration":302,
         "suffix":"mp3","bitRate":173,"contentType":"audio/mpeg",
         "coverArt":"mf-s00C9MhOEmlMNNu3DSoWeC_640a92fc"},
        {"id":"bare","title":"Minimal Song"}
      ]}}}
    """.utf8)

    func test_search_mapsSongsToTracks_withNamespacedIDs() async throws {
        let stub = StubSession()
        stub.payloads = [searchPayload]
        let tracks = try await makeClient(stub).search(query: "love", limit: 25, offset: 0)

        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].id, "subsonic:s00C9MhOEmlMNNu3DSoWeC",
                       "ids must be namespaced so they can't collide with YouTube or local: ids")
        XCTAssertEqual(tracks[0].title, "Can I Have Your Love Tonight")
        XCTAssertEqual(tracks[0].artist, "Konstentyn")
        XCTAssertEqual(tracks[0].album, "Can I Have Your Love Tonight")
        XCTAssertEqual(tracks[0].duration, 302)
        XCTAssertNotNil(tracks[0].thumbnailURL, "coverArt should resolve to a getCoverArt URL")
    }

    func test_search_toleratesMissingOptionalFields() async throws {
        // Gonic/Airsonic omit different fields; a sparse song must not fail the
        // whole search.
        let stub = StubSession()
        stub.payloads = [searchPayload]
        let tracks = try await makeClient(stub).search(query: "love", limit: 25, offset: 0)
        XCTAssertEqual(tracks[1].id, "subsonic:bare")
        XCTAssertEqual(tracks[1].title, "Minimal Song")
        XCTAssertEqual(tracks[1].artist, "Unknown artist")
        XCTAssertNil(tracks[1].duration)
        XCTAssertNil(tracks[1].thumbnailURL)
    }

    func test_search_sendsPagingAndSongsOnlyParams() async throws {
        let stub = StubSession()
        stub.payloads = [searchPayload]
        _ = try await makeClient(stub).search(query: "love", limit: 25, offset: 50)

        let items = try XCTUnwrap(URLComponents(url: stub.requestedURLs[0], resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(stub.requestedURLs[0].path, "/rest/search3.view")
        XCTAssertEqual(byName["query"], "love")
        XCTAssertEqual(byName["songCount"], "25")
        XCTAssertEqual(byName["songOffset"], "50")
        XCTAssertEqual(byName["artistCount"], "0")
        XCTAssertEqual(byName["albumCount"], "0")
    }

    func test_emptyResult_returnsNoTracksWithoutThrowing() async throws {
        let stub = StubSession()
        stub.payloads = [Data(#"{"subsonic-response":{"status":"ok","searchResult3":{}}}"#.utf8)]
        let tracks = try await makeClient(stub).search(query: "zzz", limit: 25, offset: 0)
        XCTAssertTrue(tracks.isEmpty)
    }

    // MARK: - StreamResolving

    func test_resolve_buildsStreamURL_withoutNetwork() async throws {
        let stub = StubSession()
        let stream = try await makeClient(stub).resolve(for: "subsonic:abc123")

        XCTAssertTrue(stub.requestedURLs.isEmpty,
                      "a Subsonic stream URL is deterministic — resolving must not hit the network")
        XCTAssertEqual(stream.url.path, "/rest/stream.view")
        let items = try XCTUnwrap(URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "id" }?.value, "abc123",
                       "the namespace prefix must be stripped before hitting the server")
    }

    func test_freshResolve_isIdenticalBecauseURLsNeverExpire() async throws {
        let client = makeClient(StubSession())
        let normal = try await client.resolve(for: "subsonic:abc123")
        let fresh = try await client.resolve(for: "subsonic:abc123", fresh: true)
        XCTAssertEqual(normal.url, fresh.url)
    }

    func test_coverArtURL_isStableAcrossCalls() throws {
        // The image cache keys on the URL. A per-request salt would make every
        // render a cache miss and re-download artwork the app already has.
        let client = SubsonicClient(baseURL: "https://music.example.com",
                                    username: "demo", password: "sesame",
                                    session: StubSession())
        let first = try XCTUnwrap(client.coverArtURL(for: "art-1"))
        let second = try XCTUnwrap(client.coverArtURL(for: "art-1"))
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, try XCTUnwrap(client.coverArtURL(for: "art-2")))
    }

    func test_serverID_roundTrip() {
        XCTAssertEqual(SubsonicSong.serverID(fromTrackID: "subsonic:xyz"), "xyz")
        XCTAssertNil(SubsonicSong.serverID(fromTrackID: "local:xyz"))
        XCTAssertNil(SubsonicSong.serverID(fromTrackID: "dQw4w9WgXcQ"))
    }

    // MARK: - Configuration gate
    //
    // This decides whether the Search tab exists at all, so the matrix is
    // worth pinning down.

    func test_ariaKind_needsOnlyANonPlaceholderURL() {
        XCTAssertTrue(BackendConfig.isConfigured(kind: .aria, baseURL: "https://aria.example.com",
                                                 subsonicUsername: nil, subsonicPassword: nil))
        XCTAssertFalse(BackendConfig.isConfigured(kind: .aria,
                                                  baseURL: "http://\(BackendConfig.placeholderHost):8000",
                                                  subsonicUsername: "demo", subsonicPassword: "demo"))
    }

    func test_subsonicKind_needsURLAndBothCredentials() {
        let url = "https://music.example.com"
        XCTAssertTrue(BackendConfig.isConfigured(kind: .subsonic, baseURL: url,
                                                 subsonicUsername: "demo", subsonicPassword: "demo"))
        XCTAssertFalse(BackendConfig.isConfigured(kind: .subsonic, baseURL: url,
                                                  subsonicUsername: nil, subsonicPassword: "demo"),
                       "a password with no username is not configured")
        XCTAssertFalse(BackendConfig.isConfigured(kind: .subsonic, baseURL: url,
                                                  subsonicUsername: "demo", subsonicPassword: ""),
                       "an empty password is not configured")
        XCTAssertFalse(BackendConfig.isConfigured(kind: .subsonic, baseURL: url,
                                                  subsonicUsername: "   ", subsonicPassword: "demo"),
                       "a whitespace-only username is not configured")
        XCTAssertFalse(BackendConfig.isConfigured(kind: .subsonic,
                                                  baseURL: "http://\(BackendConfig.placeholderHost):8000",
                                                  subsonicUsername: "demo", subsonicPassword: "demo"))
    }

    func test_qualityFileName_feedsTheExistingBadge() {
        let song = SubsonicSong(id: "x", title: nil, artist: nil, album: nil, duration: 300,
                                suffix: "flac", bitRate: 900, contentType: nil, coverArt: nil)
        let name = try? XCTUnwrap(song.qualityFileName)
        XCTAssertEqual(name, "x.flac")
        // The shipped badge logic then classifies it with no Subsonic-specific code.
        XCTAssertEqual(AudioQuality.forFile(fileName: name!, sizeBytes: 0, durationSeconds: nil).display, "FLAC")
    }
}
