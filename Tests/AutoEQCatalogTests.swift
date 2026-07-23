import XCTest
@testable import Aria___Music_Browser

final class AutoEQCatalogTests: XCTestCase {

    private func entry(_ n: String, p: String, s: String = "oratory1990", c: String = "o") -> AutoEQCatalogEntry {
        AutoEQCatalogEntry(n: n, p: p, s: s, c: c)
    }

    // MARK: - Bundled index

    func test_bundledIndex_decodesAndIsSubstantial() throws {
        let entries = try AutoEQCatalog.decodeBundledIndex()
        XCTAssertGreaterThan(entries.count, 5000, "the shipped catalog should be the full AutoEq index")

        let hd650 = entries.filter { $0.name == "Sennheiser HD 650" }
        XCTAssertFalse(hd650.isEmpty, "a staple headphone must be present")
        XCTAssertEqual(hd650.first?.source, "oratory1990",
                       "index is pre-sorted with the most trusted source first")
    }

    // MARK: - Profile URL

    func test_profileURL_standardEntry() {
        let e = entry("Sennheiser HD 650", p: "oratory1990/over-ear/Sennheiser%20HD%20650")
        XCTAssertEqual(
            e.profileURL?.absoluteString,
            "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20650/Sennheiser%20HD%20650%20ParametricEQ.txt"
        )
    }

    func test_profileURL_parenthesesInName_buildsValidURL() {
        // AutoEq paths encode spaces but leave parentheses literal — both are
        // valid URL characters and must survive URL construction.
        let e = entry("1MORE Aero (ANC Off)",
                      p: "HypetheSonics/GRAS%20RA0045%20in-ear/1MORE%20Aero%20(ANC%20Off)", c: "i")
        let url = e.profileURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.hasSuffix("/1MORE%20Aero%20(ANC%20Off)%20ParametricEQ.txt"))
    }

    // MARK: - Filtering

    func test_filter_tokensMatchAllCaseInsensitive() {
        let entries = [
            entry("Sennheiser HD 650", p: "a"),
            entry("Sennheiser HD 600", p: "b"),
            entry("Sony WH-1000XM5", p: "c"),
        ]
        let hits = AutoEQCatalog.filter(entries, query: "hd 650", formFactor: nil)
        XCTAssertEqual(hits.map(\.p), ["a"])
    }

    func test_filter_byFormFactor() {
        let entries = [
            entry("A", p: "a", c: "o"),
            entry("B", p: "b", c: "i"),
        ]
        XCTAssertEqual(AutoEQCatalog.filter(entries, query: "", formFactor: .inEar).map(\.p), ["b"])
        XCTAssertEqual(AutoEQCatalog.filter(entries, query: "", formFactor: nil).count, 2)
    }

    func test_filter_matchesSourceToo() {
        let entries = [
            entry("Sennheiser HD 650", p: "a", s: "oratory1990"),
            entry("Sennheiser HD 650", p: "b", s: "crinacle"),
        ]
        XCTAssertEqual(AutoEQCatalog.filter(entries, query: "650 crinacle", formFactor: nil).map(\.p), ["b"])
    }

    // MARK: - Fetch

    private final class StubSession: URLSessionProtocol, @unchecked Sendable {
        var result: (Data, URLResponse)?
        private(set) var requestedURL: URL?

        func dataTask(with url: URL,
                      completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTaskProtocol {
            fatalError("unused in these tests")
        }

        func data(from url: URL) async throws -> (Data, URLResponse) {
            requestedURL = url
            guard let result else { throw URLError(.notConnectedToInternet) }
            return result
        }
    }

    private func httpResponse(_ status: Int, url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    func test_fetchProfile_parsesAndNamesAfterEntry() async throws {
        let e = entry("Sennheiser HD 650", p: "oratory1990/over-ear/Sennheiser%20HD%20650")
        let stub = StubSession()
        let text = """
        Preamp: -6.1 dB
        Filter 1: ON LSC Fc 105 Hz Gain 6.4 dB Q 0.70
        Filter 2: ON PK Fc 8800 Hz Gain 5.1 dB Q 1.42
        """
        stub.result = (Data(text.utf8), httpResponse(200, url: e.profileURL!))

        let preset = try await AutoEQCatalog(urlSession: stub).fetchProfile(for: e)
        XCTAssertEqual(preset.name, "Sennheiser HD 650")
        XCTAssertEqual(preset.preamp, -6.1, accuracy: 0.001)
        XCTAssertEqual(preset.bands.count, 2)
        XCTAssertEqual(stub.requestedURL, e.profileURL)
    }

    func test_fetchProfile_non200_throwsBadStatus() async {
        let e = entry("X", p: "s/over-ear/X")
        let stub = StubSession()
        stub.result = (Data(), httpResponse(404, url: e.profileURL!))

        do {
            _ = try await AutoEQCatalog(urlSession: stub).fetchProfile(for: e)
            XCTFail("expected badStatus")
        } catch let AutoEQCatalog.CatalogError.badStatus(code) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
