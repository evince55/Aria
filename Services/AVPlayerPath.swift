import Foundation
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "AVPlayerPath")

/// Owns the no-EQ playback path: `AVPlayer` + `AVPlayerItem` + KVO observers
/// + item-scoped end-of-track notification. All cross-component state lives
/// on `PlayerManager` and is mutated through the weak `player` reference.
@MainActor
final class AVPlayerPath {
    private weak var player: PlayerManager?
    private(set) var avPlayer: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private weak var endObserverItem: AVPlayerItem?

    /// Stored seek target consumed on next `play`. PlayerManager writes to
    /// this before calling `play(url:)` so a switch-back from engine path
    /// resumes at the right time.
    var pendingSeek: TimeInterval?

    init(player: PlayerManager) {
        self.player = player
    }

    deinit {
        statusObserver?.invalidate()
        rateObserver?.invalidate()
    }

    // MARK: - Playback

    func play(url: URL) {
        guard let player else { return }
        log.notice("playNative url=\(url.lastPathComponent, privacy: .public) replacingExistingPlayer=\(self.avPlayer != nil, privacy: .public) usingEngine=\(player.isUsingEngine, privacy: .public)")
        player.currentStreamURL = url
        player.nowPlaying.configureRemoteCommands()
        player.stopEngine()

        playerItem?.removeObserver(player, forKeyPath: #keyPath(AVPlayerItem.status))
        if let obs = timeObserver { avPlayer?.removeTimeObserver(obs) }
        statusObserver?.invalidate()
        rateObserver?.invalidate()
        avPlayer?.pause()
        removeEndObserver()

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        playerItem?.preferredForwardBufferDuration = 10
        avPlayer = AVPlayer(playerItem: playerItem)

        rateObserver = avPlayer?.observe(\.rate, options: [.new]) { [weak self] avPlayer, _ in
            log.notice("rate changed -> \(avPlayer.rate, privacy: .public)")
            DispatchQueue.main.async {
                guard let self, let player = self.player else { return }
                player.isPlaying = avPlayer.rate > 0
                player.playbackState = avPlayer.rate > 0 ? .playing : .paused
                player.nowPlaying.updateNowPlaying()
            }
        }

        statusObserver = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, let player = self.player else { return }
                if item.status == .failed {
                    log.error("AVPlayerItem error: \(item.error?.localizedDescription ?? "?", privacy: .public)")
                    player.isPlaying = false
                    player.playbackState = .idle
                    player.currentStreamURL = nil
                } else if item.status == .readyToPlay {
                    let itemDuration = item.duration
                    if itemDuration.isNumeric && !itemDuration.isIndefinite {
                        let resolved = self.correctedDuration(for: item) ?? itemDuration
                        player.duration = CMTimeGetSeconds(resolved)
                        if CMTimeCompare(resolved, itemDuration) != 0 {
                            self.playerItem?.forwardPlaybackEndTime = resolved
                        }
                        player.nowPlaying.updateNowPlaying()
                    }
                }
            }
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 600)
        timeObserver = avPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            log.debug("time=\(time.seconds, privacy: .public) duration=\(self?.player?.duration ?? 0, privacy: .public) rate=\(self?.avPlayer?.rate ?? -1, privacy: .public)")
            self?.player?.currentTime = time.seconds
            self?.player?.nowPlaying.updateNowPlaying()
        }

        addEndObserver(for: playerItem)

        if let seek = pendingSeek {
            avPlayer?.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
            pendingSeek = nil
        }
        avPlayer?.play()
        player.isUsingEngine = false
    }

    /// Plays the current item from the beginning (used by `repeatMode == .one`).
    func replayCurrent() {
        avPlayer?.seek(to: .zero)
        avPlayer?.play()
    }

    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        avPlayer?.seek(to: cmTime)
    }

    func play() {
        avPlayer?.play()
    }

    func pause() {
        avPlayer?.pause()
    }

    // MARK: - End-of-item observer

    private func addEndObserver(for item: AVPlayerItem?) {
        guard let item, let player else { return }
        endObserverItem = item
        NotificationCenter.default.addObserver(
            player, selector: #selector(PlayerManager.playerItemDidFinish),
            name: .AVPlayerItemDidPlayToEndTime, object: item
        )
    }

    private func removeEndObserver() {
        if let item = endObserverItem, let player {
            NotificationCenter.default.removeObserver(
                player, name: .AVPlayerItemDidPlayToEndTime, object: item
            )
        }
        endObserverItem = nil
    }

    // MARK: - Teardown

    func stop() {
        log.notice("stopAVPlayer player=\(self.avPlayer != nil, privacy: .public) item=\(self.playerItem != nil, privacy: .public) timeObserver=\(self.timeObserver != nil, privacy: .public)")
        avPlayer?.pause()
        removeEndObserver()
        if let obs = timeObserver { avPlayer?.removeTimeObserver(obs) }
        statusObserver?.invalidate()
        rateObserver?.invalidate()
        avPlayer = nil
        playerItem = nil
        timeObserver = nil
    }

    // MARK: - Duration fix-up

    /// Some YouTube DASH audio renditions report a duration that's roughly
    /// 2× the actual track length (duplicate audio segments). The audio
    /// track's `timeRange` is authoritative, so prefer it when the item
    /// duration is suspiciously larger.
    private func correctedDuration(for item: AVPlayerItem) -> CMTime {
        let itemDur = item.duration
        guard let trackDur = item.asset.tracks(withMediaType: .audio).first?.timeRange.duration,
              trackDur.isNumeric, !trackDur.isIndefinite,
              itemDur.isNumeric, !itemDur.isIndefinite else {
            return itemDur
        }
        let itemSec = CMTimeGetSeconds(itemDur)
        let trackSec = CMTimeGetSeconds(trackDur)
        guard itemSec > 0, trackSec > 0, itemSec / trackSec > 1.1 else {
            return itemDur
        }
        return trackDur
    }
}
