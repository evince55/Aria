import Foundation
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "StreamPrefetcher")

/// Pre-resolves the *next* queued track's stream URL so advancing to it starts
/// instantly instead of paying a fresh `/api/resolve` round-trip.
///
/// Wraps a `StreamResolving` and keeps a tiny, short-TTL in-memory cache keyed
/// by video ID. `PlayerManager` calls `prefetch(_:)` once the current track is
/// playing, then `resolve(for:)` (instead of the bare resolver) on the next
/// advance — which returns the warm entry with no network call when it's fresh.
///
/// Resolved googlevideo URLs stay valid for hours; the short TTL just bounds
/// staleness and memory for a one-deep look-ahead.
actor StreamPrefetcher: StreamResolving {
    private let resolver: StreamResolving
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    private struct Entry {
        let stream: ResolvedStream
        let at: Date
    }
    private var cache: [String: Entry] = [:]
    private var inFlight: (id: String, task: Task<Void, Never>)?

    init(
        resolver: StreamResolving,
        ttl: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.resolver = resolver
        self.ttl = ttl
        self.now = now
    }

    /// `StreamResolving` conformance — the `/api/play` download path is not
    /// prefetched, so just forward it.
    func stream(for videoID: String) async throws -> URL {
        try await resolver.stream(for: videoID)
    }

    /// Returns a fresh pre-resolved stream for `videoID` if one is cached,
    /// consuming it; otherwise resolves through the wrapped resolver. This is
    /// the call `PlayerManager` makes for normal playback so prefetched tracks
    /// start with no round-trip.
    func resolve(for videoID: String) async throws -> ResolvedStream {
        if let entry = cache.removeValue(forKey: videoID),
           now().timeIntervalSince(entry.at) < ttl {
            log.notice("prefetch hit \(videoID, privacy: .public)")
            return entry.stream
        }
        return try await resolver.resolve(for: videoID)
    }

    /// Fire-and-forget: resolve `videoID` and stash it for the next
    /// `resolve(for:)`. Cancels any prefetch for a different id so only the
    /// one upcoming track is ever warmed.
    func prefetch(_ videoID: String) {
        if cache[videoID] != nil { return }
        if let inFlight, inFlight.id == videoID { return }
        inFlight?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.resolver.resolve(for: videoID)
                await self.store(stream, for: videoID)
            } catch {
                log.debug("prefetch miss \(videoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        inFlight = (videoID, task)
    }

    /// Drops any in-flight prefetch and cached entries (e.g. when the queue is
    /// cleared or replaced).
    func cancelPrefetch() {
        inFlight?.task.cancel()
        inFlight = nil
        cache.removeAll()
    }

    /// Test hook: await any in-flight prefetch so tests can assert against a
    /// settled cache deterministically. No-op in production.
    func waitForPrefetch() async {
        await inFlight?.task.value
    }

    private func store(_ stream: ResolvedStream, for videoID: String) {
        if Task.isCancelled { return }
        cache[videoID] = Entry(stream: stream, at: now())
        if inFlight?.id == videoID { inFlight = nil }
        log.notice("prefetched \(videoID, privacy: .public)")
    }
}
