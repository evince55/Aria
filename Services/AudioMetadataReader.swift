import Foundation
import AVFoundation
import AudioToolbox

enum AudioMetadataReader {
    static func readAll(at url: URL) async -> (AudioCodecInfo?, AudioQuality?) {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { return (nil, nil) }
            let descriptions: [CMFormatDescription]
            do {
                descriptions = try await track.load(.formatDescriptions)
            } catch {
                return (nil, nil)
            }
            guard let desc = descriptions.first else { return (nil, nil) }

            let format = parseFormat(from: desc, fileExtension: url.pathExtension.lowercased())
            let quality = parseQuality(from: desc, track: track, format: format)
            return (format, quality)
        } catch {
            return (nil, nil)
        }
    }

    private static func parseFormat(from desc: CMFormatDescription, fileExtension: String) -> AudioCodecInfo? {
        let subtype = CMFormatDescriptionGetMediaSubType(desc)
        switch subtype {
        case kAudioFormatFLAC:
            return AudioCodecInfo(codec: "FLAC", containerExtension: fileExtension, lossless: true)
        case kAudioFormatMPEGLayer3:
            return AudioCodecInfo(codec: "MP3", containerExtension: fileExtension, lossless: false)
        case kAudioFormatMPEG4AAC:
            return AudioCodecInfo(codec: "AAC", containerExtension: fileExtension, lossless: false)
        case kAudioFormatAppleLossless:
            return AudioCodecInfo(codec: "ALAC", containerExtension: fileExtension, lossless: true)
        case kAudioFormatLinearPCM:
            return AudioCodecInfo(codec: "PCM", containerExtension: fileExtension, lossless: true)
        default:
            return AudioCodecInfo(codec: fourCC(subtype), containerExtension: fileExtension, lossless: false)
        }
    }

    private static func parseQuality(
        from desc: CMFormatDescription,
        track: AVAssetTrack,
        format: AudioCodecInfo?
    ) -> AudioQuality? {
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let sampleRate = Int(asbd.mSampleRate.rounded())
        let bitDepth = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
        let bitrateKbps: Int?
        if let format, !format.lossless {
            let estimated = track.estimatedDataRate
            if estimated > 0 {
                bitrateKbps = Int((estimated / 1000.0).rounded())
            } else {
                bitrateKbps = nil
            }
        } else {
            bitrateKbps = nil
        }
        return AudioQuality(bitDepth: bitDepth, sampleRateHz: sampleRate, bitrateKbps: bitrateKbps)
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "UNKNOWN"
    }
}
