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

    /// Authoritative track length (seconds) supplied by the backend for the
    /// current item, or nil. Used to override the container duration when a
    /// YouTube DASH stream reports 2x its real length (song + equal silence).
    private var knownDuration: TimeInterval?

    /// Real-time EQ tap attached to the current item's audio (streamed EQ).
    /// nil until EQ is first enabled for an item.
    private var eqTap: AudioEQTap?

    init(player: PlayerManager) {
        self.player = player
    }

    deinit {
        statusObserver?.invalidate()
        rateObserver?.invalidate()
    }

    // MARK: - Playback

    func play(url: URL, knownDuration: TimeInterval? = nil) {
        guard let player else { return }
        log.notice("playNative url=\(url.lastPathComponent, privacy: .public) replacingExistingPlayer=\(self.avPlayer != nil, privacy: .public)")
        self.knownDuration = knownDuration
        player.currentStreamURL = url
        player.nowPlaying.configureRemoteCommands()

        // NOTE: the status observer is block-based (`observe(\.status)` below,
        // stored in `statusObserver` and invalidated here) — it is NOT a manual
        // KVO `addObserver(player, forKeyPath:)`. A leftover
        // `removeObserver(player, forKeyPath: .status)` used to live here and
        // would trap ("not registered as an observer") whenever a previous
        // AVPlayerItem existed — dormant until instant-start made EQ-on playback
        // create AVPlayer items. Removed.
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
                    // Let PlayerManager decide whether to re-resolve+retry (for a
                    // streamed track) or surface the error.
                    player.handleAVPlayerItemFailure(item.error)
                } else if item.status == .readyToPlay {
                    let itemDuration = item.duration
                    if itemDuration.isNumeric && !itemDuration.isIndefinite {
                        var resolved = self.correctedDuration(for: item)
                        // The track-vs-container heuristic misses the case where
                        // BOTH are doubled (DASH song + equal silence). When the
                        // backend gave us the true length and the container is
                        // materially longer, trust the backend and cap there.
                        if let known = self.knownDuration, known > 0 {
                            let itemSec = CMTimeGetSeconds(itemDuration)
                            if itemSec > known * 1.1 {
                                resolved = CMTime(seconds: known, preferredTimescale: 600)
                            }
                        }
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

        // Fresh item → fresh tap. Attach now if EQ is already on.
        eqTap = nil
        if player.eq.isEnabled {
            attachEQ(bands: player.eq.bands)
        }

        if let seek = pendingSeek {
            avPlayer?.seek(to: CMTime(seconds: seek, preferredTimescale: 600))
            pendingSeek = nil
        }
        avPlayer?.play()
    }

    // MARK: - EQ (real-time tap)

    /// Enables or disables EQ on the current streamed item. The first enable
    /// attaches the tap (async track load); thereafter we just toggle bypass so
    /// there's no re-attach hitch.
    func setEQEnabled(_ enabled: Bool) {
        if enabled {
            if let tap = eqTap {
                tap.setBypass(false)
            } else if let bands = player?.eq.bands {
                attachEQ(bands: bands)
            }
        } else {
            eqTap?.setBypass(true)
        }
    }

    func updateEQBands(_ bands: [Float]) {
        eqTap?.setBands(bands)
    }

    /// Builds an `AudioEQTap`, loads the current item's audio track, and sets the
    /// resulting `audioMix` — applying EQ to the live stream with no download.
    private func attachEQ(bands: [Float]) {
        guard let item = playerItem else { return }
        let tap = AudioEQTap(frequencies: PlayerManager.eqFrequencies, bands: bands, bypassed: false)
        eqTap = tap
        let asset = item.asset
        Task { @MainActor [weak self] in
            guard let self,
                  let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  self.eqTap === tap, self.playerItem === item,
                  let mix = tap.makeAudioMix(for: track) else { return }
            item.audioMix = mix
        }
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
        eqTap = nil
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
