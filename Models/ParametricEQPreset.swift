import Foundation

/// Filter shapes supported by the parametric EQ. Maps 1:1 onto AUNBandEQ
/// filter types (`kAUNBandEQFilterType_Parametric` / `_LowShelf` / `_HighShelf`).
enum ParametricFilterType: String, Codable, Equatable {
    case peak
    case lowShelf
    case highShelf
}

/// One parametric band: a filter shape at a centre/corner frequency with a
/// gain and a Q. Q is the user-facing width unit (what AutoEQ profiles use);
/// AUNBandEQ wants bandwidth in octaves — see `bandwidthOctaves`.
struct ParametricBand: Codable, Equatable {
    let type: ParametricFilterType
    let frequency: Float
    let gain: Float
    let q: Float

    /// AUNBandEQ's bandwidth parameter is in octaves; convert from Q with the
    /// standard relation BW = (2/ln 2) · asinh(1/(2Q)).
    var bandwidthOctaves: Float {
        guard q > 0 else { return 0.5 }
        return (2 / Float(M_LN2)) * asinh(1 / (2 * q))
    }
}

/// A named parametric curve — typically an imported AutoEQ correction profile
/// for a specific headphone. `preamp` is the global gain (dB) applied so
/// boosted bands don't clip.
struct ParametricEQPreset: Codable, Equatable {
    let name: String
    let preamp: Float
    let bands: [ParametricBand]
}
