import XCTest
@testable import Aria___Music_Browser

final class AutoEQParserTests: XCTestCase {

    private let sample = """
    Preamp: -6.4 dB
    Filter 1: ON PK Fc 105 Hz Gain -4.9 dB Q 0.70
    Filter 2: ON LSC Fc 105 Hz Gain 1.0 dB Q 0.70
    Filter 3: ON HSC Fc 10000 Hz Gain -3.2 dB Q 0.70
    """

    func test_parsesPreampAndBands() throws {
        let preset = try AutoEQParser.parse(sample, name: "HD 650")
        XCTAssertEqual(preset.name, "HD 650")
        XCTAssertEqual(preset.preamp, -6.4, accuracy: 0.001)
        XCTAssertEqual(preset.bands.count, 3)

        XCTAssertEqual(preset.bands[0].type, .peak)
        XCTAssertEqual(preset.bands[0].frequency, 105)
        XCTAssertEqual(preset.bands[0].gain, -4.9, accuracy: 0.001)
        XCTAssertEqual(preset.bands[0].q, 0.7, accuracy: 0.001)

        XCTAssertEqual(preset.bands[1].type, .lowShelf)
        XCTAssertEqual(preset.bands[2].type, .highShelf)
    }

    func test_skipsOffFiltersAndJunkLines() throws {
        let text = """
        # comment line
        Preamp: -2.0 dB

        Filter 1: OFF PK Fc 100 Hz Gain 3.0 dB Q 1.00
        Filter 2: ON PK Fc 200 Hz Gain 2.0 dB Q 1.41
        totally unrelated line
        """
        let preset = try AutoEQParser.parse(text, name: "x")
        XCTAssertEqual(preset.bands.count, 1, "OFF filters and junk must be skipped")
        XCTAssertEqual(preset.bands[0].frequency, 200)
    }

    func test_missingQ_defaultsToPointSeven() throws {
        let text = "Filter 1: ON LS Fc 80 Hz Gain 2.5 dB"
        let preset = try AutoEQParser.parse(text, name: "x")
        XCTAssertEqual(preset.bands[0].q, 0.7, accuracy: 0.001)
        XCTAssertEqual(preset.bands[0].type, .lowShelf)
    }

    func test_decimalFrequency_parses() throws {
        let text = "Filter 1: ON PK Fc 1250.5 Hz Gain -1.2 dB Q 2.00"
        let preset = try AutoEQParser.parse(text, name: "x")
        XCTAssertEqual(preset.bands[0].frequency, 1250.5, accuracy: 0.001)
    }

    func test_noPreampLine_defaultsToZero() throws {
        let text = "Filter 1: ON PK Fc 100 Hz Gain 1.0 dB Q 1.00"
        let preset = try AutoEQParser.parse(text, name: "x")
        XCTAssertEqual(preset.preamp, 0)
    }

    func test_emptyOrGarbageInput_throwsNoFilters() {
        XCTAssertThrowsError(try AutoEQParser.parse("", name: "x")) { error in
            XCTAssertEqual(error as? AutoEQParser.ParseError, .noFilters)
        }
        XCTAssertThrowsError(try AutoEQParser.parse("hello world", name: "x"))
    }
}
