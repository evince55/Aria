import Foundation

/// Parses AutoEQ "ParametricEQ.txt" profiles into a `ParametricEQPreset`.
///
/// The AutoEQ project (autoeq.app / jaakkopasanen/AutoEq) publishes measured
/// correction curves per headphone in a fixed text format:
///
///     Preamp: -6.4 dB
///     Filter 1: ON PK Fc 105 Hz Gain -4.9 dB Q 0.70
///     Filter 2: ON LSC Fc 105 Hz Gain 1.0 dB Q 0.70
///
/// Filter types: PK (peaking), LS/LSC (low shelf), HS/HSC (high shelf).
/// Lines that don't match (comments, blanks, "OFF" filters) are skipped.
enum AutoEQParser {
    enum ParseError: LocalizedError, Equatable {
        case noFilters
        var errorDescription: String? {
            switch self {
            case .noFilters:
                return "No EQ filters found. Export the “ParametricEQ.txt” variant of the AutoEQ profile and try again."
            }
        }
    }

    private static let preampPattern = try! NSRegularExpression(
        pattern: #"^\s*Preamp:\s*(-?\d+(?:\.\d+)?)\s*dB"#,
        options: [.caseInsensitive])

    // "Filter 1: ON PK Fc 105 Hz Gain -4.9 dB Q 0.70" — Q is optional (some
    // exports omit it on shelves; 0.7 is AutoEQ's default shelf Q).
    private static let filterPattern = try! NSRegularExpression(
        pattern: #"^\s*Filter\s*\d+:\s*ON\s+(PK|PEQ|LSC?|HSC?)\s+Fc\s+(\d+(?:\.\d+)?)\s*Hz\s+Gain\s+(-?\d+(?:\.\d+)?)\s*dB(?:\s+Q\s+(\d+(?:\.\d+)?))?"#,
        options: [.caseInsensitive])

    static func parse(_ text: String, name: String) throws -> ParametricEQPreset {
        var preamp: Float = 0
        var bands: [ParametricBand] = []

        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)

            if let m = preampPattern.firstMatch(in: line, range: range),
               let value = Float(line[Range(m.range(at: 1), in: line)!]) {
                preamp = value
                continue
            }

            guard let m = filterPattern.firstMatch(in: line, range: range),
                  let fc = Float(line[Range(m.range(at: 2), in: line)!]),
                  let gain = Float(line[Range(m.range(at: 3), in: line)!]) else { continue }

            let typeToken = line[Range(m.range(at: 1), in: line)!].uppercased()
            let q: Float
            if m.range(at: 4).location != NSNotFound,
               let parsed = Float(line[Range(m.range(at: 4), in: line)!]) {
                q = parsed
            } else {
                q = 0.7
            }

            let type: ParametricFilterType
            switch typeToken {
            case "LS", "LSC": type = .lowShelf
            case "HS", "HSC": type = .highShelf
            default: type = .peak  // PK / PEQ
            }
            bands.append(ParametricBand(type: type, frequency: fc, gain: gain, q: q))
        }

        guard !bands.isEmpty else { throw ParseError.noFilters }
        return ParametricEQPreset(name: name, preamp: preamp, bands: bands)
    }
}
