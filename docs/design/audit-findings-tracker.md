# Aria — Audit Findings Tracker

Source: the initial multi-agent "ultracode" sweep (96 agents, ~4.4M tokens, 85 verified findings), re-verified against the **current** code on 2026-06-27 by an 11-agent status pass (one per dimension).

**Status: 19 done · 13 partial · 53 open** (of 85). Status reflects the `feat/progressive-radio` branch (stacked on the EQ fixes) + the `feat/llmops-backend-hardening` branch (backend vendored into the repo at `backend/`).

Legend: ✅ done · 🟡 partial · ⬜ open. Severity from the original sweep. "Evidence" is the verifier's current-code justification.

## Update 2026-06-28 — broken playback features fixed (`feat/playback-fixes`)

Five advertised-but-dead playback features were implemented in
`Managers/PlayerManager.swift`, `Services/NowPlayingService.swift`, and the
player/settings views, with 13 new XCTest cases in `PlayerManagerTests`:

- ✅ **Implement real shuffle** (was 🟡) — `toggleShuffle()` now shuffles the
  upcoming queue and snapshots the original order so it's reversible;
  `playSlice` honours the shuffle state on fresh collections.
- ✅ **Implement Repeat-All** (was ⬜) — when the queue drains under
  `repeatMode == .all`, it re-seeds from the tracks played this session and
  loops.
- ✅ **Add a play history so Previous-track works** (was ⬜) — a bounded
  `playHistory` stack; `previousTrack()` steps back to the actual prior track
  (or restarts when >3s in).
- ✅ **Wire up the Sleep Timer** (was ⬜) — `startSleepTimer` schedules a pause
  when the persisted duration elapses; the More screen shows a live countdown.
- ✅ **Enable/disable next/prev remote commands + Like command** (were ⬜) —
  `NowPlayingService` now toggles `nextTrackCommand`/`previousTrackCommand`
  enabled-state via `hasNext`/`hasPrevious`, the previous command drives the
  real history-based `previousTrack`, and a `likeCommand` toggles
  `FavoritesManager`.
- 🟡 **Real previous-track and gapless/crossfade transitions** (was ⬜) —
  previous-track is now real; gapless/crossfade still open.

## Update 2026-06-28 — EQ tap rewrite merged

The EQ playback path was rewritten from download-then-`AVAudioEngine` to a
real-time `MTAudioProcessingTap` on `AVPlayer` (one path, streamed + local). This
resolves several findings the per-row tables below still list as open/partial:

- ✅ **Bring EQ to the streaming path so enabling EQ doesn't force a full download**
  (was XL/open) — EQ is now instant via the tap; no download.
- ✅ **Stream the EQ download to disk instead of buffering in RAM** (was partial)
  — moot: there is no EQ download anymore.
- ✅ **Make engine seek incremental instead of re-decoding** (was open) — moot:
  `AVPlayer` does native seek; the `AVAssetReader` engine is gone.
- ✅ **Bound the EQ audio cache** (was open) — moot: `EQCache` deleted.
- 🟡 **Decompose the 914-line PlayerManager god object** (was open → improved) —
  ~640 lines of engine/swap code removed; the dual-path flag soup is gone.
  Remaining: `AVPlayerPath` could still be split further.

(The per-dimension tables below predate this and aren't individually re-marked.)

## Update 2026-06-28 — LLMOps backend hardening merged

The backend was **vendored into the Aria repo** (`backend/`) as the single
source of truth and given a real observability/reliability layer. Deploy is now
`scp backend/app.py …` from the repo (see `backend/README.md`). The following
findings from the LLMOps track are resolved (rows below updated in place):

- ✅ **Structured logging + request IDs + latency metrics** — `logging` config,
  an ASGI middleware that stamps `X-Request-ID` and records p50/p95 per
  endpoint, `/api/metrics`, and an enriched `/api/health` (yt-dlp version, node
  status, uptime, error rate). print() is gone.
- ✅ **Persist LRU access metadata to disk** — `.access_times.json`, loaded on
  startup, throttled saves, flushed on shutdown/eviction/clear.
- ✅ **Pin + auto-update yt-dlp** — floor-pinned in `requirements.txt`;
  `update-yt-dlp.sh` + `aria-yt-dlp-update.timer` keep it current.
- ✅ **Validate downloads + sweep partials** — size/ffprobe validation before
  serving; startup sweep of `.part`/`.ytdl`/zero-byte; corrupt downloads discarded.
- ✅ **Disk-full guard** — `shutil.disk_usage` precheck → 507 before download.
- ✅ **Format-aware cache key** — files tagged `{id}.bestaudio.*`, deterministic
  m4a-preferred lookup (no more arbitrary `matches[0]`).
- ✅ **Node detection** — env → `shutil.which` → common paths, with a startup
  check and health report.
- ✅ **CI** — `.github/workflows/ci.yml` runs backend py_compile+pytest (linux)
  and iOS `xcodebuild test` (macOS) on every push/PR.
- ✅ **Backend test suite** — 44 pytest/TestClient cases (eviction, rate limit,
  single-flight, retry classification, validation, disk guard, resolve/radio,
  metrics, persisted LRU).
- ✅ **Health alerting / uptime monitoring** — `healthcheck.sh` +
  `aria-healthcheck.timer` (run off-box / external monitor recommended).

Still **partial** in this track: resolved-format-URL caching (extraction still
re-runs per `/api/resolve`).

## Addressed this session (done / partial)

- 🟡 partial · *high* — Stream the EQ download to disk instead of buffering the whole file in RAM
- ✅ done · *critical* — Add a multi-client yt-dlp fallback chain instead of a single android_vr client
- 🟡 partial · *high* — Stop hard-coding the node binary path; detect it or make it configurable
- 🟡 partial · *high* — Serialized single-download semaphore collides with the client's 15s request timeout
- ✅ done · *high* — Open yt-dlp proxy: arbitrary video_id with no validation enables abuse, glob injection, and URL-parameter injection
- ✅ done · *high* — Unbounded downloads (no duration/size cap) allow trivial disk-fill and denial-of-wallet
- 🟡 partial · *critical* — No authentication on any backend endpoint — public Render URL is a wide-open service
- 🟡 partial · *high* — DELETE /api/cache lets any anonymous caller wipe the entire shared cache
- 🟡 partial · *medium* — /api/stream path handling relies on implicit normalization; harden against traversal and serve only known cache files
- ✅ done · *critical* — Playing a search result dead-ends instead of continuing into a radio/autoplay queue
- 🟡 partial · *medium* — Result ranking is raw yt-dlp order with no music-intent filtering; duration is fetched but discarded
- ✅ done · *critical* — Stream the URL to the client and play progressively instead of downloading the whole file first
- ✅ done · *critical* — Replace the global Semaphore(1) download/search serialization that blocks every user on one instance
- ✅ done · *high* — Return the stream URL before the download completes via single-flight + client retry, decoupling resolve latency from download latency
- 🟡 partial · *medium* — Pin/standardize the yt-dlp player_client and cache resolved format URLs to avoid repeated heavy extraction
- 🟡 partial · *high* — Make the custom seek slider, transport, and now-playing state accessible to VoiceOver and honor reduce-motion
- ✅ done · *critical* — Fix AtomicFileWriter so it actually overwrites — every save after the first silently fails
- 🟡 partial · *critical* — Surface stream-fetch failures to the user instead of silently going idle
- 🟡 partial · *high* — Stop buffering entire audio files in memory byte-by-byte in downloadWithProgress
- 🟡 partial · *high* — Now Playing elapsed time freezes on the lock screen while backgrounded
- 🟡 partial · *high* — Streamed-playback failures are invisible to the user and to any monitor
- 🟡 partial · *high* — Backend uses bare print() with no structured logging, request IDs, or latency metrics
- ✅ done · *critical* — Make collections auto-fill the queue for continuous playback
- 🟡 partial · *high* — Implement real shuffle (button currently does nothing)

## iOS — Playback Engine

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ⬜ open | high | M | Prefetch and pre-resolve the next queued track to kill inter-track gaps | playNextInQueue() (PlayerManager.swift:524-545) still calls play() cold; no look-ahead StreamResolver.resolve of queue.first and no EQCache pre-warm anywhere — grep for prefetch/preResolve returns nothing. Radio refill only appends Tracks, never pre-resolves URLs. |
| ⬜ open | high | M | Add stall/rebuffer recovery to the AVPlayer streaming path | AVPlayerPath.swift:61-101 still observes only .rate and .status; no isPlaybackBufferEmpty/isPlaybackLikelyToKeepUp KVO, no automaticallyWaitsToMinimizeStalling. On .failed (74-78) it flips to .idle and nulls currentStreamURL with no re-resolve/retry. preferredForwardBufferDuration=10 is set but t… |
| ⬜ open | high | L | Decompose the 914-line PlayerManager god object | PlayerManager.swift is now 1047 lines (grew). The AVAudioEngine+AVAssetReader engine path is still inline (PlayerManager.swift:646-1033); no EnginePlaybackPath service and no common PlaybackPath protocol — only AVPlayerPath remains extracted, as before. |
| ⬜ open | high | XL | Bring EQ to the streaming path so enabling EQ doesn't force a full download | fetchStreamURL still gates on eq.isEnabled and routes to downloadAndPlayEngine (PlayerManager.swift:568,605-606), which downloads the whole file before scheduling (646-698). AVPlayer path still has no AVAudioUnitEQ; EQ toggle still tears down/re-downloads via switchToEnginePlayback (991-1007). |
| 🟡 partial | high | M | Stream the EQ download to disk instead of buffering the whole file in RAM | Download half is fixed: URLSessionProtocols.swift:80-99 flushes 64KB chunks to a FileHandle, no full-file Data buffer. But the engine schedule loop (PlayerManager.swift:811-853) still races ahead with only 5ms sleeps, scheduling every decoded buffer onto AVAudioPlayerNode which retains all unplay… |
| ⬜ open | medium | M | Make engine seek incremental instead of re-decoding (and re-fetching) from scratch | seekEngine (PlayerManager.swift:942-961) still stops the node, bumps scheduleGeneration, and calls startEngine, which builds a fresh AVAssetReader with a new timeRange (768-790). When downloadedFileURL is nil it still re-calls fetchStreamURL (956-959), a full network re-resolve on scrub. |
| ⬜ open | medium | M | Bound the EQ audio cache — it grows without limit | EQCache.swift has no size cap, no LRU, no count limit — only clear() (40-46). Still keyed on SHA-256 of stream.absoluteString (33-35), which includes expiring googlevideo params, so re-resolves miss and duplicate. The extension-preservation change is unrelated to bounding. |
| 🟡 partial | medium | L | Implement real previous-track and gapless/crossfade transitions | previousTrack() is still just seek(to: 0) with a TODO acknowledging the no-op (PlayerManager.swift:500-507); no play-history stack exists (grep finds none). playNextInQueue still destructively removeFirst (537) and play() calls stopAllPlayback (272,302,1035) — hard cuts, no overlap/crossfade. |

## Backend — Cache & Reliability

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | M | Add a multi-client yt-dlp fallback chain instead of a single android_vr client | _YTDL_PLAYER_CLIENTS = ["android_vr","ios","tv_embedded","web"] is now an ordered fallback list passed to both _download_sync (app.py:149) and _resolve_sync (app.py:236); search uses extract_flat with no stream extraction so it doesn't need it. |
| ✅ done | high | S | Persist LRU access metadata to disk so eviction survives restarts | `_load_access_times`/`_save_access_times` persist `_stream_access_times` to `song_cache/.access_times.json`; lifespan loads it on startup, `_record_access` saves (throttled), shutdown/eviction/clear flush. Eviction order survives restart. Covered by `test_access_times_survive_reload`. |
| ✅ done | high | S | Pin and auto-update yt-dlp rather than leaving it unversioned | requirements.txt floor-pins `yt-dlp>=2026.6.9` (fastapi/uvicorn exact); `update-yt-dlp.sh` + `aria-yt-dlp-update.timer` upgrade daily and restart only on change; `/api/health` now reports `yt_dlp_version`. |
| ✅ done | high | M | Validate downloaded files and clean up partial/corrupt artifacts before serving | `_is_valid_media` (size + ffprobe-if-present) gates serving; failed downloads are unlinked and counted (`invalid_media`); `_find_cached_file` skips `.part`/`.ytdl`/zero-byte; `_cleanup_partial_files` sweeps junk on startup. Covered by validation/cleanup tests. |
| ✅ done | high | S | Stop hard-coding the node binary path; detect it or make it configurable | `_detect_node_path()`: env `NODE_PATH` (if a real file) → `shutil.which("node")` → common paths → None (then yt-dlp self-discovers). Resolved once at boot, logged at startup, surfaced in `/api/health.node`. Covered by 3 detection tests. |
| 🟡 partial | high | M | Serialized single-download semaphore collides with the client's 15s request timeout | download concurrency raised from 1 to env-tunable DOWNLOAD_CONCURRENCY=2 (app.py:74) and new /api/resolve returns a direct stream URL without downloading (app.py:457-482), which the non-EQ client path now uses (PlayerManager.swift:581); but the engine//api/play path still does a full serialized d… |
| ✅ done | medium | M | Make the cache key include format/quality, not just video_id | outtmpl is now `{id}.bestaudio.%(ext)s` (`AUDIO_FORMAT_TAG`), and `_find_cached_file` resolves deterministically by extension preference (m4a first), skipping junk — no more arbitrary `matches[0]`. Legacy untagged files still resolve as a fallback. Covered by `test_find_cached_file_prefers_m4a`. |
| ✅ done | medium | M | Add disk-full handling and structured failure observability | `_check_disk_space(MAX_FILESIZE_BYTES)` runs before download → 507 if free < `MIN_FREE_DISK_BYTES`; failures are typed (429/401/400/404/502/507) and logged via `logging`; `/api/metrics` exposes p50/p95 + `failures_by_reason`; `/api/health` reports error_rate, versions, node. |

## Backend — Security & Abuse

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| 🟡 partial | critical | M | No authentication on any backend endpoint — public Render URL is a wide-open service | _require_api_key Depends added to play/search/resolve/radio/cache (app.py:113-125,351,428,461,490,511), but it's a no-op unless ARIA_API_KEY env var is set (default empty, app.py:38,117-118) and the iOS client still sends no auth header (StreamResolver.swift:51,78 plain GETs); no CORS. |
| ✅ done | high | S | Open yt-dlp proxy: arbitrary video_id with no validation enables abuse, glob injection, and URL-parameter injection | _VIDEO_ID_RE=^[A-Za-z0-9_-]{11}$ enforced before any glob/yt-dlp call on play/resolve/radio (app.py:41,357-358,469-470,496-497), closing glob and &list= URL-param injection. |
| ✅ done | high | M | Unbounded downloads (no duration/size cap) allow trivial disk-fill and denial-of-wallet | ydl_opts now sets match_filter 'duration < 900 & !is_live' and max_filesize=60MB (app.py:27-29,158-161); download semaphore raised to 2 and socket_timeout caps stalls (app.py:74,151). |
| ⬜ open | high | M | Rate limiting keyed on spoofable X-Forwarded-For — limiter is bypassable and memory-unbounded | _client_ip still trusts x-forwarded-for unconditionally with no trusted-proxy allowlist (app.py:85-92) and _request_log defaultdict(deque) is never pruned of stale spoofed-IP keys (app.py:82,101). |
| 🟡 partial | high | S | DELETE /api/cache lets any anonymous caller wipe the entire shared cache | clear_cache now has Depends(_require_api_key) (app.py:511); docstring claims 'always requires auth' but it's only enforced when ARIA_API_KEY is set, so default deployment is still wipeable; no rate-limit/IP-log added. |
| ⬜ open | medium | M | Release client disables ATS globally (NSAllowsArbitraryLoads=true) and does no cert pinning in production | Info.plist still sets NSAllowsArbitraryLoads=true app-wide plus the googlevideo insecure-HTTP exception (Aria---Music-Browser-Info.plist:7-8,13-19); TLSPinningDelegate still nils the pin in Release (#else branches, TLSPinningDelegate.swift:48-52,72-73), so the Render backend is unpinned. |
| 🟡 partial | medium | S | /api/stream path handling relies on implicit normalization; harden against traversal and serve only known cache files | stream() now does (CACHE_DIR/file_name).resolve() with explicit is_relative_to(CACHE_DIR.resolve()) containment check (app.py:412-414), closing traversal; the 11-char-ID filename regex from the improvement was not added. |
| ⬜ open | low | S | Search query passed unbounded to yt-dlp ytsearch25 — no length cap or per-query cost control | search() still applies no max length to q (app.py:435-437) and _search_cache grows one entry per unique query with only lazy TTL eviction on re-request (app.py:78,440-444,453) — no LRU/max-entries/sweep. |

## iOS — Search & Discovery

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | L | Playing a search result dead-ends instead of continuing into a radio/autoplay queue | SearchView taps now call playerManager.playRadio(seed:) (SearchView.swift:240,338,371); PlayerManager.playRadio/refillRadio seed+auto-refill a queue from backend /api/radio (PlayerManager.swift:458-498,541-543) via RadioService; backend exposes /api/radio YouTube-Mix endpoint (app.py:485-507). |
| ⬜ open | high | M | Search is capped at 25 results with no pagination or infinite scroll | Backend still hard-codes ytsearch25: with no page/offset param (app.py:209); YouTubeSearchService issues a single GET /api/search?q= (lines 40-82); SearchView renders the whole array in a plain List with no onAppear-of-last-row / load-more trigger (SearchView.swift:220-278). |
| ⬜ open | high | M | 'Trending' and 'Based on your listening' are both just the recently-played list relabeled | recentlyPlayedSection still renders recentlyPlayed.prefix(8) and trendingSection renders the same recentlyPlayed.prefix(20) with the empty 'start listening to see trends' state (SearchView.swift:180,195-209); no trending/popular backend endpoint exists (grep on app.py finds none). |
| ⬜ open | medium | M | No search suggestions / autocomplete; results only fire after 3 chars + 600ms | runSearch still gates trimmed.count >= 3 then Task.sleep 600ms before the network call (SearchView.swift:396,406); no /api/suggest endpoint in backend and no suggest/autocomplete code in iOS (grep returns nothing). |
| 🟡 partial | medium | M | Result ranking is raw yt-dlp order with no music-intent filtering; duration is fetched but discarded | Backend still returns raw ytsearch order and includes duration (app.py:209,219); a duration cap exists only as a download-time match_filter (MAX_DURATION_SECONDS=900, app.py:158-160), not a search re-rank; iOS SearchResult decoder still decodes only id/title/artist/thumbnail and drops duration (Y… |
| ⬜ open | low | S | Search history is stored in raw UserDefaults, bypassing the project's KeyValueStore/Debouncer convention | SettingsManager still writes searchHistory synchronously to UserDefaults.standard on every mutation via save() (SettingsManager.swift:28,40,65-71); no KeyValueStore/Debouncer migration. |

## Backend — Streaming & Latency

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | L | Stream the URL to the client and play progressively instead of downloading the whole file first | backend/app.py:457-482 adds /api/resolve (download=False, returns direct googlevideo url); PlayerManager.swift:581-608 uses streamResolver.resolve + playAVPlayer for non-EQ playback; only the EQ engine path still downloads via /api/play. |
| ✅ done | critical | S | Replace the global Semaphore(1) download/search serialization that blocks every user on one instance | backend/app.py:73-74 now Semaphore(SEARCH_CONCURRENCY=4) and Semaphore(DOWNLOAD_CONCURRENCY=2), env-tunable and decoupled; resolve runs under the search semaphore (app.py:474) so it never queues behind downloads. |
| ✅ done | high | M | Return the stream URL before the download completes via single-flight + client retry, decoupling resolve latency from download latency | backend/app.py:457-482 /api/resolve returns the direct upstream URL immediately without any download; PlayerManager.swift:581-583,608 starts AVPlayer on that URL, removing the single-long-request failure mode for the default (non-EQ) path. |
| ⬜ open | high | S | Eliminate Render free-tier cold-start stall on first play | No /api/health warm-keep ping anywhere in App/Managers/Services (grep empty); client timeouts unchanged at 15s/60s (PlayerManager.swift:169-170, AriaApp.swift:44-45) with no 'waking up' state; backend still cold-indexes cache on startup (app.py:48-62). |
| ⬜ open | medium | S | Cut search latency by fetching fewer results and dropping fields the client never uses | backend/app.py:209 still ytsearch25 (no N env var) and app.py:219 still projects duration, while client decoder (YouTubeSearchService.swift:60-64) still omits duration entirely. |
| ⬜ open | medium | M | Prefetch/warm the next queued track's stream so gapless and next-track latency disappears | No audio prefetch/prewarm of the next queue item (grep for prefetch/preResolve/preload empty); refillRadio (PlayerManager.swift:476-543) only fetches radio metadata, and there is no /api/prefetch or pre-resolve of the upcoming track. |
| 🟡 partial | medium | M | Pin/standardize the yt-dlp player_client and cache resolved format URLs to avoid repeated heavy extraction | Fallback chain added (app.py:45 _YTDL_PLAYER_CLIENTS=['android_vr','ios','tv_embedded','web']) and node path now env-configurable (app.py:150 NODE_PATH); but no resolved-format-URL cache — _resolve_sync (app.py:226-259) re-runs full extraction+JS on every call. |

## iOS — UX, Architecture & Accessibility

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ⬜ open | high | M | Throttle and isolate the per-frame currentTime updates that re-render the entire app | PlayerManager.swift still has 11 @Published on one object (:12-27); startTimeDisplayLink (:963-967) sets no preferredFramesPerSecond; pollEngineTime (:969-977) writes @Published currentTime every tick; no PlaybackClock split exists and all 10 views still hold @EnvironmentObject playerManager. |
| 🟡 partial | high | M | Downsample artwork to display size instead of decoding full 1280x720 JPEGs for thumbnails | Views/Shared/AsyncCachedImage.swift now decodes via CGImageSourceCreateThumbnailAtIndex with kCGImageSourceThumbnailMaxPixelSize/CreateThumbnailFromImageAlways/ShouldCacheImmediately (downsampledImage(data:maxPixelSize:), ~line 183), driven by a new `targetSize` (pt) param × UIScreen.scale; in-memory cache now keys by URL+pixel-bucket (ImageCacheKey) so different call sites (36pt mini-player vs 290pt full-screen) don't collide; all Views/** call sites updated to pass real frame sizes. Still open: YouTubeThumbnailRewriter.swift:42 (out of this lane's write-set) unconditionally upgrades to maxresdefault before download regardless of targetSize, so the *download* size isn't reduced yet — only the *decode*. |
| ✅ done | low | S | Artwork placeholder is a blank grey rectangle, not a recognizable icon, for both loading and failed states | Added shared `ArtworkPlaceholder` (Views/Shared/ArtworkPlaceholder.swift): a themed `tokens.dividerColor` fill with a centered `music.note` SF Symbol sized as a fraction (0.38) of the container's shorter side via GeometryReader, so it scales correctly from 36pt (mini-player) to 290pt (full-screen) without per-call-site tuning; marked `.accessibilityHidden(true)` since the surrounding row/track carries the label. `AsyncCachedImage`'s default placeholder param is now `ArtworkPlaceholder()` (was `ShimmerView()`), and its body shows the same placeholder for both the loading and `didFail` states (previously `didFail` rendered a separate hardcoded gray+photo-icon ZStack), so any call site that omits a placeholder gets the icon on both paths. Routed through it: MiniPlayerView (was `Rectangle().fill(.gray.opacity(0.3))`, now has a `themeManager` EnvironmentObject), FullScreenPlayerView (was `Rectangle().fill(themeManager.dividerColor)`), TrackThumbnail (was `ShimmerView`, now takes an optional `tokens` param plumbed from all 6 call sites: FavoritesView/PlaylistDetailView/PlaylistsView/QueueView/SearchView×2), LibraryTrackRow (replaced its own hand-rolled ZStack+RoundedRectangle+Image.note with the shared view), and the two playlist preview-artwork `AsyncCachedImage` placeholders in PlaylistsView/PlaylistDetailView (the separate "no playlist preview at all" `music.note.list` gradient fallback in those same views was left as-is — different semantic, not an image-load placeholder). Added `ThemeManager.fallbackTokens` static for parameterless defaults. New `Tests/ArtworkPlaceholderTests.swift` (5 tests) covers instantiation and rendering at mini-player/library-row/full-screen sizes plus the fallback-tokens sanity check; full `AriaTests` suite passes (238 executed, 2 skipped integration tests, 0 failures). |
| ⬜ open | high | L | Support Dynamic Type — the entire app uses fixed-point fonts that never scale | DS.Typography (DesignSystem.swift:22-30) is all Font.system(size:) with no relativeTo:; grep for ScaledMetric/dynamicTypeSize/sizeCategory across Views/Models/Managers returns no matches (only stray .font(.body/.caption) literals). |
| 🟡 partial | high | M | Make the custom seek slider, transport, and now-playing state accessible to VoiceOver and honor reduce-motion | Transport buttons have accessibilityLabels (FullScreenPlayerView.swift:194-222) but seek Slider (:161) still has no accessibilityValue/label, rows have no .accessibilityElement(.combine), NowPlayingIndicator (TrackRow.swift:26) still repeatForever with no accessibilityHidden, and accessibilityRed… |
| ⬜ open | medium | M | Library list uses ScrollView+LazyVStack and recomputes sort/group every body pass | LibraryView.swift:225-227 still ScrollView{LazyVStack{ForEach(vm.sections)}}, passes playerManager.isPlaying into rows (:233); LibraryViewModel.swift still exposes computed var filteredAndSortedTracks (:68) and var sections (:82), not cached @Published. |
| ⬜ open | medium | L | No iPad / landscape adaptation — phone-only layout with hard-coded widths | grep for horizontalSizeClass/NavigationSplitView/GridItem(.adaptive across Views/ returns no matches; full-screen player artwork still fixed side=290 (FullScreenPlayerView.swift:117). |
| ⬜ open | medium | M | Custom drag-to-dismiss full-screen player drops native sheet behavior and accessibility | ContentView still toggles @State showFullPlayer (:13,33,106) with .transition(.move(edge:.bottom)) (:47); FullScreenPlayerView still attaches a whole-view DragGesture on .offset(y:dragOffset) (:83-99) with no velocity/rubber-banding, no fullScreenCover/presentationDetents. |
| ⬜ open | low | S | Verify color-token contrast meets WCAG and add differentiate-without-color fallbacks | ThemeManager.swift:66-68 textSecondary still Color(white:0.62) in dark mode (~4.3:1); state still color-only (FavoritesView accent row, shuffle/repeat accent) and no accessibilityDifferentiateWithoutColor usage exists in Views/. |

## iOS — Data, Queue & Persistence

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | S | Fix AtomicFileWriter so it actually overwrites — every save after the first silently fails | Services/AtomicFileWriter.swift:8-10 now uses data.write(to:options:.atomic) (overwrite-safe); moveItem is gone; KeyValueStore.swift:44 and LocalLibraryManager.swift:140,378 route through it. |
| ✅ done | high | M | Persist the playback queue (and now-playing track + position) across launches | #10: Models/PersistedPlayback.swift + debounced playback_state.json restore currentTrack+queue+position into a paused state (PlayerManager); first play resumes from saved position, never auto-resumes. |
| ✅ done | high | S | Shrink the crash data-loss window — debounced writes only become durable on backgrounding | #10: all debounced stores (incl. PlayerManager) now flush on UIApplication.willTerminate (App/AriaApp.swift), not just scenePhase background/inactive. |
| ✅ done | high | M | Add schema versioning + migration to every JSON store before the model evolves | #10: Services/VersionedStore.swift (VersionedEnvelope {schemaVersion, items}) wraps every store (favorites/playlists/recently-played×2/local library); legacy bare-array files migrate in place on first load; undecodable bytes quarantined to a .corrupt- sibling instead of try?-dropped. |
| ⬜ open | medium | M | Stop discarding track duration/album when a track is saved into a playlist or recents | Models/Track.swift:3-17 still carries only id/title/artist/thumbnailURL/localFileURL/isMissing; LocalTrack.asPlayerTrack (LocalTrack.swift:50-58) drops durationSeconds/album on conversion. |
| ✅ done | medium | M | Local/offline tracks show no artwork — embedded cover art is not reliably extracted | Fixed on feat/data-local-artwork in TWO parts. **(A) Broadened extraction:** LocalLibraryManager.extractArtwork delegates to `loadArtworkData(from:)` (generic over a new `MetadataLoading` protocol; `AVURLAsset` conforms via an adapter extension) which tries (1) the common-identifier artwork item filtered from the asset's full `.metadata` set + a broader identifier/key heuristic, (2) every format-specific set via `availableMetadataFormats`/`loadMetadata(for:)` (ID3 `APIC`, iTunes `covr`, QuickTime/ISO user data), (3) the legacy `.commonMetadata`/`commonKey=="artwork"` fallback — coercing non-`dataValue` payloads via `.value`; magic-byte sniffing extended to GIF. **(B) ROOT CAUSE of device-observed blank artwork — stale absolute paths:** artwork was persisted as an ABSOLUTE `URL` in `LocalTrack.artworkURL`, which dangles after the app Data-container UUID changes on reinstall/dev-rebuild (audio survived because it's resolved by file name at access time). Fix mirrors audio: `LocalTrack` now stores a stable relative `artworkFileName` (bare `<uuid>.<ext>`); a custom `Codable init(from:)` migrates legacy absolute `artworkURL` entries (URL or raw-string form) by keeping only the last path component, and `encode(to:)` never writes the legacy key. Schema bumped to v2. Absolute paths are re-derived at access time via `LocalLibraryManager.artworkURL(for:)` (against the current libraryDirectory) and a container-resolved computed `LocalTrack.artworkURL` (keeps existing View read-sites + `asPlayerTrack` working with no out-of-lane edits). **(C) Self-heal:** on init, `healMissingArtwork()` re-extracts artwork from the still-present audio file for any track whose resolved artwork file is gone (best-effort, debounced, non-blocking), recovering the user's existing tracks across rebuilds. Coverage: Tests/LocalLibraryManagerTests.swift — 9 extraction/selection tests plus new tests for legacy-URL→fileName migration (URL + raw-string), relative-only persistence round-trip, `artworkURL(for:)` resolution against the injected dir (and that it follows the dir across two managers), and self-heal via an injected artwork-data loader seam (re-extracts when present, no-op + no crash when absent, skips when already on disk). No binary audio fixtures added. Full AriaTests suite: 233 tests, 0 failures (2 skipped live-integration tests). |
| ⬜ open | medium | S | Add playlist track reordering (and queue reordering) — the data model supports it but no UI/manager path exists | PlaylistsManager has no move/reorder func (only removeTrack at :63); grep for onMove/EditButton/moveInQueue in PlaylistDetailView.swift and QueueView.swift returns nothing. |
| ⬜ open | medium | L | No cross-device sync and no playlist export/import — library is trapped on one device | No CloudKit/NSUbiquitous; the only iCloud refs are import-source checks (ImportError.swift:20, LibraryView.swift:282); the one ShareLink (FullScreenPlayerView.swift:263) shares the track thumbnail URL, not a playlist export. |

## iOS — Networking & Offline

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ⬜ open | critical | M | Add cold-start detection and retry/backoff so Render spin-up doesn't fail playback and search | PlayerManager.defaultURLSession() still hard-codes timeoutIntervalForRequest=15 / forResource=60 (PlayerManager.swift:168-170) and YouTubeSearchService uses default timeouts (YouTubeSearchService.swift:6-16); no retry/backoff on /api/play, /api/resolve, or /api/search; no /api/health warm-up ping… |
| 🟡 partial | critical | M | Surface stream-fetch failures to the user instead of silently going idle | handleFetchError() now sets playerError=.streamFailed(error) (PlayerManager.swift:618-620) and ContentView shows a 4s toast on .streamFailed (ContentView.swift:74-82) — the silent-idle fetch path is fixed. But the AVPlayerItem .failed branch still only sets playbackState=.idle and nils the URL wi… |
| ⬜ open | high | L | Add client-side offline download of YouTube tracks (the backend already has the audio file) | No offline-download feature exists: grep for downloadForOffline/offlineDownload/downloads manifest returns nothing; EQ path still caches into purgeable .cachesDirectory via EQCache, and the no-EQ path streams /api/resolve and persists nothing (PlayerManager.swift:561-609). play(_:) only prefers l… |
| 🟡 partial | high | S | Stop buffering entire audio files in memory byte-by-byte in downloadWithProgress | URLSessionProtocols.swift:75-100 now flushes to disk in 64KB chunks via FileHandle (memory blow-up fixed), but still iterates session.bytes(from:) one byte at a time with chunk.append(byte) and received += 1 per byte (lines 92-98) — the per-byte AsyncBytes CPU cost and lack of downloadTask/URLSes… |
| ⬜ open | medium | M | Unify networking into one configured session/layer instead of three divergent clients | Still three+ divergent clients: PlayerManager/StreamResolver/RadioService/NowPlaying share the pinned 15/60s session, but YouTubeSearchService builds its own URLSession with default timeouts and NO TLSPinningDelegate (YouTubeSearchService.swift:6-16) and AsyncCachedImage uses URLSession.shared (A… |
| ⬜ open | medium | M | Add network reachability so the app can show offline state and pre-empt doomed requests | No reachability anywhere — grep for NWPathMonitor / import Network / Reachability across the worktree's Swift sources returns nothing. Every play/search still blindly fires and waits out the configured timeout to discover offline. |
| ⬜ open | medium | S | Distinguish and handle HTTP 429 rate-limit responses from the backend on the client | Backend still returns bare 429 with no Retry-After header (app.py:95-110). Client lumps all non-2xx into StreamResolverError.serverError (StreamResolver.swift:94-99) and >=400 into ServiceError.serverError(rawBody) (YouTubeSearchService.swift:54-58); no statusCode==429 branch, no Retry-After pars… |

## iOS — System Integration

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ⬜ open | high | S | Stop mixing with other audio — a music player must interrupt/duck, not coexist | Still [.mixWithOthers]: AriaApp.swift:21-22 and NowPlayingService.swift:103; no routeSharingPolicy(.longFormAudio) anywhere. |
| ⬜ open | high | XL | Add CarPlay support (CPNowPlayingTemplate + browsing) — major reach gap | grep for CarPlay/CPNowPlaying/CPTemplate returns nothing; find for *.entitlements returns empty in the worktree. |
| 🟡 partial | high | M | Now Playing elapsed time freezes on the lock screen while backgrounded | updateNowPlaying() now sets Elapsed+Rate+Duration on most transitions (play/seek/togglePlayPause), giving the system an extrapolation anchor, but no MPNowPlayingInfoCenter.playbackState or MPNowPlayingInfoPropertyMediaType is set and pause() (PlayerManager.swift:343-351) never pushes an update. |
| ✅ done | medium | M | Disable/enable next/prev remote commands to match queue state, and remove the no-op previousTrack | NowPlayingService.swift:95-96 still addTargets next/prev with no .isEnabled; previousTrack() (PlayerManager.swift:505-507) is still a seek(to:0) no-op; no play-history stack, no changeRepeatMode/changeShuffleMode/skip commands. |
| ✅ done | medium | S | Wire a Like/Favorite remote command into Now Playing (data already exists) | NowPlayingService.configureRemoteCommands() (lines 82-97) registers no likeCommand/dislikeCommand and FavoritesManager is not injected into the service. |
| ⬜ open | medium | S | Interruption-ended resume uses togglePlayPause() and never re-activates the session | handleInterruption .ended still calls togglePlayPause() (PlayerManager.swift:206) with no activateAudioSession() re-activation and no wasPlayingBeforeInterruption guard. |
| ⬜ open | medium | L | Add Siri/App Intents + Shortcuts so users can voice-control and automate Aria | grep for AppIntent/SiriKit/INPlayMedia/NSUserActivity/AppShortcutsProvider returns nothing across the worktree. |
| ⬜ open | low | L | Add a Now Playing Live Activity and a home-screen widget | grep for WidgetKit/ActivityKit/LiveActivity/ActivityAttributes returns nothing; no widget extension target exists. |

## Quality — Testing & Observability

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | M | Add CI for iOS tests and backend on every push/PR | `.github/workflows/ci.yml`: `backend` job (ubuntu) runs `py_compile` + `pytest`; `ios` job (macos) runs `xcodebuild test -scheme AriaTests`. Triggers on push to main + all PRs; concurrency-cancels superseded runs. NOTE: the iOS job (runner Xcode/sim names) is unverified on hosted runners — may need a label/version tweak on first run. |
| ✅ done | critical | M | Backend has zero automated tests despite owning all playback-critical logic | `backend/tests/test_app.py` — 44 pytest/TestClient cases covering eviction, rate limiting, single-flight download, retry classification, video_id validation, file validation, disk guard, node detection, persisted LRU, metrics, and `/api/resolve`+`/api/radio`+`/api/health`. All green locally. |
| ⬜ open | high | M | No shared iOS↔backend contract; decoders silently drift from the server | Backend search returns duration (app.py:219) but SearchResult still omits it (YouTubeSearchService.swift:60-65); no golden-fixture decode tests exist and live tests still XCTSkip on placeholder host. |
| 🟡 partial | high | M | Streamed-playback failures are invisible to the user and to any monitor | handleFetchError now sets playerError=.streamFailed (PlayerManager.swift:619) and ContentView shows a 4s toast (ContentView.swift:74), but AVPlayerPath .failed branch (AVPlayerPath.swift:74-78) still only sets .idle with no playerError, there's no Retry affordance, and no MetricKit/telemetry/anal… |
| ✅ done | high | M | Backend uses bare print() with no structured logging, request IDs, or latency metrics | `logging` configured; `observability_middleware` stamps a 12-char `X-Request-ID`, logs `rid/ip/method/path/status/ms`, and feeds `_record_metric`; `/api/metrics` exposes p50/p95 + `failures_by_reason`; all `print()` removed. Covered by `test_request_id_header_present` / `test_metrics_endpoint_tracks_requests`. |
| ✅ done | medium | S | No health alerting or uptime monitoring on the Render backend | `healthcheck.sh` probes `/api/health`, alerts via `ARIA_ALERT_WEBHOOK` on down/degraded/high-error-rate; `aria-healthcheck.timer` runs it every 5 min. README recommends running it off-box (or an external monitor) since a down host can't probe itself. `/api/health` now emits the signals a monitor needs (status, versions, error_rate). |
| ⬜ open | medium | S | Test suite has no coverage gating and key network/error paths are untested in unit tests | No .xctestplan exists and no codeCoverage in any scheme; no dedicated StreamResolver/YouTubeSearchService error-path unit tests in Tests/ (StreamResolver referenced only by PlayerManagerTests). |
| ⬜ open | low | S | Live integration tests carry a stale/incorrect skip reason, masking that the contract path is unverified | AriaTests-Info.plist still sets NSAllowsArbitraryLoads (:21-23) yet the stale 'test bundle enforces ATS' comment/XCTSkip persists at YouTubeSearchServiceTests.swift:29-33 and TLSPinningDelegateTests.swift:193-197; real guard is the ARIA_HOMELAB_HOST placeholder. |

## Product — Feature Gaps

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | S | Make collections auto-fill the queue for continuous playback | All collection entry points now seed the queue: Search uses playRadio (SearchView.swift:240,338,370), Favorites uses playSlice (FavoritesView.swift:70,138), Playlists use playSlice (PlaylistDetailView.swift:128,137,205); playNextInQueue auto-advances (PlayerManager.swift:524-545). |
| ✅ done | high | M | Wire up the Sleep Timer (setting is persisted but never fires) | MoreView.swift:222 onChange only calls Haptics.selection()+settingsManager.save(); no scheduledTimer/asyncAfter/Task.sleep ever reads sleepTimer to pause playback — the setting still does nothing. |
| ✅ done | high | M | Implement Repeat-All (queue does not loop) | playNextInQueue on an empty queue with repeatMode != .off still only replays currentTrack (PlayerManager.swift:524-535); no original-collection is stored to re-seed and loop, and repeatIcon returns 'repeat' for both .off and .all (FullScreenPlayerView.swift:227-233). |
| ✅ done | high | M | Add a play history so Previous-track works | previousTrack() is still a no-op that just calls seek(to:0) with a TODO; no play-history stack exists in PlayerManager (PlayerManager.swift:500-507). |
| ✅ done | high | M | Implement real shuffle (button currently does nothing) | 'Shuffle Play' buttons now call playSlice(tracks.shuffled()) (FavoritesView.swift:68-70, PlaylistDetailView.swift:135-137), but the in-player shuffle toggle is still just toggleShuffle(){isShuffled.toggle()} (PlayerManager.swift:404) and isShuffled is never read by playSlice/playNextInQueue, so t… |
| ⬜ open | medium | M | Enable queue reordering and playlist reordering (drag to reorder) | QueueView still only has .onDelete and tap-to-play index 0 (QueueView.swift:90-130), no .onMove; PlaylistsManager has no move/reorder method (only create/delete/rename/add/removeTrack) and PlaylistDetailView has no .onMove. |
| ⬜ open | medium | S | Add 'Save Queue as Playlist' and add-collection-to-queue | QueueView toolbar still only offers Done/Clear (QueueView.swift:29-43); no saveQueue/queueAsPlaylist action and no bulk 'add collection to queue / play next' anywhere — grep returns nothing. |
| ⬜ open | medium | M | Add variable playback speed control | No rate/defaultRate is ever set and no AVAudioUnitTimePitch in the engine graph; AVPlayer .rate is only observed for isPlaying (AVPlayerPath.swift:61-66), and no speed picker exists in FullScreenPlayerView. |
| ⬜ open | medium | M | Add track duration to the model and show it in lists/rows | Track.swift still has no duration field (id/title/artist/thumbnailURL/localFileURL/isMissing only); StreamResolver decodes a duration but only for DASH capping, never stored on Track; Search/Favorites/Queue rows show no length. (Only local LibraryTrackRow shows durationSeconds, pre-existing.) |
| ⬜ open | low | S | Add a first-run onboarding / empty-state guidance flow | No onboarding/firstLaunch/hasOnboarded/welcome/tutorial code anywhere in Managers/Views/App — grep returns nothing; new users still land on the empty default tab with no guidance. |
