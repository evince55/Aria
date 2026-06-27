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
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var queue: [Track] = []
    @Published var playerError: PlayerError?

    let eq: EQController

    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
        case ended
        /// Engine path is downloading the source stream to `EQCache`
        /// before the first buffer can be scheduled. `progress` is in
        /// `0.0...1.0`; an indeterminate download (no `Content-Length`
        /// from the server) reports `0` until completion.
        case preparingDownload(progress: Double)
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
    private var streamResolver: StreamResolving!

    var nowPlaying: NowPlayingService!
    private var avPlayerPath: AVPlayerPath!

    // MARK: - Engine path

    private var engine: AVAudioEngine?
    private var engineNode: AVAudioPlayerNode?
    private var eqUnit: AVAudioUnitEQ?
    private var scheduleGeneration: Int = 0
    /// Absolute track position (seconds) the engine's AVAssetReader was told
    /// to start from. The AVAudioPlayerNode's own sample clock always restarts
    /// at 0 on each (re)start, so `pollEngineTime` adds this offset to recover
    /// the true position — without it the seek bar desyncs from the audio by
    /// exactly the seek amount.
    private var engineSeekOffset: TimeInterval = 0

    // MARK: - Playback control

    private var timeDisplayLink: CADisplayLink?
    var seekTarget: TimeInterval?

    var isUsingEngine = false
    private var switchingToEngine = false
    private var pendingEngineSwitch = false
    var currentStreamURL: URL?
    private var downloadedFileURL: URL?
    private var downloadTask: Task<Void, Never>?
    private var isStartingEngine = false
    var playGeneration = 0

    // MARK: - Init / deinit

    override init() {
        let session = Self.defaultURLSession()
        self.urlSession = session
        self.streamResolver = StreamResolver(session: session)
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
        self.streamResolver = StreamResolver(session: urlSession)
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
        timeDisplayLink?.invalidate()
        downloadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.togglePlayPauseCommand.removeTarget(nil)
        c.changePlaybackPositionCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)
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
        if let localURL = track.localFileURL {
            playLocal(track: track, fileURL: localURL)
        } else {
            playStreamed(track: track)
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
        log.notice("play track=\(track.id, privacy: .public) gen=\(gen) prevPlayerAlive=\(self.avPlayerPath?.avPlayer != nil, privacy: .public) prevUsingEngine=\(self.isUsingEngine, privacy: .public)")
        nowPlaying.activateAudioSession()

        currentTrack = track
        currentArtworkURL = track.thumbnailURL
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
        if eq.isEnabled {
            downloadAndPlayEngine(url: fileURL)
        } else {
            playAVPlayer(url: fileURL)
        }
    }

    func togglePlayPause() {
        guard currentTrack != nil else { return }

        if isPlaying {
            pause()
        } else {
            nowPlaying.activateAudioSession()
            if pendingEngineSwitch, !isUsingEngine {
                pendingEngineSwitch = false
                isPlaying = true
                playbackState = .loading
                switchToEnginePlayback()
                nowPlaying.updateNowPlaying()
                return
            }
            if isUsingEngine {
                if playbackState == .ended { seekEngine(to: 0) }
                engineNode?.play()
            } else {
                if playbackState == .ended { avPlayerPath.replayCurrent() }
                avPlayerPath.play()
            }
            isPlaying = true
            playbackState = .playing
        }
        nowPlaying.updateNowPlaying()
    }

    private func pause() {
        isPlaying = false
        playbackState = .paused
        if isUsingEngine {
            engineNode?.pause()
        } else {
            avPlayerPath.pause()
        }
    }

    func seek(to time: TimeInterval) {
        if isUsingEngine {
            seekEngine(to: time)
        } else {
            avPlayerPath.seek(to: time)
        }
        currentTime = time
        nowPlaying.updateNowPlaying()
    }

    func applyEQPreset(_ gains: [Float]) {
        let outcome = eq.apply(gains)
        handleEQOutcome(outcome)
    }

    func resetEQ() {
        let wasEnabled = eq.reset()
        pendingEngineSwitch = false
        if wasEnabled && isUsingEngine {
            switchBackToPlayer()
        }
    }

    private func handleEQOutcome(_ outcome: EQApplyOutcome) {
        switch outcome {
        case .noChange:
            if isUsingEngine { applyBandsToEngine(eq.bands) }
        case .becameEnabled, .stillEnabled:
            if isUsingEngine {
                applyBandsToEngine(eq.bands)
            } else if outcome == .becameEnabled {
                if isPlaying {
                    switchToEnginePlayback()
                } else {
                    pendingEngineSwitch = true
                }
            }
        case .becameDisabled:
            pendingEngineSwitch = false
            if isUsingEngine {
                switchBackToPlayer()
            }
        }
    }

    private func applyBandsToEngine(_ bands: [Float]) {
        for i in 0..<10 {
            eqUnit?.bands[i].gain = bands[i]
        }
    }

    func toggleShuffle() { isShuffled.toggle() }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .one
        case .one: repeatMode = .all
        case .all: repeatMode = .off
        }
    }

    func nextTrack() {
        if !queue.isEmpty {
            playNextInQueue()
        } else {
            seek(to: 0)
            if isUsingEngine { engineNode?.stop() } else { avPlayerPath.pause() }
            isPlaying = false
            playbackState = .ended
        }
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
        let idx = max(0, min(startIndex, playable.count - 1))
        let upcoming = Array(playable.dropFirst(idx + 1))
        queue = upcoming
        play(playable[idx])
    }

    /// TODO: Currently a no-op distinction — both branches restart the current
    /// track. Replace with a real previous-track implementation that consults
    /// a track history (i.e. the order tracks were played, not the queue).
    /// For now the behaviour is "tap to restart the current track", which
    /// matches what most lock-screen / control-center users expect.
    func previousTrack() {
        seek(to: 0)
    }

    // MARK: - Queue

    func addToQueue(_ track: Track) {
        queue.append(track)
    }

    func removeFromQueue(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)
    }

    func clearQueue() {
        queue.removeAll()
    }

    func playNextInQueue() {
        guard !queue.isEmpty else {
            if repeatMode == .off {
                isPlaying = false
                playbackState = .ended
                nowPlaying.updateNowPlaying()
                return
            }
            if let track = currentTrack {
                play(track)
            }
            return
        }
        let next = queue.removeFirst()
        play(next)
    }

    func clearEQCache() {
        EQCache.shared.clear()
    }

    // MARK: - Network

    /// Kicks off a `/api/play?video_id=...` request and dispatches the
    /// resulting stream URL to the AVPlayer path or the engine path based
    /// on the current EQ state. The Task is stored on the manager so a
    /// new `play(_:)` call can cancel the prior in-flight request; the
    /// `generation` check is a defensive fallback in case the cancel
    /// races with the response.
    private var streamTask: Task<Void, Never>?

    private func fetchStreamURL(for videoID: String, generation: Int) {
        streamTask?.cancel()
        // Capture the EQ decision once: the engine path needs a downloaded
        // local file (/api/play), but the plain AVPlayer path can start
        // instantly from the direct URL (/api/resolve) — no full download.
        // Deciding up front avoids a race where eq.isEnabled flips mid-fetch
        // and we resolve one way but dispatch the other.
        let useEngine = eq.isEnabled
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let streamURL: URL
            do {
                if useEngine {
                    streamURL = try await self.streamResolver.stream(for: videoID)
                } else {
                    streamURL = try await self.streamResolver.resolve(for: videoID)
                }
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

            // Bail if a newer play() arrived while the network call was
            // in flight. The Task cancellation handles the common case;
            // this check covers the brief window where the cancel
            // hasn't propagated to the resolver yet.
            guard generation == self.playGeneration else { return }

            log.notice("Got stream URL \(streamURL.absoluteString, privacy: .public) gen=\(generation, privacy: .public) willDispatchTo=\(useEngine ? "engine" : "playNative", privacy: .public)")
            self.currentStreamURL = streamURL
            if useEngine {
                self.downloadAndPlayEngine(url: streamURL)
            } else {
                self.playAVPlayer(url: streamURL)
            }
        }
    }

    private func handleFetchError(_ error: Error? = nil) {
        isPlaying = false
        playbackState = .idle
        switchingToEngine = false
        isStartingEngine = false
        if let error {
            playerError = .streamFailed(error.localizedDescription)
        }
    }

    // MARK: - AVPlayer path (delegates to AVPlayerPath)

    private func playAVPlayer(url: URL) {
        avPlayerPath.pendingSeek = seekTarget
        seekTarget = nil
        avPlayerPath.play(url: url)
    }

    /// Selector target for the end-of-item notification registered by `AVPlayerPath`.
    @objc func playerItemDidFinish() {
        if repeatMode == .one {
            if isUsingEngine {
                seekEngine(to: 0)
            } else {
                avPlayerPath.replayCurrent()
            }
        } else {
            playNextInQueue()
        }
    }

    // MARK: - Engine path (with EQ)

    private func downloadAndPlayEngine(url: URL) {
        currentStreamURL = url

        // Local files (imported via the Library tab) don't need a
        // download — skip straight to the engine.
        if url.isFileURL {
            playbackState = .loading
            startEngine(with: url)
            return
        }

        let cacheURL = EQCache.shared.cacheURL(for: url)
        let cached = FileManager.default.fileExists(atPath: cacheURL.path)
        log.notice("downloadAndPlayEngine: cache=\(cached ? "hit" : "miss", privacy: .public) path=\(cacheURL.path, privacy: .public)")
        if cached {
            playbackState = .loading
            startEngine(with: cacheURL)
            return
        }

        playbackState = .preparingDownload(progress: 0)
        downloadTask?.cancel()
        let streamURL = url
        let targetCacheURL = cacheURL
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let downloadedURL = try await self.urlSession.downloadWithProgress(
                    from: streamURL,
                    onProgress: { progress in
                        Task { @MainActor [weak self] in
                            self?.playbackState = .preparingDownload(progress: progress)
                        }
                    }
                )
                let cacheDir = targetCacheURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: targetCacheURL.path) {
                    try FileManager.default.removeItem(at: targetCacheURL)
                }
                try FileManager.default.moveItem(at: downloadedURL, to: targetCacheURL)
                self.startEngine(with: targetCacheURL)
            } catch is CancellationError {
                // Newer play()/stop arrived; nothing to do.
            } catch let urlError as URLError where urlError.code == .cancelled {
                // URLSession.bytes throws URLError(.cancelled) when the
                // wrapping Task is cancelled. Treat as a no-op.
            } catch {
                log.error("Download error: \(error.localizedDescription, privacy: .public)")
                self.playAVPlayer(url: streamURL)
            }
        }
    }

    private func startEngine(with fileURL: URL) {
        guard !isStartingEngine else { return }
        isStartingEngine = true
        downloadedFileURL = fileURL

        let asset = AVURLAsset(url: fileURL)
        guard let audioTrack = asset.tracks(withMediaType: .audio).first else {
            isStartingEngine = false
            fallbackToPlayer(fileURL: fileURL)
            return
        }

        nowPlaying.configureRemoteCommands()
        setupEngine()

        guard let engine, let node = engineNode, let eqUnit = eqUnit else {
            isStartingEngine = false
            fallbackToPlayer(fileURL: fileURL)
            return
        }

        duration = CMTimeGetSeconds(asset.duration)
        if duration == 0 || duration.isNaN {
            duration = CMTimeGetSeconds(audioTrack.timeRange.duration)
        }

        let format: AudioStreamBasicDescription? = {
            guard let any = audioTrack.formatDescriptions.first,
                  let ptr = CMAudioFormatDescriptionGetStreamBasicDescription(any as! CMAudioFormatDescription) else { return nil }
            return ptr.pointee
        }()

        let sampleRate = format?.mSampleRate ?? 44100
        let channels = format?.mChannelsPerFrame ?? 2

        let bufferFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!

        // Reconnect the player node with the *source file's* format so the
        // scheduled buffers match the node's output format. The engine is
        // created once and reused across tracks, so a previous track's sample
        // rate (or the nil-inferred hardware rate) can mismatch this track —
        // scheduleBuffer then traps on
        // `_outputFormat.sampleRate == buffer.format.sampleRate`. This is the
        // most common AVAudioEngine crash and is hit hardest by hi-res local
        // files (e.g. 96 kHz FLAC) whose rate differs from the 44.1/48 kHz
        // default. The mainMixerNode handles conversion to the hardware rate.
        node.stop()
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(eqUnit)
        engine.connect(node, to: eqUnit, format: bufferFormat)
        engine.connect(eqUnit, to: engine.mainMixerNode, format: bufferFormat)

        // AVLinearPCMBitDepthKey is REQUIRED whenever AVLinearPCMIsFloatKey is
        // set: on-device `AVAssetReaderAudioMixOutput` throws
        // NSInvalidArgumentException ("If one of AVLinearPCMIsFloatKey and
        // AVLinearPCMBitDepthKey is specified, both must be specified") if it's
        // missing. The simulator tolerates the omission; hardware does not.
        // 32-bit float matches the .pcmFormatFloat32 bufferFormat above.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            isStartingEngine = false
            fallbackToPlayer(fileURL: fileURL)
            return
        }

        var startOffset: TimeInterval = 0
        if let seek = seekTarget, seek > 0 {
            let cmSeek = CMTime(seconds: seek, preferredTimescale: 600)
            let remaining = CMTimeSubtract(asset.duration, cmSeek)
            if CMTIME_IS_VALID(remaining) && CMTimeGetSeconds(remaining) > 0 {
                reader.timeRange = CMTimeRange(start: cmSeek, duration: remaining)
                startOffset = seek
            }
            seekTarget = nil
        }
        // Record where the reader actually starts so pollEngineTime can report
        // an absolute position (0 for a fresh play, the seek point otherwise).
        engineSeekOffset = startOffset

        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else {
            isStartingEngine = false
            fallbackToPlayer(fileURL: fileURL)
            return
        }

        if !engine.isRunning {
            do { try engine.start() } catch {
                isStartingEngine = false
                fallbackToPlayer(fileURL: fileURL)
                return
            }
        }

        scheduleGeneration += 1
        let gen = scheduleGeneration

        let scheduleQueue = DispatchQueue(label: "eq.schedule")

        scheduleQueue.async { [weak self] in
            guard let self else { return }
            var lastBuffer: AVAudioPCMBuffer?
            var didScheduleFirst = false

            while reader.status == .reading {
                if gen != self.scheduleGeneration { reader.cancelReading(); break }
                guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                    if reader.status == .completed || reader.status == .failed { break }
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                guard let pcmBuffer = self.createPCMBuffer(from: sampleBuffer, format: bufferFormat) else { continue }

                if !didScheduleFirst {
                    didScheduleFirst = true
                    DispatchQueue.main.async {
                        guard gen == self.scheduleGeneration, self.isUsingEngine else { return }
                        self.engineNode?.scheduleBuffer(pcmBuffer, completionHandler: nil)
                        self.engineNode?.play()
                        self.isPlaying = true
                        self.playbackState = .playing
                        // The "starting" phase is over once the first buffer is
                        // playing. Leaving this true (as before) meant it stayed
                        // set for the whole track, so seekEngine()'s restart hit
                        // `guard !isStartingEngine` and bailed after it had already
                        // stopped the node — seeking/skipping killed playback.
                        self.isStartingEngine = false
                        self.startTimeDisplayLink()
                        self.nowPlaying.updateNowPlaying()
                    }
                } else {
                    let toSchedule = lastBuffer
                    lastBuffer = pcmBuffer
                    DispatchQueue.main.async {
                        guard gen == self.scheduleGeneration, self.isUsingEngine else { return }
                        if let toSchedule = toSchedule {
                            self.engineNode?.scheduleBuffer(toSchedule, completionHandler: nil)
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.005)
            }

            if reader.status == .completed {
                let finalBuffer = lastBuffer
                let didStart = didScheduleFirst
                DispatchQueue.main.async {
                    guard gen == self.scheduleGeneration, self.isUsingEngine else { return }
                    if let finalBuffer = finalBuffer, didStart {
                        self.engineNode?.scheduleBuffer(finalBuffer, completionCallbackType: .dataPlayedBack) { _ in
                            DispatchQueue.main.async {
                                guard gen == self.scheduleGeneration else { return }
                                self.isStartingEngine = false
                                self.playerItemDidFinish()
                            }
                        }
                    } else {
                        self.isStartingEngine = false
                        self.playerItemDidFinish()
                    }
                }
            } else if reader.status == .failed {
                log.error("Reader failed: \(reader.error?.localizedDescription ?? "?", privacy: .public)")
                reader.cancelReading()
                DispatchQueue.main.async {
                    self.isStartingEngine = false
                    self.fallbackToPlayer(fileURL: fileURL)
                }
            }
        }

        isUsingEngine = true
        switchingToEngine = false
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Let CoreMedia copy the decoded PCM into the buffer's audioBufferList.
        // The previous hand-rolled pointer arithmetic assumed the CMBlockBuffer
        // was contiguous and planar with a channel count matching `format` —
        // none of which is guaranteed. Non-contiguous block buffers, mono
        // sources, or interleaved data all caused out-of-bounds reads (crash /
        // corruption), most often on local FLAC/ALAC imports. This API handles
        // contiguity and layout correctly per the sample buffer's own format.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            log.error("PCM copy failed: OSStatus \(status, privacy: .public)")
            return nil
        }
        return pcmBuffer
    }

    private func setupEngine() {
        guard engine == nil else {
            applyBandsToEngine(eq.bands)
            return
        }

        let eng = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 10)

        for i in 0..<10 {
            let f = eq.bands[i]
            f.filterType = .parametric
            f.frequency = PlayerManager.eqFrequencies[i]
            f.bandwidth = 1.0
            f.gain = self.eq.bands[i]
            f.bypass = false
        }

        eng.attach(node)
        eng.attach(eq)
        eng.connect(node, to: eq, format: nil)
        eng.connect(eq, to: eng.mainMixerNode, format: nil)

        engine = eng
        engineNode = node
        eqUnit = eq
    }

    private func seekEngine(to time: TimeInterval) {
        engineNode?.stop()
        scheduleGeneration += 1
        // This is a deliberate restart: clear the starting guard so the
        // startEngine() call below isn't rejected by `guard !isStartingEngine`.
        // The scheduleGeneration bump above already invalidates the prior
        // schedule loop, so there's no double-start risk.
        isStartingEngine = false

        seekTarget = time
        if let fileURL = downloadedFileURL {
            playbackState = .loading
            startEngine(with: fileURL)
        } else if let track = currentTrack {
            playGeneration += 1
            let gen = playGeneration
            playbackState = .loading
            fetchStreamURL(for: track.id, generation: gen)
        }
    }

    private func startTimeDisplayLink() {
        timeDisplayLink?.invalidate()
        timeDisplayLink = CADisplayLink(target: self, selector: #selector(pollEngineTime))
        timeDisplayLink?.add(to: .main, forMode: .common)
    }

    @objc private func pollEngineTime() {
        guard let node = engineNode, node.isPlaying,
              let lastTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: lastTime) else { return }
        // playerTime.sampleTime is relative to the node's last start (always 0
        // after a seek/restart); add the reader's start offset for the true
        // absolute track position so the seek bar tracks the audio.
        currentTime = engineSeekOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
        nowPlaying.updateNowPlaying()
    }

    private func fallbackToPlayer(fileURL: URL) {
        log.notice("Engine path failed, falling back to AVPlayer")
        isUsingEngine = false
        switchingToEngine = false
        isStartingEngine = false
        stopEngine()
        avPlayerPath.stop()
        let fallbackURL = currentStreamURL ?? fileURL
        playAVPlayer(url: fallbackURL)
    }

    private func switchToEnginePlayback() {
        guard !switchingToEngine, let track = currentTrack else { return }
        playGeneration += 1
        let gen = playGeneration
        switchingToEngine = true
        pendingEngineSwitch = false
        seekTarget = currentTime
        avPlayerPath.stop()
        DispatchQueue.main.async { [weak self] in
            guard let self, gen == self.playGeneration else { return }
            if let localURL = track.localFileURL {
                self.downloadAndPlayEngine(url: localURL)
            } else {
                self.fetchStreamURL(for: track.id, generation: gen)
            }
        }
    }

    private func switchBackToPlayer() {
        guard isUsingEngine else { return }
        let pos = currentTime
        seekTarget = pos
        stopEngine()
        isUsingEngine = false

        guard let url = currentStreamURL else {
            isPlaying = false
            playbackState = .idle
            return
        }
        playAVPlayer(url: url)
    }

    func stopEngine() {
        scheduleGeneration += 1
        timeDisplayLink?.invalidate()
        timeDisplayLink = nil
        engineNode?.stop()
        engine?.stop()
        engine = nil
        engineNode = nil
        eqUnit = nil
    }

    private func stopAllPlayback() {
        downloadTask?.cancel()
        downloadTask = nil
        seekTarget = nil
        scheduleGeneration += 1
        stopEngine()
        avPlayerPath.stop()
        avPlayerPath.pendingSeek = nil
        isUsingEngine = false
        timeDisplayLink?.invalidate()
        timeDisplayLink = nil
    }
}
