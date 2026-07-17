import Foundation
import AVFoundation

enum AudioFormat: String, Equatable {
    case mp3, aac, alac, flac, aiff, wav
    case ogg, opus, wma, ape
    case unknown

    var isSupported: Bool {
        switch self {
        case .mp3, .aac, .alac, .flac, .aiff, .wav: return true
        case .ogg, .opus, .wma, .ape, .unknown: return false
        }
    }

    /// Whether the format preserves the original signal bit-for-bit. Drives the
    /// `AudioQuality` badge's lossless/lossy split.
    var isLossless: Bool {
        switch self {
        case .flac, .alac, .wav, .aiff, .ape: return true
        case .mp3, .aac, .ogg, .opus, .wma, .unknown: return false
        }
    }

    var displayName: String {
        switch self {
        case .aac: return "AAC"
        case .alac: return "ALAC"
        case .aiff: return "AIFF"
        case .ape: return "APE"
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        case .ogg: return "OGG"
        case .opus: return "Opus"
        case .wav: return "WAV"
        case .wma: return "WMA"
        case .unknown: return "Unknown"
        }
    }

    static func detect(url: URL) -> AudioFormat {
        detect(extension: url.pathExtension.lowercased())
    }

    static func detect(extension ext: String) -> AudioFormat {
        switch ext {
        case "mp3", "mpeg": return .mp3
        case "aac", "m4a": return .aac
        case "alac": return .alac
        case "flac": return .flac
        case "aif", "aiff": return .aiff
        case "wav", "wave": return .wav
        case "ogg", "oga": return .ogg
        case "opus": return .opus
        case "wma": return .wma
        case "ape": return .ape
        default: return .unknown
        }
    }

    static func probe(url: URL) async -> AudioFormat {
        let fastPath = detect(url: url)
        guard fastPath == .unknown else { return fastPath }
        let asset = AVURLAsset(url: url)
        _ = try? await asset.load(.tracks)
        return .unknown
    }
}
