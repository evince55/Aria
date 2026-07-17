import Foundation

/// A compact, display-ready description of a track's audio quality, derived
/// from its file name (codec) plus optional size/duration (bitrate). Rendered
/// by `QualityBadge` in the Library rows.
///
/// The value is intentionally cheap to compute (`forFile` is a pure function),
/// so rows can build it inline without probing the file.
struct AudioQuality: Equatable, Hashable {
    /// Broad bucket used to colour/label the badge.
    enum Category: Equatable, Hashable {
        case lossless
        case lossy
        case unknown
    }

    /// Short pill text, e.g. `"FLAC"`, `"MP3 320"`, `"AAC"`, `"—"`.
    let display: String
    let category: Category

    var isLossless: Bool { category == .lossless }

    /// A computed bitrate at/above this (kbps) on an `.m4a`/AAC file means the
    /// container really holds ALAC — AAC never reaches it in practice.
    private static let ALACBitrateFloor = 700

    /// Builds a badge value from a file name and, when available, its size and
    /// duration. Lossless codecs display their format name; lossy codecs show a
    /// computed kbps tier when a positive duration is known, otherwise just the
    /// codec name. Unknown/unsupported extensions yield an `.unknown` badge.
    static func forFile(fileName: String, sizeBytes: Int64, durationSeconds: Double?) -> AudioQuality {
        let format = AudioFormat.detect(extension: (fileName as NSString).pathExtension.lowercased())

        if format == .unknown {
            return AudioQuality(display: "—", category: .unknown)
        }

        if format.isLossless {
            // FLAC/WAV/ALAC show their name; AIFF collapses to "Lossless"
            // since a bare "AIFF" reads less clearly as a quality tier.
            let name: String
            switch format {
            case .flac: name = "FLAC"
            case .wav: name = "WAV"
            case .alac: name = "ALAC"
            default: name = "Lossless"
            }
            return AudioQuality(display: name, category: .lossless)
        }

        // Lossy: prefer "CODEC kbps" when a positive duration lets us compute it.
        let codec = format.displayName
        if let duration = durationSeconds, duration > 0, sizeBytes > 0 {
            let kbps = Int((Double(sizeBytes) * 8 / duration / 1000).rounded())
            if kbps > 0 {
                // .m4a holds either AAC (lossy) or ALAC (lossless) and the
                // extension can't tell them apart. AAC tops out ~320-512 kbps,
                // so a bitrate this high means the file is really ALAC.
                if format == .aac && kbps >= ALACBitrateFloor {
                    return AudioQuality(display: "ALAC", category: .lossless)
                }
                return AudioQuality(display: "\(codec) \(kbps)", category: .lossy)
            }
        }
        return AudioQuality(display: codec, category: .lossy)
    }
}
