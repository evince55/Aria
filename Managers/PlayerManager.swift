import Foundation
import MediaPlayer
import Combine
import AVFoundation
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "PlayerManager")

final class PlayerManager: NSObject, ObservableObject {
    // MARK: - Published state

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var playbackState: PlaybackState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var queue: [Track] = []

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

    // MARK: - Configuration

    static let backendURL: String = {
        if let url = Bundle.main.object(forInfoDictionaryKey: "ARIA_BACKEND_URL") as? String {
            return url
        }
        #if DEBUG
        // Homelab over Tailscale — WireGuard already encrypts the tunnel,
        // so plain HTTP is fine for local dev. HTTPS was attempted but
        // requires a system-trusted CA on the device, which is impractical
        // to install on a real iPhone for a dev-only backend.
        return "http://100.76.103.1:8000"
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
        playGeneration += 1
        let gen = playGeneration
        log.notice("play track=\(track.id, privacy: .public) gen=\(gen) prevPlayerAlive=\(self.avPlayerPath?.avPlayer != nil, privacy: .public) prevUsingEngine=\(self.isUsingEngine, privacy: .public)")
        nowPlaying.activateAudioSession()

        currentTrack = track
        isPlaying = true
        playbackState = .loading
        currentTime = 0
        duration = 0
        stopAllPlayback()
        nowPlaying.updateNowPlaying()
        nowPlaying.loadArtwork(for: track)
        fetchStreamURL(for: track.id, generation: gen)
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
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let streamURL: URL
            do {
                streamURL = try await self.streamResolver.stream(for: videoID)
            } catch is CancellationError {
                return
            } catch {
                log.error("Stream URL fetch failed: \(error.localizedDescription, privacy: .public)")
                if generation == self.playGeneration {
                    self.handleFetchError()
                }
                return
            }

            if Task.isCancelled { return }

            // Bail if a newer play() arrived while the network call was
            // in flight. The Task cancellation handles the common case;
            // this check covers the brief window where the cancel
            // hasn't propagated to the resolver yet.
            guard generation == self.playGeneration else { return }

            log.notice("Got stream URL \(streamURL.absoluteString, privacy: .public) gen=\(generation, privacy: .public) willDispatchTo=\(self.eq.isEnabled ? "engine" : "playNative", privacy: .public)")
            self.currentStreamURL = streamURL
            if self.eq.isEnabled {
                self.downloadAndPlayEngine(url: streamURL)
            } else {
                self.playAVPlayer(url: streamURL)
            }
        }
    }

    private func handleFetchError() {
        isPlaying = false
        playbackState = .idle
        switchingToEngine = false
        isStartingEngine = false
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

        guard let engine, engineNode != nil, eqUnit != nil else {
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

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: channels,
            AVSampleRateKey: sampleRate,
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            isStartingEngine = false
            fallbackToPlayer(fileURL: fileURL)
            return
        }

        if let seek = seekTarget, seek > 0 {
            let cmSeek = CMTime(seconds: seek, preferredTimescale: 600)
            let remaining = CMTimeSubtract(asset.duration, cmSeek)
            if CMTIME_IS_VALID(remaining) && CMTimeGetSeconds(remaining) > 0 {
                reader.timeRange = CMTimeRange(start: cmSeek, duration: remaining)
            }
            seekTarget = nil
        }

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

        let bufferFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)
            ?? AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))!

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

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var totalLength = 0
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)

        guard let src = dataPointer, totalLength > 0 else { return nil }

        let channelCount = Int(format.channelCount)
        let bytesPerChannel = totalLength / channelCount
        let floatCount = bytesPerChannel / MemoryLayout<Float>.size
        let actualFrameCount = min(floatCount, Int(frameCount))
        guard actualFrameCount > 0 else { return nil }

        for ch in 0..<channelCount {
            if let dst = pcmBuffer.floatChannelData?[ch] {
                let offset = ch * floatCount
                let srcFloats = src.withMemoryRebound(to: Float.self, capacity: totalLength / MemoryLayout<Float>.size) { $0 }
                dst.update(from: srcFloats + offset, count: actualFrameCount)
            }
        }

        pcmBuffer.frameLength = AVAudioFrameCount(actualFrameCount)
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
        currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
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
            self.fetchStreamURL(for: track.id, generation: gen)
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
