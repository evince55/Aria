import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "NowPlayingService")

/// Owns the Now Playing / lock-screen / control-center integration, and
/// activates the `AVAudioSession` on demand. Stateless except for the
/// one-time remote command registration flag.
@MainActor
final class NowPlayingService {
    private let urlSession: URLSessionProtocol
    private weak var player: PlayerManager?
    private var remoteCommandsConfigured = false
    private var artworkTask: Task<Void, Never>?

    init(player: PlayerManager, urlSession: URLSessionProtocol) {
        self.player = player
        self.urlSession = urlSession
    }

    deinit {
        artworkTask?.cancel()
    }

    // MARK: - Public API

    func updateNowPlaying() {
        guard let player else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        guard let track = player.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        if let art = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func loadArtwork(for track: Track) {
        guard let url = track.thumbnailURL else { return }
        loadArtwork(from: url)
    }

    /// Loads artwork from any URL — both remote (https) and local
    /// (file://). For local files, reads the bytes directly instead
    /// of going through URLSession.
    func loadArtwork(from url: URL) {
        artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = (try? await self.urlSession.data(from: url))?.0
            }
            guard let data, let img = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: img.size) { requestedSize in
                self.downscaled(img, to: requestedSize)
            }
            await MainActor.run {
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    func configureRemoteCommands() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player?.togglePlayPause(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player?.togglePlayPause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.player?.togglePlayPause(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.player?.seek(to: e.positionTime)
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.player?.nextTrack(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.player?.previousTrack(); return .success }
    }

    func activateAudioSession() {
        Task(priority: .userInitiated) {
            let s = AVAudioSession.sharedInstance()
            do {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try s.setActive(true)
            } catch {
                log.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Internal

    private func downscaled(_ image: UIImage, to size: CGSize) -> UIImage {
        guard size.width > 0, size.height > 0 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
