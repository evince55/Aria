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
    /// Single source of truth for play / pause / rebuffer. `timeControlStatus`
    /// distinguishes a user pause (`.paused`) from an involuntary stall
    /// (`.waitingToPlayAtSpecifiedRate`), which inferring from `rate == 0` could
    /// not — a stall used to masquerade as a pause and starve the watchdog.
    private var timeControlObserver: NSKeyValueObservation?
    /// Fires if the buffer stays empty past the grace period, asking
    /// `PlayerManager` to re-resolve + resume. Re-armed each time the buffer
    /// empties, cancelled when playback recovers or the item is torn down.
    private var stallWatchdog: Task<Void, Never>?
    private let stallGrace: TimeInterval = 8
    /// Last whole-second pushed to Now Playing, so the 4 Hz time observer only
    /// updates the lock screen ~1×/sec instead of every tick.
    private var lastNowPlayingSecond = -1
    private var endObserverToken: NSObjectProtocol?

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
        timeControlObserver?.invalidate()
        stallWatchdog?.cancel()
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
        timeControlObserver?.invalidate()
        cancelStallWatchdog()
        lastNowPlayingSecond = -1
        avPlayer?.pause()
        removeEndObserver()

        let asset = AVURLAsset(url: url)
        playerItem = AVPlayerItem(asset: asset)
        playerItem?.preferredForwardBufferDuration = 10
        // Preserve pitch when playing at a non-1x speed (otherwise fast/slow
        // playback sounds chipmunk/detuned).
        playerItem?.audioTimePitchAlgorithm = .timeDomain
        avPlayer = AVPlayer(playerItem: playerItem)
        // Let AVPlayer hold playback until it has enough buffer to avoid
        // immediate stalls on a slow start, rather than starting and dying.
        avPlayer?.automaticallyWaitsToMinimizeStalling = true
        // play() begins at defaultRate (iOS 16+), so the chosen speed carries
        // across tracks without touching every play() call site.
        avPlayer?.defaultRate = playbackRate

        timeControlObserver = avPlayer?.observe(\.timeControlStatus, options: [.new]) { [weak self] avPlayer, _ in
            let status = avPlayer.timeControlStatus
            DispatchQueue.main.async {
                guard let self, let player = self.player else { return }
                switch status {
                case .playing:
                    player.isPlaying = true
                    player.playbackState = .playing
                    if player.isRebuffering { player.isRebuffering = false }
                    self.cancelStallWatchdog()
                    player.notePlaybackRecovered()
                case .paused:
                    player.isPlaying = false
                    // A genuine pause. Don't clobber a load/end transition the
                    // status/end observers own.
                    if player.playbackState != .loading, player.playbackState != .ended {
                        player.playbackState = .paused
                    }
                    if player.isRebuffering { player.isRebuffering = false }
                    self.cancelStallWatchdog()
                case .waitingToPlayAtSpecifiedRate:
                    // Wants to play but is buffering/stalled — NOT a user pause.
                    // Only treat as a rebuffer once playback has actually begun;
                    // during the initial cold load playbackState is .loading and
                    // PlayerManager already shows a spinner.
                    if player.playbackState == .playing {
                        player.isRebuffering = true
                        self.armStallWatchdog()
                    }
                @unknown default:
                    break
                }
                player.nowPlaying.updateNowPlaying()
            }
        }

        statusObserver = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, let player = self.player else { return }
                // Ignore a stale item's late status callback: play(url:) may have
                // swapped in a new item between this KVO firing and the main-queue
                // hop, and we must not apply item-A's failure/end-time to item B.
                guard self.playerItem === item else { return }
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
                            item.forwardPlaybackEndTime = resolved
                        }
                        player.nowPlaying.updateNowPlaying()
                    }
                }
            }
        }

        // (Rebuffer detection + recovery are driven by the timeControlStatus
        // observer above — .waitingToPlayAtSpecifiedRate arms the watchdog and
        // shows "Buffering…", .playing clears it — so the separate
        // isPlaybackBufferEmpty / isPlaybackLikelyToKeepUp observers are gone.)

        // 4 Hz position updates → smooth scrubber, but only the clock's
        // observers (the player view) re-render. Now Playing is throttled to
        // ~1 Hz so the lock screen isn't spammed.
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = avPlayer?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let player = self.player else { return }
            player.clock.currentTime = time.seconds
            let sec = Int(time.seconds)
            if sec != self.lastNowPlayingSecond {
                self.lastNowPlayingSecond = sec
                player.nowPlaying.updateNowPlaying()
            }
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

    /// Selected playback speed, applied to the current and all future items.
    private(set) var playbackRate: Float = 1.0

    /// Change the playback speed. Updates `defaultRate` so `play()` resumes at
    /// the chosen speed, and applies it live if currently playing. When paused,
    /// only the default is updated so we don't inadvertently start playback.
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        avPlayer?.defaultRate = rate
        if let player = avPlayer, player.rate > 0 {
            player.rate = rate
        }
    }

    // MARK: - End-of-item observer

    private func addEndObserver(for item: AVPlayerItem?) {
        guard let item, let player else { return }
        removeEndObserver()
        // Block-based with queue: .main so the handler — which mutates
        // PlayerManager's @Published queue/track/state on every track end — runs
        // on the main actor. The selector overload used here had no queue, so it
        // fired on AVFoundation's posting thread (a SwiftUI-from-background
        // violation and a data race against user queue edits).
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak player] _ in
            player?.playerItemDidFinish()
        }
    }

    private func removeEndObserver() {
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
    }

    // MARK: - Teardown

    func stop() {
        log.notice("stopAVPlayer player=\(self.avPlayer != nil, privacy: .public) item=\(self.playerItem != nil, privacy: .public) timeObserver=\(self.timeObserver != nil, privacy: .public)")
        avPlayer?.pause()
        removeEndObserver()
        if let obs = timeObserver { avPlayer?.removeTimeObserver(obs) }
        statusObserver?.invalidate()
        timeControlObserver?.invalidate()
        cancelStallWatchdog()
        avPlayer = nil
        playerItem = nil
        timeObserver = nil
        timeControlObserver = nil
        lastNowPlayingSecond = -1
        eqTap = nil
        player?.isRebuffering = false
    }

    // MARK: - Stall watchdog

    /// Arms (or re-arms) the grace timer. If the item is still starved when it
    /// fires, ask `PlayerManager` to re-resolve and resume.
    private func armStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.stallGrace ?? 8) * 1_000_000_000))
            guard let self, !Task.isCancelled,
                  let player = self.player, let item = self.playerItem else { return }
            if item.isPlaybackBufferEmpty && !item.isPlaybackLikelyToKeepUp {
                player.handleStall()
            }
        }
    }

    private func cancelStallWatchdog() {
        stallWatchdog?.cancel()
        stallWatchdog = nil
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
