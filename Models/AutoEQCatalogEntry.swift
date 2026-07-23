import Foundation

/// One row of the bundled AutoEq catalog index (`Resources/autoeq-index.json`,
/// generated from the AutoEq project's results INDEX). Keys are minified in the
/// JSON to keep the 8,850-entry index small.
struct AutoEQCatalogEntry: Codable, Identifiable, Hashable {
    /// Headphone display name, e.g. "Sennheiser HD 650".
    let n: String
    /// URL-encoded directory path under `results/` in the AutoEq repo,
    /// e.g. "oratory1990/over-ear/Sennheiser%20HD%20650". Unique per entry.
    let p: String
    /// Measurement source, e.g. "oratory1990", "crinacle".
    let s: String
    /// Form-factor code: "o" over-ear, "i" in-ear, "e" earbud, "x" other.
    let c: String

    var id: String { p }
    var name: String { n }
    var source: String { s }

    enum FormFactor: String, CaseIterable {
        case overEar = "o"
        case inEar = "i"
        case earbud = "e"
        case other = "x"

        var label: String {
            switch self {
            case .overEar: return "Over-ear"
            case .inEar: return "In-ear"
            case .earbud: return "Earbuds"
            case .other: return "Other"
            }
        }
    }

    var formFactor: FormFactor { FormFactor(rawValue: c) ?? .other }

    /// Raw-content URL of this entry's `ParametricEQ.txt`. The path segments in
    /// `p` are pre-encoded by the index generator (spaces as %20; parentheses
    /// are valid URL characters and stay literal), and the profile file inside
    /// each result directory is named "<dir name> ParametricEQ.txt".
    var profileURL: URL? {
        guard let dirName = p.split(separator: "/").last else { return nil }
        return URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/\(p)/\(dirName)%20ParametricEQ.txt")
    }
}
