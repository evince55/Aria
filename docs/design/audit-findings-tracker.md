# Aria — Audit Findings Tracker

Source: the initial multi-agent "ultracode" sweep (96 agents, ~4.4M tokens, 85 verified findings), re-verified against the **current** code on 2026-06-27 by an 11-agent status pass (one per dimension).

**Status: 9 done · 15 partial · 61 open** (of 85). Status reflects the `feat/progressive-radio` branch (stacked on the EQ fixes) + deployed `backend/app.py`.

Legend: ✅ done · 🟡 partial · ⬜ open. Severity from the original sweep. "Evidence" is the verifier's current-code justification.

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
| ⬜ open | medium | L | Implement real previous-track and gapless/crossfade transitions | previousTrack() is still just seek(to: 0) with a TODO acknowledging the no-op (PlayerManager.swift:500-507); no play-history stack exists (grep finds none). playNextInQueue still destructively removeFirst (537) and play() calls stopAllPlayback (272,302,1035) — hard cuts, no overlap/crossfade. |

## Backend — Cache & Reliability

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | M | Add a multi-client yt-dlp fallback chain instead of a single android_vr client | _YTDL_PLAYER_CLIENTS = ["android_vr","ios","tv_embedded","web"] is now an ordered fallback list passed to both _download_sync (app.py:149) and _resolve_sync (app.py:236); search uses extract_flat with no stream extraction so it doesn't need it. |
| ⬜ open | high | S | Persist LRU access metadata to disk so eviction survives restarts | _stream_access_times is still in-memory only (app.py:69); lifespan recomputes only _total_cache_bytes not access times (app.py:48-63); eviction still uses _stream_access_times.get(vid, 0) (app.py:315) so all files read as epoch-0 after restart. |
| ⬜ open | high | S | Pin and auto-update yt-dlp rather than leaving it unversioned | requirements.txt:3 still lists bare 'yt-dlp' with no pin; no update cron/timer or self-update wired; /api/health (app.py:524-534) does not surface the yt-dlp version. |
| ⬜ open | high | M | Validate downloaded files and clean up partial/corrupt artifacts before serving | post-download path just adds cached.stat().st_size (app.py:387-393) with no size/ffprobe integrity check; _find_cached_file (app.py:295-296) still returns matches[0] without skipping .part/zero-byte files; no temp-file sweep in lifespan. (download_ranges/MAX_DURATION/max_filesize are pre-download… |
| 🟡 partial | high | S | Stop hard-coding the node binary path; detect it or make it configurable | js_runtimes node path is now os.environ.get("NODE_PATH", "/usr/bin/node") in all three callers (app.py:150,206,237) — env-configurable, but still defaults to a hard-coded /usr/bin/node with no shutil.which fallback and no startup/health check. |
| 🟡 partial | high | M | Serialized single-download semaphore collides with the client's 15s request timeout | download concurrency raised from 1 to env-tunable DOWNLOAD_CONCURRENCY=2 (app.py:74) and new /api/resolve returns a direct stream URL without downloading (app.py:457-482), which the non-EQ client path now uses (PlayerManager.swift:581); but the engine//api/play path still does a full serialized d… |
| ⬜ open | medium | M | Make the cache key include format/quality, not just video_id | outtmpl is still %(id)s.%(ext)s (app.py:148) and _find_cached_file still globs {video_id}.* returning matches[0] (app.py:295-296) — no format/version discriminator, no deterministic .m4a preference or size validation. |
| ⬜ open | medium | M | Add disk-full handling and structured failure observability | eviction still keys off _total_cache_bytes not shutil.disk_usage (app.py:307); no free-space precheck before download; failures are still print() + generic HTTPException(500) (app.py:382); /api/health (app.py:524-534) reports only counts/sizes/access_tracked, no failure metrics, yt-dlp version, o… |

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
| ⬜ open | high | M | Downsample artwork to display size instead of decoding full 1280x720 JPEGs for thumbnails | AsyncCachedImage.swift still decodes via UIImage(data:) (:99) with no CGImageSourceCreateThumbnail/downsampling, stores full-size cost (:22-23); rewriter still upgrades to maxresdefault first (YouTubeThumbnailRewriter.swift:42) with no per-call target size. |
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
| ⬜ open | high | M | Persist the playback queue (and now-playing track + position) across launches | PlayerManager.queue is still a bare @Published [Track] (PlayerManager.swift:26); no QueueStore/Debouncer/flushPendingWrites in PlayerManager, and ContentView scenePhase flush list (ContentView.swift:94-97) omits playerManager. |
| ⬜ open | high | S | Shrink the crash data-loss window — debounced writes only become durable on backgrounding | ContentView.swift:92-97 still flushes only on .background/.inactive; no UIApplication.willTerminateNotification/willResignActive observer and no synchronous performSave for high-value mutations (grep: no hits). |
| ⬜ open | high | M | Add schema versioning + migration to every JSON store before the model evolves | grep for schemaVersion/migrat returns nothing in Managers/Models/Services; stores still encode bare arrays and there is no .corrupt/backup-on-failure path (grep: no hits). |
| ⬜ open | medium | M | Stop discarding track duration/album when a track is saved into a playlist or recents | Models/Track.swift:3-17 still carries only id/title/artist/thumbnailURL/localFileURL/isMissing; LocalTrack.asPlayerTrack (LocalTrack.swift:50-58) drops durationSeconds/album on conversion. |
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
| ⬜ open | medium | M | Disable/enable next/prev remote commands to match queue state, and remove the no-op previousTrack | NowPlayingService.swift:95-96 still addTargets next/prev with no .isEnabled; previousTrack() (PlayerManager.swift:505-507) is still a seek(to:0) no-op; no play-history stack, no changeRepeatMode/changeShuffleMode/skip commands. |
| ⬜ open | medium | S | Wire a Like/Favorite remote command into Now Playing (data already exists) | NowPlayingService.configureRemoteCommands() (lines 82-97) registers no likeCommand/dislikeCommand and FavoritesManager is not injected into the service. |
| ⬜ open | medium | S | Interruption-ended resume uses togglePlayPause() and never re-activates the session | handleInterruption .ended still calls togglePlayPause() (PlayerManager.swift:206) with no activateAudioSession() re-activation and no wasPlayingBeforeInterruption guard. |
| ⬜ open | medium | L | Add Siri/App Intents + Shortcuts so users can voice-control and automate Aria | grep for AppIntent/SiriKit/INPlayMedia/NSUserActivity/AppShortcutsProvider returns nothing across the worktree. |
| ⬜ open | low | L | Add a Now Playing Live Activity and a home-screen widget | grep for WidgetKit/ActivityKit/LiveActivity/ActivityAttributes returns nothing; no widget extension target exists. |

## Quality — Testing & Observability

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ⬜ open | critical | M | Add CI for iOS tests and backend on every push/PR | No CI anywhere: find for .github/.yml/.yaml/Fastfile/render.yaml/Procfile/Dockerfile in worktree and root returns nothing; tests still run only by hand. |
| ⬜ open | critical | M | Backend has zero automated tests despite owning all playback-critical logic | `find backend -name '*test*'` (excluding .venv) returns nothing; rate-limiter, eviction, single-flight, retry classifier in app.py remain untested. |
| ⬜ open | high | M | No shared iOS↔backend contract; decoders silently drift from the server | Backend search returns duration (app.py:219) but SearchResult still omits it (YouTubeSearchService.swift:60-65); no golden-fixture decode tests exist and live tests still XCTSkip on placeholder host. |
| 🟡 partial | high | M | Streamed-playback failures are invisible to the user and to any monitor | handleFetchError now sets playerError=.streamFailed (PlayerManager.swift:619) and ContentView shows a 4s toast (ContentView.swift:74), but AVPlayerPath .failed branch (AVPlayerPath.swift:74-78) still only sets .idle with no playerError, there's no Retry affordance, and no MetricKit/telemetry/anal… |
| 🟡 partial | high | M | Backend uses bare print() with no structured logging, request IDs, or latency metrics | Failure causes now map to honest status codes (429/401/400/404/502 in app.py), but no `import logging`, no middleware, no request_id, no latency/counters, /api/metrics absent, and print() remains at app.py:61,192,332 with /api/play still 500. |
| ⬜ open | medium | S | No health alerting or uptime monitoring on the Render backend | No render.yaml/Procfile in repo, no uptime check polling /api/health, and aria-backend.service has Restart=always (:14) but no WatchdogSec. |
| ⬜ open | medium | S | Test suite has no coverage gating and key network/error paths are untested in unit tests | No .xctestplan exists and no codeCoverage in any scheme; no dedicated StreamResolver/YouTubeSearchService error-path unit tests in Tests/ (StreamResolver referenced only by PlayerManagerTests). |
| ⬜ open | low | S | Live integration tests carry a stale/incorrect skip reason, masking that the contract path is unverified | AriaTests-Info.plist still sets NSAllowsArbitraryLoads (:21-23) yet the stale 'test bundle enforces ATS' comment/XCTSkip persists at YouTubeSearchServiceTests.swift:29-33 and TLSPinningDelegateTests.swift:193-197; real guard is the ARIA_HOMELAB_HOST placeholder. |

## Product — Feature Gaps

| Status | Sev | Effort | Finding | Evidence (current code) |
|---|---|---|---|---|
| ✅ done | critical | S | Make collections auto-fill the queue for continuous playback | All collection entry points now seed the queue: Search uses playRadio (SearchView.swift:240,338,370), Favorites uses playSlice (FavoritesView.swift:70,138), Playlists use playSlice (PlaylistDetailView.swift:128,137,205); playNextInQueue auto-advances (PlayerManager.swift:524-545). |
| ⬜ open | high | M | Wire up the Sleep Timer (setting is persisted but never fires) | MoreView.swift:222 onChange only calls Haptics.selection()+settingsManager.save(); no scheduledTimer/asyncAfter/Task.sleep ever reads sleepTimer to pause playback — the setting still does nothing. |
| ⬜ open | high | M | Implement Repeat-All (queue does not loop) | playNextInQueue on an empty queue with repeatMode != .off still only replays currentTrack (PlayerManager.swift:524-535); no original-collection is stored to re-seed and loop, and repeatIcon returns 'repeat' for both .off and .all (FullScreenPlayerView.swift:227-233). |
| ⬜ open | high | M | Add a play history so Previous-track works | previousTrack() is still a no-op that just calls seek(to:0) with a TODO; no play-history stack exists in PlayerManager (PlayerManager.swift:500-507). |
| 🟡 partial | high | M | Implement real shuffle (button currently does nothing) | 'Shuffle Play' buttons now call playSlice(tracks.shuffled()) (FavoritesView.swift:68-70, PlaylistDetailView.swift:135-137), but the in-player shuffle toggle is still just toggleShuffle(){isShuffled.toggle()} (PlayerManager.swift:404) and isShuffled is never read by playSlice/playNextInQueue, so t… |
| ⬜ open | medium | M | Enable queue reordering and playlist reordering (drag to reorder) | QueueView still only has .onDelete and tap-to-play index 0 (QueueView.swift:90-130), no .onMove; PlaylistsManager has no move/reorder method (only create/delete/rename/add/removeTrack) and PlaylistDetailView has no .onMove. |
| ⬜ open | medium | S | Add 'Save Queue as Playlist' and add-collection-to-queue | QueueView toolbar still only offers Done/Clear (QueueView.swift:29-43); no saveQueue/queueAsPlaylist action and no bulk 'add collection to queue / play next' anywhere — grep returns nothing. |
| ⬜ open | medium | M | Add variable playback speed control | No rate/defaultRate is ever set and no AVAudioUnitTimePitch in the engine graph; AVPlayer .rate is only observed for isPlaying (AVPlayerPath.swift:61-66), and no speed picker exists in FullScreenPlayerView. |
| ⬜ open | medium | M | Add track duration to the model and show it in lists/rows | Track.swift still has no duration field (id/title/artist/thumbnailURL/localFileURL/isMissing only); StreamResolver decodes a duration but only for DASH capping, never stored on Track; Search/Favorites/Queue rows show no length. (Only local LibraryTrackRow shows durationSeconds, pre-existing.) |
| ⬜ open | low | S | Add a first-run onboarding / empty-state guidance flow | No onboarding/firstLaunch/hasOnboarded/welcome/tutorial code anywhere in Managers/Views/App — grep returns nothing; new users still land on the empty default tab with no guidance. |
