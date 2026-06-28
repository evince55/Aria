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

    /// Wired by `PlayerManager.configureFavorites(_:)` so the lock-screen Like
    /// command can toggle the current track's favorite state.
    weak var favorites: FavoritesManager?

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
        refreshCommandState()
    }

    /// Keeps the next/prev/like remote commands in sync with queue, history,
    /// and favorite state. Cheap; called on every Now Playing update.
    func refreshCommandState() {
        guard remoteCommandsConfigured, let player else { return }
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = player.hasNext
        c.previousTrackCommand.isEnabled = player.hasPrevious
        if let track = player.currentTrack {
            c.likeCommand.isActive = favorites?.isFavorite(track) ?? false
        }
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

        // Like / Favorite — toggles the current track in FavoritesManager.
        let like = c.likeCommand
        like.isEnabled = true
        like.localizedTitle = "Favorite"
        like.localizedShortTitle = "Favorite"
        like.addTarget { [weak self] _ in
            guard let self,
                  let track = self.player?.currentTrack,
                  let favorites = self.favorites else { return .commandFailed }
            favorites.toggle(track)
            self.refreshCommandState()
            return .success
        }

        // Initial availability reflects the current state.
        refreshCommandState()
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
