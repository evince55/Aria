import Foundation
import MediaPlayer
import Combine
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "PlayerManager")

final class PlayerManager: NSObject, ObservableObject {
    // MARK: - Published state

    @Published var currentTrack: Track?
    /// Resolved artwork URL for the current track — either the YouTube
    /// thumbnail (for streamed tracks) or the extracted embedded
    /// artwork file (for local imports). `nil` when no artwork is
    /// available. The view layer uses this instead of
    /// `currentTrack.thumbnailURL` so local files can show their
    /// embedded artwork without going through `Track`.
    @Published private(set) var currentArtworkURL: URL?
    @Published var isPlaying = false
    @Published var playbackState: PlaybackState = .idle
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var queue: [Track] = []
    @Published var playerError: PlayerError?
    /// When a sleep timer is armed, the wall-clock instant it will fire.
    /// `nil` when no timer is active. The view layer observes this to show a
    /// live countdown.
    @Published private(set) var sleepTimerEndDate: Date?

    /// True while the current item has drained its buffer mid-playback and is
    /// re-buffering. Drives the player's "Buffering…" affordance. Lives on
    /// `PlayerManager` (not the clock) because it's a coarse, low-frequency
    /// state, unlike the per-tick position.
    @Published var isRebuffering = false

    /// High-frequency playback position + track length, split into its own
    /// observable so the 4 Hz time observer re-renders only the scrubber, not
    /// every view that observes `PlayerManager`. `currentTime` / `duration`
    /// below forward to it so existing call sites are unchanged.
    let clock = PlaybackClock()

    /// Forwarders to `clock`. Plain computed properties (NOT `@Published`), so
    /// writing the position every tick does not fire `PlayerManager`'s
    /// `objectWillChange` — only `clock`'s observers update.
    var currentTime: TimeInterval {
        get { clock.currentTime }
        set { clock.currentTime = newValue }
    }
    var duration: TimeInterval {
        get { clock.duration }
        set { clock.duration = newValue }
    }

    let eq: EQController

    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
    }

    enum RepeatMode: Int, CaseIterable {
        case off, one, all
    }

    enum PlayerError: Error, Equatable {
        case trackMissing(trackID: String)
        case streamFailed(String)
    }

    // MARK: - Configuration

    static let backendURL: String = {
        if let url = Bundle.main.object(forInfoDictionaryKey: "ARIA_BACKEND_URL") as? String {
            return url
        }
        let host = Bundle.main.object(forInfoDictionaryKey: "ARIA_HOMELAB_HOST") as? String ?? "192.0.2.1"
        #if DEBUG
        // Homelab over Tailscale — WireGuard already encrypts the tunnel,
        // so plain HTTP is fine for local dev. HTTPS was attempted but
        // requires a system-trusted CA on the device, which is impractical
        // to install on a real iPhone for a dev-only backend. The host
        // resolves from `ARIA_HOMELAB_HOST` in Info.plist; the public
        // source ships the RFC 5737 TEST-NET-1 placeholder so the IP
        // doesn't leak. See the README's "Dev homelab setup" section.
        return "http://\(host):8000"
        #else
        return "https://aria-backend-px9s.onrender.com"
        #endif
    }()

    static let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Subsystems

    private var urlSession: URLSessionProtocol!
    /// Wraps the `StreamResolver` with a one-deep look-ahead cache. Normal
    /// playback resolves through this so a prefetched next track starts with no
    /// network round-trip.
    private var prefetcher: StreamPrefetcher!
    private var radioService: RadioServing!

    var nowPlaying: NowPlayingService!
    private var avPlayerPath: AVPlayerPath!

    // MARK: - Radio (endless similar-song autoplay)

    /// Whether the current queue is a radio (auto-refilling) queue. Cleared
    /// when the user explicitly seeds the queue another way (playSlice).
    private var radioActive = false
    /// IDs already queued/played in this radio session, to avoid repeats on
    /// refill.
    private var radioSeen = Set<String>()
    private var radioRefillTask: Task<Void, Never>?
    /// Refill the radio queue once it drops to this many upcoming tracks.
    private let radioRefillThreshold = 4

    // MARK: - Playback control

    var seekTarget: TimeInterval?
    var currentStreamURL: URL?
    var playGeneration = 0

    /// Tracks played before the current one, oldest first. Powers real
    /// Previous-track navigation. Capped to avoid unbounded growth.
    private var playHistory: [Track] = []
    private let maxPlayHistory = 200
    /// Don't pop history when the user is well into a track — Previous then
    /// restarts the current track, matching standard player behaviour.
    private let previousRestartThreshold: TimeInterval = 3

    /// Snapshot of the upcoming queue in its original (unshuffled) order,
    /// kept only while `isShuffled` is on so the toggle is reversible.
    private var unshuffledQueue: [Track]?

    /// Pending sleep-timer task; cancelled when the timer is re-armed or
    /// turned off.
    private var sleepTimerTask: Task<Void, Never>?

    // MARK: - Init / deinit

    override init() {
        let session = Self.defaultURLSession()
        self.urlSession = session
        self.prefetcher = StreamPrefetcher(resolver: StreamResolver(session: session))
        self.radioService = RadioService(session: session)
        self.eq = EQController()
        super.init()
        nowPlaying = NowPlayingService(player: self, urlSession: session)
        avPlayerPath = AVPlayerPath(player: self)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    /// Designated initialiser for tests and alternative configurations.
    init(urlSession: URLSessionProtocol, eq: EQController = EQController()) {
        self.urlSession = urlSession
        self.prefetcher = StreamPrefetcher(resolver: StreamResolver(session: urlSession))
        self.radioService = RadioService(session: urlSession)
        self.eq = eq
        super.init()
        let session = urlSession
        nowPlaying = NowPlayingService(player: self, urlSession: session)
        avPlayerPath = AVPlayerPath(player: self)

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    private static func defaultURLSession() -> URLSessionProtocol {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.urlCache = URLCache.shared
        let session = URLSession(
            configuration: config,
            delegate: TLSPinningDelegate(),
            delegateQueue: nil
        )
        return URLSessionAdapter(session: session)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.changePlaybackPositionCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)
        c.likeCommand.removeTarget(nil)
        sleepTimerTask?.cancel()
    }

    // MARK: - Audio session notifications

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            if let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optRaw)
                if opts.contains(.shouldResume) {
                    togglePlayPause()
                }
            }
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable else { return }
        pause()
    }

    // MARK: - Playback

    /// Dev-only helper: injects a fake current track without going through
    /// the network so the full-screen player layout can be visually verified
    /// in the simulator. Triggered from `ContentView` via the
    /// `--debug-fake-track` launch argument or the `debug_fake_track`
    /// UserDefault key. Not used in Release builds.
    func loadDebugFakeTrack() {
        let track = Track(
            id: "debug-track-1",
            title: "Bohemian Rhapsody",
            artist: "Queen",
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/fJ9rUzIMcZQ/maxresdefault.jpg")
        )
        currentTrack = track
        isPlaying = true
        playbackState = .playing
        currentTime = 132
        duration = 354
    }

    func play(_ track: Track) {
        // Record the track we're leaving so Previous can return to it. Skip
        // when re-playing the same track (e.g. retry/repeat).
        if let leaving = currentTrack, leaving.id != track.id {
            recordHistory(leaving)
        }
        startPlayback(track)
    }

    /// Starts playback of `track` without touching the play-history stack.
    /// Used by `previousTrack()` and Repeat-All looping, which manage history
    /// themselves.
    private func startPlayback(_ track: Track) {
        if let localURL = track.localFileURL {
            playLocal(track: track, fileURL: localURL)
        } else {
            playStreamed(track: track)
        }
    }

    private func recordHistory(_ track: Track) {
        playHistory.append(track)
        if playHistory.count > maxPlayHistory {
            playHistory.removeFirst(playHistory.count - maxPlayHistory)
        }
    }

    /// Convenience: starts playback of a library entry. Equivalent to
    /// `play(track.asPlayerTrack(fileURL:))` but keeps the call site
    /// explicit about which file is being played.
    func play(localTrack: LocalTrack, fileURL: URL) {
        let track = localTrack.asPlayerTrack(fileURL: fileURL)
        play(track)
    }

    // MARK: - Playback paths

    private func playStreamed(track: Track) {
        playGeneration += 1
        let gen = playGeneration
        log.notice("play track=\(track.id, privacy: .public) gen=\(gen) prevPlayerAlive=\(self.avPlayerPath?.avPlayer != nil, privacy: .public)")
        nowPlaying.activateAudioSession()

        currentTrack = track
        currentArtworkURL = track.thumbnailURL
        currentVideoID = track.id
        didRetryResolve = false
        stallRetryCount = 0
        isRebuffering = false
        isPlaying = true
        playbackState = .loading
        currentTime = 0
        duration = 0
        stopAllPlayback()
        nowPlaying.updateNowPlaying()
        nowPlaying.loadArtwork(for: track)
        fetchStreamURL(for: track.id, generation: gen)
    }

    /// Plays a local file. Honors the current EQ setting: EQ on routes
    /// through the engine path (no download needed), EQ off goes
    /// straight to the AVPlayer path.
    private func playLocal(track: Track, fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            self.currentTrack = track
            self.isPlaying = false
            self.playbackState = .ended
            self.playerError = .trackMissing(trackID: track.id)
            self.nowPlaying.updateNowPlaying()
            return
        }
        playGeneration += 1
        let gen = playGeneration
        log.notice("play local track=\(track.id, privacy: .public) gen=\(gen) eq=\(self.eq.isEnabled, privacy: .public) hasArtwork=\(track.thumbnailURL != nil, privacy: .public)")
        _ = gen  // reserved for future generation-based cancellation
        nowPlaying.activateAudioSession()

        currentTrack = track
        currentArtworkURL = track.thumbnailURL
        currentVideoID = nil  // local file — nothing to re-resolve
        didRetryResolve = false
        isPlaying = true
        playbackState = .loading
        currentTime = 0
        duration = 0
        stopAllPlayback()
        nowPlaying.updateNowPlaying()
        if let artworkURL = track.thumbnailURL {
            nowPlaying.loadArtwork(from: artworkURL)
        }
        currentStreamURL = fileURL
        // Local files play through AVPlayer too; EQ (if on) is applied by the
        // real-time tap inside AVPlayerPath — same single path as streaming.
        playAVPlayer(url: fileURL)
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }

        if isPlaying {
            pause()
        } else {
            nowPlaying.activateAudioSession()
            if playbackState == .ended { avPlayerPath.replayCurrent() }
            avPlayerPath.play()
            isPlaying = true
            playbackState = .playing
        }
        nowPlaying.updateNowPlaying()
    }

    private func pause() {
        isPlaying = false
        playbackState = .paused
        avPlayerPath.pause()
    }

    func seek(to time: TimeInterval) {
        avPlayerPath.seek(to: time)
        currentTime = time
        nowPlaying.updateNowPlaying()
    }

    func applyEQPreset(_ gains: [Float]) {
        let outcome = eq.apply(gains)
        handleEQOutcome(outcome)
    }

    func resetEQ() {
        _ = eq.reset()
        avPlayerPath.setEQEnabled(false)
    }

    private func handleEQOutcome(_ outcome: EQApplyOutcome) {
        // EQ runs through the real-time AVPlayer tap for both streamed and
        // local tracks — live, no engine, no download, no playback restart.
        switch outcome {
        case .noChange, .stillEnabled:
            avPlayerPath.updateEQBands(eq.bands)
        case .becameEnabled:
            avPlayerPath.updateEQBands(eq.bands)
            avPlayerPath.setEQEnabled(true)
        case .becameDisabled:
            avPlayerPath.setEQEnabled(false)
        }
    }

    /// Toggles shuffle over the *upcoming* queue. Turning it on randomises the
    /// queue (snapshotting the original order); turning it off restores that
    /// order, dropping any tracks already consumed while shuffled.
    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            unshuffledQueue = queue
            queue = queue.shuffled()
        } else if let original = unshuffledQueue {
            let remaining = Set(queue.map(\.id))
            queue = original.filter { remaining.contains($0.id) }
            unshuffledQueue = nil
        }
        nowPlaying.updateNowPlaying()
    }

    /// Installs `tracks` as the upcoming queue, honouring the current shuffle
    /// state so a freshly-seeded collection plays shuffled when shuffle is on.
    private func installQueue(_ tracks: [Track]) {
        if isShuffled {
            unshuffledQueue = tracks
            queue = tracks.shuffled()
        } else {
            unshuffledQueue = nil
            queue = tracks
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .one
        case .one: repeatMode = .all
        case .all: repeatMode = .off
        }
    }

    func nextTrack() {
        if !queue.isEmpty || repeatMode == .all {
            playNextInQueue()
        } else {
            seek(to: 0)
            avPlayerPath.pause()
            isPlaying = false
            playbackState = .ended
        }
    }

    /// Whether a Next action can advance: either the queue has tracks, or
    /// Repeat-All can loop back to the start. Drives the remote command's
    /// enabled state.
    var hasNext: Bool { !queue.isEmpty || repeatMode == .all }

    /// Whether a Previous action can step back to an earlier track.
    var hasPrevious: Bool { !playHistory.isEmpty }

    // MARK: - Sleep timer

    /// Arms (or cancels, for `.off`) the sleep timer for the given duration.
    /// When it elapses, playback is paused. Call from the settings UI.
    func startSleepTimer(_ duration: SleepTimerDuration) {
        scheduleSleepTimer(after: duration.timeInterval)
    }

    /// Lower-level entry point taking a raw interval in seconds (or `nil`/<=0
    /// to cancel). Exposed for testing with short intervals.
    func scheduleSleepTimer(after interval: TimeInterval?) {
        sleepTimerTask?.cancel()
        guard let interval, interval > 0 else {
            sleepTimerEndDate = nil
            sleepTimerTask = nil
            return
        }
        sleepTimerEndDate = Date().addingTimeInterval(interval)
        sleepTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.fireSleepTimer()
        }
    }

    private func fireSleepTimer() {
        sleepTimerEndDate = nil
        sleepTimerTask = nil
        if isPlaying {
            pause()
            nowPlaying.updateNowPlaying()
        }
    }

    // MARK: - Favorites wiring

    /// Connects a `FavoritesManager` so the lock-screen Like command can
    /// toggle the current track's favorite state. Call once at launch.
    func configureFavorites(_ favorites: FavoritesManager) {
        nowPlaying.favorites = favorites
        nowPlaying.configureRemoteCommands()
        nowPlaying.updateNowPlaying()
    }

    /// Replaces the queue with `tracks` and starts playback at
    /// `tracks[startIndex]`. Used by callers that want to play a
    /// contiguous slice of a library/playlist (e.g. the Library tab
    /// when the user taps a track in the middle of the list).
    ///
    /// Local tracks flagged `isMissing` (file is no longer on disk)
    /// are filtered out before queuing so a single missing entry
    /// doesn't trigger a 1-by-1 playback error.
    func playSlice(_ tracks: [Track], startIndex: Int) {
        guard !tracks.isEmpty else { return }
        let missing = tracks.filter { $0.isLocal && $0.isMissing }
        let playable = tracks.filter { track in
            guard track.isLocal else { return true }
            return !track.isMissing
        }
        if !missing.isEmpty {
            log.notice("playSlice skipped \(missing.count) missing track(s)")
        }
        guard !playable.isEmpty else { return }
        // Explicit collection playback supersedes any active radio session.
        endRadio()
        let idx = max(0, min(startIndex, playable.count - 1))
        let upcoming = Array(playable.dropFirst(idx + 1))
        // A fresh collection starts a new history lineage.
        playHistory.removeAll()
        installQueue(upcoming)
        play(playable[idx])
    }

    // MARK: - Radio

    /// Starts an endless "play similar songs" session seeded from `seed`:
    /// plays the seed immediately, then fills the queue from the backend's
    /// YouTube-Mix radio and keeps refilling as it drains. Used by Search so
    /// tapping a result plays related music instead of the raw result list.
    func playRadio(seed: Track) {
        radioActive = true
        radioSeen = [seed.id]
        radioRefillTask?.cancel()
        queue = []
        play(seed)
        refillRadio(from: seed.id, replacing: true)
    }

    private func endRadio() {
        radioActive = false
        radioRefillTask?.cancel()
        radioRefillTask = nil
        radioSeen.removeAll()
    }

    /// Fetches similar tracks for `seedID` and either replaces or appends to
    /// the queue, skipping anything already seen this session.
    private func refillRadio(from seedID: String, replacing: Bool) {
        guard radioActive else { return }
        radioRefillTask?.cancel()
        radioRefillTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let fresh: [Track]
            do {
                fresh = try await self.radioService.similar(to: seedID, limit: 25)
            } catch {
                log.error("Radio refill failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            if Task.isCancelled || !self.radioActive { return }
            let novel = fresh.filter { self.radioSeen.insert($0.id).inserted }
            guard !novel.isEmpty else { return }
            if replacing {
                self.queue = novel
            } else {
                self.queue.append(contentsOf: novel)
            }
            log.notice("Radio: +\(novel.count) tracks (queue=\(self.queue.count))")
        }
    }

    /// Steps back to the actually-previously-played track using the play
    /// history. When the user is more than a few seconds into the current
    /// track, restarts it instead (standard transport behaviour). With no
    /// history, restarts the current track.
    func previousTrack() {
        if currentTime > previousRestartThreshold {
            seek(to: 0)
            return
        }
        guard let previous = playHistory.popLast() else {
            seek(to: 0)
            return
        }
        // Put the track we're leaving back at the front of the queue so Next
        // returns to it.
        if let leaving = currentTrack {
            queue.insert(leaving, at: 0)
            if isShuffled { unshuffledQueue?.insert(leaving, at: 0) }
        }
        startPlayback(previous)
    }

    // MARK: - Queue

    func addToQueue(_ track: Track) {
        queue.append(track)
        if isShuffled { unshuffledQueue?.append(track) }
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        let removed = queue.remove(at: index)
        unshuffledQueue?.removeAll { $0.id == removed.id }
    }

    func clearQueue() {
        queue.removeAll()
        unshuffledQueue = nil
    }

    func playNextInQueue() {
        guard !queue.isEmpty else {
            advanceWithEmptyQueue()
            return
        }
        let next = queue.removeFirst()
        unshuffledQueue?.removeAll { $0.id == next.id }
        radioSeen.insert(next.id)
        // Top up an endless radio queue before it runs dry, seeded from the
        // track we're about to play so the station evolves with the listening.
        if radioActive && queue.count <= radioRefillThreshold {
            refillRadio(from: next.id, replacing: false)
        }
        play(next)
    }

    /// Handles a Next action when the queue is empty, honouring the repeat
    /// mode. Repeat-All re-seeds the queue from the tracks played this session
    /// so the collection loops; Repeat-One restarts the current track; Off
    /// ends playback.
    private func advanceWithEmptyQueue() {
        switch repeatMode {
        case .off:
            isPlaying = false
            playbackState = .ended
            nowPlaying.updateNowPlaying()
        case .one:
            if let track = currentTrack { startPlayback(track) }
        case .all:
            // The collection, in play order, is everything in history plus the
            // track that just finished.
            let collection = playHistory + (currentTrack.map { [$0] } ?? [])
            guard collection.count > 1, let first = collection.first else {
                if let track = currentTrack { startPlayback(track) }
                return
            }
            playHistory.removeAll()
            installQueue(Array(collection.dropFirst()))
            play(first)
        }
    }

    // MARK: - Network

    /// Kicks off a `/api/play?video_id=...` request and dispatches the
    /// resulting stream URL to the AVPlayer path or the engine path based
    /// on the current EQ state. The Task is stored on the manager so a
    /// new `play(_:)` call can cancel the prior in-flight request; the
    /// `generation` check is a defensive fallback in case the cancel
    /// races with the response.
    private var streamTask: Task<Void, Never>?
    /// Video ID of the current streamed track (nil for local files), used to
    /// re-resolve a failed direct URL. `didRetryResolve` caps it to one retry
    /// per play so a genuinely dead track surfaces an error instead of looping.
    private var currentVideoID: String?
    private var didRetryResolve = false
    /// Counts mid-playback stall recoveries for the current track so a
    /// persistently-stalling stream eventually gives up instead of looping
    /// re-resolves. Reset on a fresh play and whenever playback recovers.
    private var stallRetryCount = 0
    private let maxStallRetries = 3

    /// Resolves a streamed track to a direct URL and plays it instantly via
    /// AVPlayer. EQ (if on) is applied by the real-time tap inside `AVPlayerPath`
    /// — one path for streamed and local, no engine, no download.
    private func fetchStreamURL(for videoID: String, generation: Int) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let resolved: ResolvedStream
            do {
                resolved = try await self.prefetcher.resolve(for: videoID)
            } catch is CancellationError {
                return
            } catch {
                log.error("Stream URL fetch failed: \(error.localizedDescription, privacy: .public)")
                if generation == self.playGeneration {
                    self.handleFetchError(error)
                }
                return
            }

            if Task.isCancelled { return }
            // Bail if a newer play() arrived while the network call was in flight.
            guard generation == self.playGeneration else { return }

            self.currentStreamURL = resolved.url
            self.playAVPlayer(url: resolved.url, knownDuration: resolved.duration)
            // The current track is on its way; warm the next one so advancing
            // to it is instant.
            self.prefetchNext()
        }
    }

    /// Pre-resolves the next streamed track in the queue (one deep) so
    /// `playNextInQueue` starts it with no `/api/resolve` round-trip. Local
    /// files need no resolve and are skipped.
    private func prefetchNext() {
        guard let next = queue.first, next.localFileURL == nil, !next.id.isEmpty else { return }
        let id = next.id
        Task { [prefetcher] in await prefetcher?.prefetch(id) }
    }

    /// Best-effort, fire-and-forget ping to `/api/health` to wake a sleeping
    /// Render free-tier instance before the user's first real request, so the
    /// cold start (~30–60 s) doesn't fail or stall first play/search. Result is
    /// ignored.
    func warmUpBackend() {
        guard let url = URL(string: "\(Self.backendURL)/api/health") else { return }
        let session = urlSession
        Task { _ = try? await session?.data(from: url) }
    }

    private func handleFetchError(_ error: Error? = nil) {
        isPlaying = false
        playbackState = .idle
        if let error {
            playerError = .streamFailed(error.localizedDescription)
        }
    }

    /// Called by `AVPlayerPath` when its item fails. A streamed track's direct
    /// URL can fail transiently (signed-URL expiry, a flaky cached engine file
    /// after EQ-off), so we re-resolve and retry once before surfacing an error
    /// — turning the "switch back and forth until it works" dance into an
    /// automatic recovery.
    func handleAVPlayerItemFailure(_ error: Error?) {
        if let videoID = currentVideoID, !didRetryResolve {
            didRetryResolve = true
            log.notice("AVPlayer item failed; re-resolving \(videoID, privacy: .public) once")
            playGeneration += 1
            let gen = playGeneration
            playbackState = .loading
            fetchStreamURL(for: videoID, generation: gen)
            return
        }
        isPlaying = false
        playbackState = .idle
        currentStreamURL = nil
        playerError = .streamFailed(error?.localizedDescription ?? "Playback failed")
    }

    /// Called by `AVPlayerPath`'s stall watchdog when the buffer has stayed
    /// empty past the grace period. A signed googlevideo URL can go stale or
    /// the network can dip mid-track; rather than dying to `.idle`, re-resolve
    /// the same video and resume from the current position. Capped at
    /// `maxStallRetries`, reset whenever playback actually recovers.
    func handleStall() {
        guard let videoID = currentVideoID, stallRetryCount < maxStallRetries else { return }
        stallRetryCount += 1
        log.notice("playback stalled; re-resolving \(videoID, privacy: .public) at \(self.currentTime, privacy: .public)s (retry \(self.stallRetryCount, privacy: .public))")
        seekTarget = clock.currentTime
        playGeneration += 1
        let gen = playGeneration
        playbackState = .loading
        fetchStreamURL(for: videoID, generation: gen)
    }

    /// Called by `AVPlayerPath` when the item reports it can keep up again —
    /// clears the buffering UI and lets both the hard-failure and stall retries
    /// re-arm for any future, independent interruption.
    func notePlaybackRecovered() {
        isRebuffering = false
        stallRetryCount = 0
        didRetryResolve = false
    }

    // MARK: - AVPlayer path (delegates to AVPlayerPath)

    private func playAVPlayer(url: URL, knownDuration: TimeInterval? = nil) {
        avPlayerPath.pendingSeek = seekTarget
        seekTarget = nil
        avPlayerPath.play(url: url, knownDuration: knownDuration)
    }

    /// Selector target for the end-of-item notification registered by `AVPlayerPath`.
    @objc func playerItemDidFinish() {
        if repeatMode == .one {
            avPlayerPath.replayCurrent()
        } else {
            playNextInQueue()
        }
    }

    private func stopAllPlayback() {
        seekTarget = nil
        avPlayerPath.stop()
        avPlayerPath.pendingSeek = nil
    }
}
