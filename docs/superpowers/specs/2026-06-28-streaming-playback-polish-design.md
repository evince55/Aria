# Streaming Playback Polish — Design

**Date:** 2026-06-28
**Branch:** `feat/streaming-polish`
**Scope:** Four "felt-quality" improvements to the AVPlayer streaming path. One PR.
No EQ-tap, radio-refill, or backend changes.

## Context

The app now uses **one** playback path: `AVPlayer` + a real-time
`MTAudioProcessingTap` for EQ (the `AVAudioEngine` path was deleted).
`StreamResolver.resolve(for:)` returns a direct googlevideo URL + duration;
a `knownDuration` cap handles the YouTube DASH 2×-duration bug.
iOS 16.6, Swift 5, zero third-party deps.

A re-read of the current code corrected one stale audit assumption: the
per-frame `CADisplayLink`/`pollEngineTime` clock is **gone** with the engine.
`AVPlayerPath` already ticks `currentTime` at a **1.0s** periodic observer, not
60–120 Hz. So the remaining clock problem is **isolation** (the 1 Hz tick still
writes `@Published currentTime` on the big `PlayerManager`, re-rendering every
view), not throttling.

## 1. Next-track prefetch — kill inter-track gaps

**New unit: `Services/StreamPrefetcher.swift`** — an `actor` wrapping
`StreamResolving` plus a tiny in-memory cache.

- State: `[videoID: (stream: ResolvedStream, at: Date)]`, TTL ≈ 5 min.
  (Resolved URLs live ~6 h; a short TTL keeps prefetches fresh and bounded.)
- `func resolve(for videoID: String) async throws -> ResolvedStream` — returns a
  fresh cached entry if present (and consumes it), else delegates to the wrapped
  resolver. This is what `PlayerManager.fetchStreamURL` calls instead of
  `streamResolver.resolve` directly.
- `func prefetch(_ videoID: String)` — fire-and-forget; resolves and stores
  under the cache. Cancels a prior in-flight prefetch for a different id.
- `func cancelPrefetch()` / cache eviction of stale entries on access.

**`PlayerManager` wiring:** after a streamed track reaches the AVPlayer
(`fetchStreamURL` success path), call `prefetcher.prefetch(queue.first.id)` when
`queue.first` is a streamed (non-local) track. `playNextInQueue` → `play` →
`fetchStreamURL` then finds the entry warm and starts with no round-trip.
Local-file tracks are never prefetched.

**Tests:** cache hit returns without a second network call; expired entry falls
through to the resolver; prefetch then resolve consumes the entry.

## 2. Stall / rebuffer recovery on the AVPlayer path

**`AVPlayerPath.swift`:**
- Set `avPlayer.automaticallyWaitsToMinimizeStalling = true`.
- Add block-based KVO on the item's `isPlaybackBufferEmpty` and
  `isPlaybackLikelyToKeepUp` (invalidated alongside the existing observers in
  `play(url:)` and `stop()`).
  - `isPlaybackBufferEmpty == true` while the user intends to play → tell
    `PlayerManager` we're rebuffering, and arm a stall watchdog.
  - `isPlaybackLikelyToKeepUp == true` → clear rebuffering, cancel the watchdog,
    reset the stall-retry counter.
- **Stall watchdog** (~8 s `Task`/timer): if still stalled when it fires,
  ask `PlayerManager` to recover.

**`PlayerManager.swift`:**
- `@Published var isRebuffering = false` (one flag; drives a spinner in the
  player UI). Set/cleared from `AVPlayerPath` via the weak `player` ref.
- `func handleStall()` — like the existing one-shot `handleAVPlayerItemFailure`
  re-resolve, but preserves position: sets `seekTarget = clock.currentTime`,
  bumps `playGeneration`, and re-resolves `currentVideoID`. A `stallRetryCount`
  caps recovery (≈3) and resets on a successful `isPlaybackLikelyToKeepUp`.
- The existing hard-failure re-resolve path is unchanged.

**UI:** `FullScreenPlayerView` (and the mini player) show a small spinner /
"Buffering…" affordance bound to `isRebuffering`.

**Tests:** `handleStall` sets `seekTarget` to the current position and triggers a
resolve request for the current video id; retry counter caps recovery.

## 3. Cold-start detection + retry/backoff

**New unit: `Services/RetryPolicy.swift`** —
`func withRetry<T>(maxAttempts: Int = 3, baseDelay: TimeInterval = 1, isRetryable: (Error) -> Bool, _ op: () async throws -> T) async throws -> T`.

- Exponential backoff ≈ 1 s → 3 s → 9 s (covers Render's ~30–60 s spin-up
  across 3 attempts; respects `Task` cancellation between attempts).
- Default `isRetryable`: `URLError` timeouts / `.networkConnectionLost` /
  `.cannotConnectToHost`, and HTTP **502/503**. Never 4xx, never malformed-JSON.

**Integration:** `StreamResolver.resolve`, `RadioService.similar`, and
`YouTubeSearchService.search` wrap their network+validate step in `withRetry`.
The retryable HTTP-status check moves just inside the retried closure so a 503
throws a retryable error rather than returning.

**Launch warm-ping:** `PlayerManager.warmUpBackend()` fires a fire-and-forget GET
`/api/health` (best-effort, ignores result). `AriaApp` calls it at launch so
Render is waking before the first user action. Silent — no new UI surface.

**Tests:** `withRetry` retries a transient error then succeeds; does not retry a
4xx; `warmUpBackend` issues a `/api/health` request through the mock session.

## 4. PlaybackClock isolation + 4 Hz scrubber

**New unit: `Managers/PlaybackClock.swift`** —
`final class PlaybackClock: ObservableObject { @Published var currentTime = 0; @Published var duration = 0 }`.

- `PlayerManager` owns `let clock = PlaybackClock()` and exposes `currentTime` /
  `duration` as **non-`@Published` computed forwarders** to the clock, so every
  existing call site (NowPlayingService, seek, tests) compiles unchanged but no
  longer triggers a `PlayerManager` `objectWillChange`.
- `AVPlayerPath` writes the periodic time + resolved duration to
  `player.clock.*`. The periodic observer interval drops to **0.25 s (4 Hz)**
  for a smooth scrubber, but `nowPlaying.updateNowPlaying()` is throttled to
  ~1 Hz (only when the whole-second value changes) to avoid spamming the lock
  screen.
- `AriaApp` injects `playerManager.clock` into the environment.
  `FullScreenPlayerView` reads it via `@EnvironmentObject var clock` so only the
  player view re-renders on the tick; `LibraryView`, `SearchView`, etc. no
  longer re-evaluate their bodies once a second.

**Tests:** seek updates `clock.currentTime`; `play` resets clock; forwarders
read through to the clock.

## Non-goals

- No EQ-tap changes, no radio-refill changes, no backend changes.
- No AVPlayerItem preroll (URL pre-resolve only for prefetch).
- No "waking up" UI for cold start (backoff is silent).

## Verification

`xcodebuild test -scheme AriaTests -project Aria.xcodeproj -destination
'platform=iOS Simulator,name=iPhone 15'` stays green; new tests added per
section. Device testing uses the real homelab IP set locally + assume-unchanged
(placeholder stays in git).
