import asyncio
import json
import logging
import os
import random
import re
import shutil
import subprocess
import time
import urllib.parse
import urllib.request
import uuid
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional
from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse
import yt_dlp
from yt_dlp.utils import match_filter_func

# ---------------------------------------------------------------------------
# Structured logging
# ---------------------------------------------------------------------------
# Bare print() gives no severity, no request correlation, and no machine-
# parseable shape. A real LLMOps backend needs to answer "which request, how
# long, why did it fail" from logs alone. Every log line below carries a
# request_id (see the middleware) so a single play can be traced end-to-end.
logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("aria")

CACHE_DIR = Path("./song_cache")
CACHE_DIR.mkdir(exist_ok=True)

MAX_CACHE_GB = float(os.environ.get("MAX_CACHE_GB", "2"))
CACHE_EVICT_GRACE_SECONDS = float(os.environ.get("CACHE_EVICT_GRACE_SECONDS", "300"))
YTDL_SOCKET_TIMEOUT = int(os.environ.get("YTDL_SOCKET_TIMEOUT", "15"))

# Reject pathologically long videos (DJ mixes, hour-long compilations) and
# live streams *before* downloading. The full-download model means one such
# video occupies a download-semaphore slot for many minutes; a few skipped in
# a row saturate all slots and every other /api/play times out. The filter
# runs on extracted metadata, so it costs nothing — no bytes are fetched.
MAX_DURATION_SECONDS = int(os.environ.get("MAX_DURATION_SECONDS", "900"))  # 15 min
# Hard byte ceiling as a backstop in case duration metadata is missing.
MAX_FILESIZE_BYTES = int(os.environ.get("MAX_FILESIZE_MB", "60")) * 1024 * 1024

# A freshly-downloaded audio file smaller than this is almost certainly a
# truncated/aborted download or an error page — never serve it.
MIN_VALID_FILE_BYTES = int(os.environ.get("MIN_VALID_FILE_BYTES", "16384"))  # 16 KB

# Refuse to start a download when free disk would drop below this headroom.
# Prevents the cache directory from filling the disk and taking the whole box
# (and the systemd unit) down with it. Default = 2x the per-file ceiling.
MIN_FREE_DISK_BYTES = int(
    os.environ.get("MIN_FREE_DISK_BYTES", str(MAX_FILESIZE_BYTES * 2))
)

RATE_LIMIT_WINDOW_SECONDS = 60
RATE_LIMIT_PLAY_PER_MIN = int(os.environ.get("RATE_LIMIT_PLAY_PER_MIN", "60"))
RATE_LIMIT_SEARCH_PER_MIN = int(os.environ.get("RATE_LIMIT_SEARCH_PER_MIN", "30"))
RATE_LIMIT_CACHE_PER_MIN = int(os.environ.get("RATE_LIMIT_CACHE_PER_MIN", "5"))
RATE_LIMIT_COVER_PER_MIN = int(os.environ.get("RATE_LIMIT_COVER_PER_MIN", "30"))
# Cap on distinct rate-limit keys held in memory. Without this the per-IP
# request log is an unbounded dict — a stream of distinct (or spoofed) client
# IPs grows it without limit (memory-exhaustion DoS). Evicted oldest-first.
RATE_LIMIT_MAX_KEYS = int(os.environ.get("RATE_LIMIT_MAX_KEYS", "10000"))
# Number of trusted reverse proxies in front of this app. X-Forwarded-For is
# client-controllable, so only the rightmost N hops — the ones our own proxies
# appended — are trustworthy. 0 (the default, and correct for the direct
# Tailscale homelab path) means ignore XFF entirely and use the socket peer.
# Set to 1 behind a single proxy (e.g. Render) so the real client is read.
TRUSTED_PROXY_COUNT = int(os.environ.get("TRUSTED_PROXY_COUNT", "0"))

# Auth: set ARIA_API_KEY in the environment to require X-API-Key (or Bearer) on
# /api/play, /api/search, and DELETE /api/cache. Leave unset to disable auth
# (the default, so local dev and existing clients keep working).
ARIA_API_KEY: str = os.environ.get("ARIA_API_KEY", "")

# youtube video IDs are exactly 11 URL-safe base64 characters.
_VIDEO_ID_RE = re.compile(r'^[A-Za-z0-9_-]{11}$')

# yt-dlp player clients tried in order. android_vr is fastest when it works;
# fallbacks kick in automatically when YouTube breaks a client.
_YTDL_PLAYER_CLIENTS = ["android_vr", "ios", "tv_embedded", "web"]

# Cache key discriminator. The cache used to glob "{id}.*" and return an
# arbitrary match, so two formats for one video collided and matches[0] was
# nondeterministic. Tagging the on-disk name with the requested format profile
# makes the key format-aware and the lookup deterministic.
AUDIO_FORMAT_TAG = os.environ.get("AUDIO_FORMAT_TAG", "bestaudio")

# Deterministic preference when several extensions exist for one key. m4a is
# what the iOS client wants (AAC in an MP4 container); others are fallbacks.
_EXT_PREFERENCE = [".m4a", ".mp4", ".webm", ".ogg", ".opus"]

# Junk produced by interrupted yt-dlp/ffmpeg runs. Never served, swept on boot.
_PARTIAL_SUFFIXES = (".part", ".ytdl", ".temp", ".tmp", ".download")


def _detect_node_path() -> Optional[str]:
    """Locate the node binary yt-dlp uses to run YouTube's player JS.

    Order: explicit NODE_PATH env (if it points at a real file) → PATH lookup
    via shutil.which → a few common install locations. Returns None if node
    can't be found, in which case we let yt-dlp use its own discovery rather
    than forcing a hard-coded /usr/bin/node that may not exist."""
    env = os.environ.get("NODE_PATH")
    if env and Path(env).is_file():
        return env
    found = shutil.which("node")
    if found:
        return found
    for candidate in ("/usr/bin/node", "/usr/local/bin/node", "/opt/homebrew/bin/node"):
        if Path(candidate).is_file():
            return candidate
    return None


NODE_PATH: Optional[str] = _detect_node_path()


def _js_runtimes() -> dict:
    """yt-dlp js_runtimes option, only set when we actually found node."""
    return {"node": {"path": NODE_PATH}} if NODE_PATH else {}


# ---------------------------------------------------------------------------
# Metrics (in-process; surfaced via /api/metrics and /api/health)
# ---------------------------------------------------------------------------
_SERVER_START = time.time()
_LATENCY_SAMPLE_CAP = 500  # per-endpoint ring buffer for percentile estimation


def _new_metrics() -> dict:
    return {
        "total_requests": 0,
        "total_errors": 0,
        # endpoint -> deque of latency_ms samples
        "latency": defaultdict(lambda: deque(maxlen=_LATENCY_SAMPLE_CAP)),
        # endpoint -> count
        "requests_by_endpoint": defaultdict(int),
        # "<status>" or reason -> count
        "failures_by_reason": defaultdict(int),
    }


_metrics = _new_metrics()


def _reset_metrics() -> None:
    """Test hook — wipe accumulated metrics between cases."""
    global _metrics
    _metrics = _new_metrics()


def _record_metric(endpoint: str, status: int, latency_ms: float) -> None:
    _metrics["total_requests"] += 1
    _metrics["requests_by_endpoint"][endpoint] += 1
    _metrics["latency"][endpoint].append(latency_ms)
    if status >= 400:
        _metrics["total_errors"] += 1
        _metrics["failures_by_reason"][str(status)] += 1


def _percentile(samples, pct: float) -> float:
    """Nearest-rank percentile. Returns 0 for an empty sample set."""
    if not samples:
        return 0
    ordered = sorted(samples)
    import math
    rank = max(1, math.ceil(pct / 100.0 * len(ordered)))
    return ordered[rank - 1]


# ---------------------------------------------------------------------------
# Persisted LRU access metadata
# ---------------------------------------------------------------------------
# _stream_access_times was in-memory only: after a restart every file read as
# epoch-0, so the *oldest-accessed-first* eviction order was meaningless and a
# freshly-restarted box could evict the track a user just played. Persisting
# the table to disk makes eviction survive restarts.
_ACCESS_SAVE_MIN_INTERVAL = float(os.environ.get("ACCESS_SAVE_MIN_INTERVAL", "10"))
_last_access_save = 0.0


def _access_times_file() -> Path:
    return CACHE_DIR / ".access_times.json"


def _load_access_times() -> None:
    f = _access_times_file()
    if not f.exists():
        return
    try:
        data = json.loads(f.read_text())
        if isinstance(data, dict):
            _stream_access_times.update({k: float(v) for k, v in data.items()})
    except (OSError, ValueError) as e:
        logger.warning("Could not load access times: %s", e)


def _save_access_times() -> None:
    f = _access_times_file()
    try:
        tmp = f.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(_stream_access_times))
        tmp.replace(f)  # atomic
    except OSError as e:
        logger.warning("Could not persist access times: %s", e)


def _maybe_save_access_times() -> None:
    """Throttled persistence — avoids a disk write on every single access."""
    global _last_access_save
    now = time.time()
    if now - _last_access_save >= _ACCESS_SAVE_MIN_INTERVAL:
        _last_access_save = now
        _save_access_times()


# ---------------------------------------------------------------------------
# Startup / shutdown
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(_app: FastAPI):
    """On startup: sweep interrupted-download junk, reload the LRU table, and
    recompute _total_cache_bytes from disk so eviction is correct immediately
    (was previously 0 until files were re-played, allowing unbounded growth)."""
    global _total_cache_bytes
    removed = _cleanup_partial_files()
    _load_access_times()
    if CACHE_DIR.exists():
        for f in CACHE_DIR.glob("*.*"):
            if f.is_file() and not f.name.startswith("."):
                try:
                    st = f.stat()
                    _total_cache_bytes += st.st_size
                    # Seed any file missing from the (possibly corrupt/empty)
                    # LRU table with its mtime, so eviction has a real age.
                    vid = f.name.split(".", 1)[0]
                    _stream_access_times.setdefault(vid, st.st_mtime)
                except OSError:
                    pass
    file_count = sum(1 for f in CACHE_DIR.glob("*.*") if not f.name.startswith("."))
    logger.info(
        "Startup: indexed %d cached files (%.1f MB), swept %d partials, "
        "node=%s, yt-dlp=%s",
        file_count, _total_cache_bytes / (1024 * 1024), removed,
        NODE_PATH or "NOT FOUND", _ytdlp_version(),
    )
    if NODE_PATH is None:
        logger.warning("node binary not found — yt-dlp JS player extraction may fail")
    yield
    _save_access_times()


app = FastAPI(title="Aria Backend", version="1.1.0", lifespan=lifespan)

_download_events: dict[str, asyncio.Event] = {}
_stream_access_times: dict[str, float] = {}
# Search is cheap (no download); allow several concurrent queries so one slow
# search doesn't block every other user. Downloads are I/O-heavy — cap at 2 to
# avoid saturating yt-dlp / the ffmpeg remux pipeline. Both are env-tunable.
_ytdl_search_semaphore = asyncio.Semaphore(int(os.environ.get("SEARCH_CONCURRENCY", "4")))
_ytdl_download_semaphore = asyncio.Semaphore(int(os.environ.get("DOWNLOAD_CONCURRENCY", "2")))
_eviction_lock = asyncio.Lock()
_total_cache_bytes = 0

_search_cache: dict[str, tuple[list[dict], float]] = {}
_SEARCH_CACHE_TTL: float = float(os.environ.get("SEARCH_CACHE_TTL", "60"))
# Pagination bounds. yt-dlp has no native offset, so a page is served by
# fetching ytsearch{offset+limit} and slicing the tail; cap the total fetch so
# a deep page can't trigger an unbounded extraction. Query length is capped to
# keep a pathological q from blowing up the ytsearch call / cache key.
SEARCH_PAGE_MAX = int(os.environ.get("SEARCH_PAGE_MAX", "50"))
SEARCH_FETCH_MAX = int(os.environ.get("SEARCH_FETCH_MAX", "100"))
MAX_QUERY_LEN = int(os.environ.get("MAX_QUERY_LEN", "200"))

# Cover-art lookup cache. Covers rarely change, so a long TTL (days, not
# seconds) is fine and keeps repeat lookups for the same track free — one
# outbound iTunes/YouTube call per (title, artist, duration-bucket) per TTL
# window. Bounded like the rate-limit table so an endless stream of distinct
# titles/artists can't grow this dict without limit.
_cover_cache: dict[str, tuple[dict, float]] = {}
_COVER_CACHE_TTL: float = float(os.environ.get("COVER_CACHE_TTL", str(60 * 60 * 24 * 7)))  # 7 days
COVER_CACHE_MAX_KEYS = int(os.environ.get("COVER_CACHE_MAX_KEYS", "10000"))

# Per-key request log for rate limiting. Keyed by "<endpoint>:<client-ip>".
_request_log: dict[str, deque[float]] = defaultdict(deque)


def _client_ip(request: Request) -> str:
    """Best-effort client IP for logging and rate limiting.

    X-Forwarded-For is attacker-controllable: any client can prepend fake hops
    to forge a different rate-limit identity (or hide behind a victim's). Each
    proxy appends the peer it saw on the RIGHT, so with ``TRUSTED_PROXY_COUNT``
    proxies in front the real client is the ``N``-th entry from the right
    (``parts[len - N]``) — everything to its left is client-supplied and
    untrusted. If there are fewer hops than trusted proxies the header is
    spoofed/misconfigured, so we ignore it. With no trusted proxy (the default)
    we ignore XFF entirely and use the direct socket peer.
    """
    if TRUSTED_PROXY_COUNT > 0:
        fwd = request.headers.get("x-forwarded-for")
        if fwd:
            parts = [p.strip() for p in fwd.split(",") if p.strip()]
            idx = len(parts) - TRUSTED_PROXY_COUNT
            if idx >= 0:
                return parts[idx]
            # Fewer forwarded hops than trusted proxies → don't trust any entry.
    if request.client and request.client.host:
        return request.client.host
    return "unknown"


# ---------------------------------------------------------------------------
# Request-ID + latency middleware
# ---------------------------------------------------------------------------
@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    request_id = uuid.uuid4().hex[:12]
    request.state.request_id = request_id
    start = time.perf_counter()
    endpoint = request.url.path
    try:
        response = await call_next(request)
        status = response.status_code
    except Exception:
        latency_ms = (time.perf_counter() - start) * 1000
        _record_metric(endpoint, 500, latency_ms)
        logger.exception(
            "rid=%s %s %s -> 500 (%.0fms) unhandled",
            request_id, request.method, endpoint, latency_ms,
        )
        return JSONResponse(
            status_code=500,
            content={"detail": "Internal server error"},
            headers={"X-Request-ID": request_id},
        )
    latency_ms = (time.perf_counter() - start) * 1000
    _record_metric(endpoint, status, latency_ms)
    response.headers["X-Request-ID"] = request_id
    log = logger.warning if status >= 400 else logger.info
    log(
        "rid=%s ip=%s %s %s -> %d (%.0fms)",
        request_id, _client_ip(request), request.method, endpoint,
        status, latency_ms,
    )
    return response


def _prune_request_log(now: float) -> None:
    """Bound the rate-limit table's memory footprint.

    First drop keys whose most-recent hit has aged out of the window (they can
    never rate-limit anything again). If still over ``RATE_LIMIT_MAX_KEYS``,
    evict the keys with the oldest activity until back under the cap. Without
    this, a stream of distinct or spoofed client IPs would grow ``_request_log``
    without limit — a slow memory-exhaustion DoS."""
    stale = [k for k, dq in _request_log.items()
             if not dq or now - dq[-1] > RATE_LIMIT_WINDOW_SECONDS]
    for k in stale:
        del _request_log[k]
    if len(_request_log) > RATE_LIMIT_MAX_KEYS:
        victims = sorted(_request_log.items(), key=lambda kv: kv[1][-1])
        for k, _ in victims[: len(_request_log) - RATE_LIMIT_MAX_KEYS]:
            del _request_log[k]


def _enforce_rate_limit(request: Request, key: str, limit: int) -> None:
    """Sliding-window rate limiter. Raises 429 if `key:<ip>` has had
    `limit` or more requests in the last `RATE_LIMIT_WINDOW_SECONDS`."""
    ip = _client_ip(request)
    full_key = f"{key}:{ip}"
    now = time.time()
    log = _request_log[full_key]
    while log and now - log[0] > RATE_LIMIT_WINDOW_SECONDS:
        log.popleft()
    if len(log) >= limit:
        raise HTTPException(
            status_code=429,
            detail=f"Rate limit exceeded: {limit} requests per "
                   f"{RATE_LIMIT_WINDOW_SECONDS}s. Try again shortly.",
            headers={"Retry-After": str(RATE_LIMIT_WINDOW_SECONDS)},
        )
    log.append(now)
    # Keep the table bounded. The scan only fires once we're over the cap, so
    # the steady-state cost is a dict-size check per request.
    if len(_request_log) > RATE_LIMIT_MAX_KEYS:
        _prune_request_log(now)


def _require_api_key(request: Request) -> None:
    """FastAPI dependency — rejects requests missing a valid API key.
    When ARIA_API_KEY is not set in the environment the check is skipped so
    local dev and existing clients keep working without any config change."""
    if not ARIA_API_KEY:
        return
    key = request.headers.get("X-API-Key", "")
    if not key:
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Bearer "):
            key = auth[7:]
    if key != ARIA_API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing API key")


# ---------------------------------------------------------------------------
# yt-dlp helpers
# ---------------------------------------------------------------------------
def _ytdlp_version() -> str:
    try:
        return yt_dlp.version.__version__
    except Exception:
        return "unknown"


def _cache_basename(video_id: str) -> str:
    """Format-aware cache key stem, e.g. 'dQw4w9WgXcQ.bestaudio'."""
    return f"{video_id}.{AUDIO_FORMAT_TAG}"


def _download_ranges_to_video_duration(info_dict, ydl):
    """Limit audio download to the video's actual duration.

    Fixes the bug where some YouTube DASH audio renditions serve 2x the
    number of audio segments as the video has, causing the downloaded file
    to be twice as long as the actual song (e.g., 6:38 of audio for a
    3:20 video, with the second half being silence/duplication).
    """
    duration = info_dict.get("duration")
    if duration and duration > 0:
        ydl.to_screen(f"Limiting audio download to video duration: {duration:.0f}s")
        return [{"start_time": 0, "end_time": duration}]
    return None


def _download_sync(video_id: str):
    """Download audio from YouTube using yt-dlp (runs in executor)."""
    url = f"https://www.youtube.com/watch?v={video_id}"
    ydl_opts = {
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "outtmpl": str(CACHE_DIR / f"{_cache_basename(video_id)}.%(ext)s"),
        "extractor_args": {"youtube": {"player_client": _YTDL_PLAYER_CLIENTS}},
        "socket_timeout": YTDL_SOCKET_TIMEOUT,
        "quiet": True,
        "no_warnings": True,
        "download_ranges": _download_ranges_to_video_duration,
        # Reject over-long videos and live streams on metadata, before any
        # bytes are downloaded — stops one skip from tying up a download slot
        # for many minutes.
        "match_filter": match_filter_func(
            f"duration < {MAX_DURATION_SECONDS} & !is_live"
        ),
        "max_filesize": MAX_FILESIZE_BYTES,
    }
    runtimes = _js_runtimes()
    if runtimes:
        ydl_opts["js_runtimes"] = runtimes
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        ydl.download([url])


# Substrings that mark a *transient* yt-dlp failure worth retrying. Permanent
# failures (video unavailable/private/age-gated) are NOT here so we fail fast
# instead of wasting three attempts and three download slots on a dead video.
_TRANSIENT_ERROR_MARKERS = (
    "403", "forbidden", "ffmpeg exited", "http error", "ssl",
    "timed out", "timeout", "connection reset", "connection aborted",
    "temporary failure", "fragment", "read error", "broken pipe",
    "502", "503", "504",
)


def _is_transient_error(err: str) -> bool:
    """Classify a yt-dlp error string as transient (retryable) or permanent."""
    e = err.lower()
    return any(marker in e for marker in _TRANSIENT_ERROR_MARKERS)


def _download_with_retry(video_id: str, max_attempts: int = 3) -> None:
    """Retry _download_sync on transient failures (403, ffmpeg errors).

    Hides YouTube edge rate-limiting and intermittent ffmpeg exit code 8
    failures from the iOS client. Up to 3 attempts with exponential backoff
    (1s, 2s) plus a small jitter to avoid thundering-herd retries.
    """
    last_exc: Optional[Exception] = None
    for attempt in range(max_attempts):
        try:
            _download_sync(video_id)
            return
        except Exception as e:
            last_exc = e
            if not _is_transient_error(str(e)) or attempt == max_attempts - 1:
                raise
            backoff = (2 ** attempt) + random.uniform(0, 0.5)
            logger.warning(
                "yt-dlp attempt %d/%d for %s failed: %s; retrying in %.1fs",
                attempt + 1, max_attempts, video_id, e, backoff,
            )
            time.sleep(backoff)
    if last_exc is not None:
        raise last_exc


def _search_sync(query: str, count: int = 25) -> list[dict]:
    """Search YouTube via yt-dlp (runs in executor). `count` is the number of
    results to fetch (ytsearch{count}); the caller slices the page it wants."""
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "socket_timeout": YTDL_SOCKET_TIMEOUT,
    }
    runtimes = _js_runtimes()
    if runtimes:
        ydl_opts["js_runtimes"] = runtimes
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        result = ydl.extract_info(f"ytsearch{count}:{query}", download=False)

    entries = result.get("entries") or []
    return [
        {
            "id": e.get("id"),
            "title": e.get("title", "Unknown"),
            "artist": e.get("channel") or e.get("uploader", "Unknown"),
            "thumbnail": e.get("thumbnail")
            or f"https://i.ytimg.com/vi/{e['id']}/default.jpg",
            "duration": e.get("duration", 0),
        }
        for e in entries
        if e.get("id")
    ]


def _resolve_sync(video_id: str) -> dict:
    """Resolve the direct audio stream URL WITHOUT downloading (runs in
    executor). Lets the client start AVPlayer immediately instead of waiting
    on a full server-side download. The returned googlevideo URL is signed and
    expires (~6h), so the client must re-resolve on playback failure."""
    url = f"https://www.youtube.com/watch?v={video_id}"
    ydl_opts = {
        "format": "bestaudio[ext=m4a]/bestaudio/best",
        "quiet": True,
        "no_warnings": True,
        "extractor_args": {"youtube": {"player_client": _YTDL_PLAYER_CLIENTS}},
        "socket_timeout": YTDL_SOCKET_TIMEOUT,
    }
    runtimes = _js_runtimes()
    if runtimes:
        ydl_opts["js_runtimes"] = runtimes
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=False)

    stream_url = info.get("url")
    if not stream_url and info.get("requested_formats"):
        stream_url = info["requested_formats"][0].get("url")
    if not stream_url:
        # Fall back to the best audio-only format in the list.
        audio = [
            f for f in info.get("formats", [])
            if f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none")
        ]
        if audio:
            stream_url = audio[-1].get("url")

    return {
        "url": stream_url,
        "duration": info.get("duration"),
        "title": info.get("title"),
    }


def _radio_sync(seed_video_id: str, limit: int) -> list[dict]:
    """Return tracks similar to `seed_video_id` by extracting its YouTube Mix
    (RD<id>) radio playlist (flat, runs in executor). This is YouTube's own
    'radio', so results are genuinely related — unlike raw search results."""
    url = f"https://www.youtube.com/watch?v={seed_video_id}&list=RD{seed_video_id}"
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "playlistend": limit,
        "socket_timeout": YTDL_SOCKET_TIMEOUT,
    }
    runtimes = _js_runtimes()
    if runtimes:
        ydl_opts["js_runtimes"] = runtimes
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        result = ydl.extract_info(url, download=False)

    entries = result.get("entries") or []
    return [
        {
            "id": e.get("id"),
            "title": e.get("title", "Unknown"),
            "artist": e.get("channel") or e.get("uploader", "Unknown"),
            "thumbnail": e.get("thumbnail")
            or f"https://i.ytimg.com/vi/{e['id']}/default.jpg",
            "duration": e.get("duration", 0),
        }
        for e in entries
        if e.get("id") and e.get("id") != seed_video_id
    ]


# ---------------------------------------------------------------------------
# Cover-art lookup
# ---------------------------------------------------------------------------
COVER_HTTP_TIMEOUT_SECONDS = float(os.environ.get("COVER_HTTP_TIMEOUT_SECONDS", "5"))
_ITUNES_ARTWORK_SIZE_RE = re.compile(r"\d+x\d+bb\.jpg$")


def _itunes_search_sync(term: str) -> list[dict]:
    """Query the iTunes Search API for candidate tracks (runs in executor).

    No API key required. Raises on network/HTTP error or malformed JSON; the
    caller treats any exception as "no result" and falls back to YouTube.
    """
    qs = urllib.parse.urlencode({
        "term": term,
        "entity": "song",
        "limit": 5,
        "media": "music",
    })
    url = f"https://itunes.apple.com/search?{qs}"
    req = urllib.request.Request(url, headers={"User-Agent": "AriaBackend/1.0"})
    with urllib.request.urlopen(req, timeout=COVER_HTTP_TIMEOUT_SECONDS) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("results") or []


def _youtube_thumbnail_sync(term: str) -> Optional[str]:
    """Fall back to a YouTube thumbnail via the same ytsearch/extract_flat
    machinery /api/search uses. Returns None on no match; propagates
    exceptions so the caller can log/degrade gracefully."""
    ydl_opts = {
        "quiet": True,
        "no_warnings": True,
        "extract_flat": True,
        "socket_timeout": YTDL_SOCKET_TIMEOUT,
    }
    runtimes = _js_runtimes()
    if runtimes:
        ydl_opts["js_runtimes"] = runtimes
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        result = ydl.extract_info(f"ytsearch1:{term}", download=False)

    entries = result.get("entries") or []
    if not entries:
        return None
    e = entries[0]
    if not e.get("id"):
        return None
    return e.get("thumbnail") or f"https://i.ytimg.com/vi/{e['id']}/hqdefault.jpg"


def _normalize_match_text(s: str) -> str:
    return re.sub(r"\s+", " ", s or "").strip().casefold()


def _upscale_itunes_artwork(url: str) -> str:
    """Rewrite the trailing '<W>x<H>bb.jpg' artwork-size suffix to 600x600."""
    if _ITUNES_ARTWORK_SIZE_RE.search(url):
        return _ITUNES_ARTWORK_SIZE_RE.sub("600x600bb.jpg", url)
    return url


def _pick_best_itunes_result(results: list[dict], artist: str,
                              duration_seconds: Optional[float]) -> Optional[dict]:
    """Pick the best iTunes candidate.

    Prefer results whose artist matches (casefolded, whitespace-normalized);
    among those (or all, if none match), break ties by closeness of
    trackTimeMillis to the supplied duration — this avoids picking a live
    version/wrong release when several tracks share a title+artist.
    """
    candidates = [r for r in results if r.get("artworkUrl100")]
    if not candidates:
        return None

    norm_artist = _normalize_match_text(artist)
    artist_matches = [
        r for r in candidates
        if _normalize_match_text(r.get("artistName", "")) == norm_artist
    ]
    pool = artist_matches or candidates

    if duration_seconds is not None and len(pool) > 1:
        target_ms = duration_seconds * 1000

        def dist(r):
            t = r.get("trackTimeMillis")
            if t is None:
                return float("inf")
            return abs(t - target_ms)

        pool = sorted(pool, key=dist)

    return pool[0]


def _prune_cover_cache() -> None:
    """Bound the cover-art cache: drop TTL-expired entries first, then evict
    oldest-inserted if still over COVER_CACHE_MAX_KEYS."""
    now = time.time()
    stale = [k for k, (_, ts) in _cover_cache.items() if now - ts > _COVER_CACHE_TTL]
    for k in stale:
        del _cover_cache[k]
    if len(_cover_cache) > COVER_CACHE_MAX_KEYS:
        victims = sorted(_cover_cache.items(), key=lambda kv: kv[1][1])
        for k, _ in victims[: len(_cover_cache) - COVER_CACHE_MAX_KEYS]:
            del _cover_cache[k]


def _cover_cache_key(title: str, artist: str, duration_seconds: Optional[float]) -> str:
    """Normalized (title, artist, duration-bucket) cache key. Duration is
    bucketed to the nearest 5s so near-identical client-reported durations
    still hit the same cache entry."""
    bucket = "" if duration_seconds is None else str(int(round(duration_seconds / 5.0)))
    return f"{_normalize_match_text(title)}\x00{_normalize_match_text(artist)}\x00{bucket}"


def _lookup_cover_sync(title: str, artist: str, duration_seconds: Optional[float]) -> dict:
    """Synchronous cover lookup (runs in executor): iTunes first, YouTube
    thumbnail as fallback. Never raises — any failure degrades to a null
    result so the endpoint never 500s on a flaky upstream."""
    term = f"{artist} {title}".strip()

    try:
        results = _itunes_search_sync(term)
        best = _pick_best_itunes_result(results, artist, duration_seconds)
        if best:
            return {
                "cover_url": _upscale_itunes_artwork(best["artworkUrl100"]),
                "source": "itunes",
            }
    except Exception as e:
        logger.warning("iTunes cover lookup failed for %r: %s", term, e)

    try:
        thumb = _youtube_thumbnail_sync(term)
        if thumb:
            return {"cover_url": thumb, "source": "youtube"}
    except Exception as e:
        logger.warning("YouTube cover fallback failed for %r: %s", term, e)

    return {"cover_url": None, "source": None}


# ---------------------------------------------------------------------------
# Cache file management
# ---------------------------------------------------------------------------
def _is_partial(path: Path) -> bool:
    name = path.name.lower()
    return name.startswith(".") or any(name.endswith(s) for s in _PARTIAL_SUFFIXES)


def _find_cached_file(video_id: str) -> Optional[Path]:
    """Return the best cached audio file for video_id, or None.

    Skips partial/junk files and zero-byte artifacts, and picks
    deterministically by extension preference (m4a first) so two formats for
    one video never resolve to an arbitrary match."""
    candidates = []
    # Prefer the format-tagged name, but fall back to legacy untagged files so
    # an existing cache isn't wholesale re-downloaded after this change ships.
    for pattern in (f"{_cache_basename(video_id)}.*", f"{video_id}.*"):
        for f in CACHE_DIR.glob(pattern):
            if not f.is_file() or _is_partial(f):
                continue
            try:
                if f.stat().st_size == 0:
                    continue
            except OSError:
                continue
            candidates.append(f)
        if candidates:
            break

    if not candidates:
        return None

    def rank(p: Path):
        ext = p.suffix.lower()
        pref = _EXT_PREFERENCE.index(ext) if ext in _EXT_PREFERENCE else len(_EXT_PREFERENCE)
        return (pref, p.name)

    return sorted(candidates, key=rank)[0]


def _is_valid_media(path: Path) -> bool:
    """Validate a freshly-downloaded file before serving it.

    Always enforces a minimum size (truncated downloads / error pages are
    tiny). If ffprobe is available, additionally confirm the file is a
    decodable media container — catches corrupt or non-audio downloads."""
    try:
        if path.stat().st_size < MIN_VALID_FILE_BYTES:
            return False
    except OSError:
        return False

    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return True  # size check is the best we can do
    try:
        result = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
            capture_output=True, timeout=15,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except (subprocess.SubprocessError, OSError) as e:
        logger.warning("ffprobe validation error for %s: %s", path.name, e)
        return False


def _cleanup_partial_files() -> int:
    """Remove interrupted-download artifacts and zero-byte files. Returns the
    number removed. Called on startup; '.'-dotfiles like the access-times JSON
    are preserved (only *.part/.ytdl/etc and zero-byte media are swept)."""
    removed = 0
    for f in CACHE_DIR.glob("*"):
        if not f.is_file():
            continue
        name = f.name.lower()
        is_junk = any(name.endswith(s) for s in _PARTIAL_SUFFIXES)
        is_empty = False
        if not name.startswith("."):
            try:
                is_empty = f.stat().st_size == 0
            except OSError:
                continue
        if is_junk or is_empty:
            try:
                f.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def _sweep_partials(video_id: str) -> None:
    """Remove leftover partial-download artifacts for one video (e.g. after a
    failed/aborted or over-size download). Without this, `.part` files pile up:
    they're excluded from `_total_cache_bytes` accounting and skipped by
    eviction, and were only swept on restart — so between restarts they fill the
    disk toward the headroom and wedge every download on a permanent 507."""
    for f in CACHE_DIR.glob(f"{video_id}*"):
        if f.is_file() and _is_partial(f):
            try:
                f.unlink()
            except OSError:
                pass


def _check_disk_space(needed_bytes: int = 0) -> None:
    """Raise 507 if writing `needed_bytes` would push free space below the
    configured headroom. Cheap precheck that prevents a disk-fill outage."""
    try:
        usage = shutil.disk_usage(CACHE_DIR)
    except OSError as e:
        logger.warning("disk_usage check failed: %s", e)
        return
    if usage.free - needed_bytes < MIN_FREE_DISK_BYTES:
        logger.error(
            "Refusing download: free=%d needed=%d headroom=%d",
            usage.free, needed_bytes, MIN_FREE_DISK_BYTES,
        )
        raise HTTPException(
            status_code=507,
            detail="Insufficient storage on server; try again later.",
        )


async def _evict_if_needed(current_video_id: str = ""):
    """Remove oldest-accessed files if cache exceeds MAX_CACHE_GB."""
    async with _eviction_lock:
        global _total_cache_bytes
        limit_bytes = int(MAX_CACHE_GB * 1024 * 1024 * 1024)
        grace = CACHE_EVICT_GRACE_SECONDS
        now = time.time()

        if _total_cache_bytes <= limit_bytes:
            return

        files_with_age = []
        for f in CACHE_DIR.glob("*.*"):
            if not f.is_file() or _is_partial(f):
                continue
            vid = f.name.split(".", 1)[0]
            last_access = _stream_access_times.get(vid)
            if last_access is None:
                # No LRU entry (e.g. after a corrupt access-times file reset the
                # table): fall back to the file's mtime instead of 0, so grace
                # still protects it and the sort order stays meaningful.
                try:
                    last_access = f.stat().st_mtime
                except OSError:
                    last_access = 0
            files_with_age.append((last_access, f, vid))

        files_with_age.sort(key=lambda x: x[0])
        evicted_names: set[str] = set()

        def evict_pass(ignore_grace: bool) -> None:
            global _total_cache_bytes
            for last_access, f, vid in files_with_age:
                if _total_cache_bytes <= limit_bytes:
                    break
                if vid == current_video_id or f.name in evicted_names:
                    continue
                if not ignore_grace and now - last_access < grace:
                    continue
                try:
                    file_size = f.stat().st_size
                    f.unlink()
                    evicted_names.add(f.name)
                    _stream_access_times.pop(vid, None)
                    _total_cache_bytes -= file_size
                    logger.info(
                        "Evicted %s (idle %.0fs%s)", f.name, now - last_access,
                        ", grace overridden" if ignore_grace else "",
                    )
                except OSError:
                    pass

        evict_pass(ignore_grace=False)
        # Hard cap: if every candidate was inside the grace window, the pass
        # above frees nothing and the cache grows without bound (previously only
        # stopped by a disk-full 507). Force-evict oldest-first, grace be damned.
        if _total_cache_bytes > limit_bytes:
            logger.warning(
                "Grace-window eviction freed nothing while over cap "
                "(%.1f MB > %.1f MB); overriding grace.",
                _total_cache_bytes / (1024 * 1024), limit_bytes / (1024 * 1024),
            )
            evict_pass(ignore_grace=True)
        _save_access_times()


def _record_access(video_id: str):
    """Record that a cached file was accessed for LRU tracking."""
    _stream_access_times[video_id] = time.time()
    _maybe_save_access_times()


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.get("/api/play")
async def play(
    request: Request,
    video_id: str = Query(..., description="YouTube video ID"),
    _auth: None = Depends(_require_api_key),
):
    """
    Get a stream URL for a YouTube video.
    Returns cached file if available, otherwise downloads and caches.
    """
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=400, detail="Invalid video_id format")
    _enforce_rate_limit(request, "play", RATE_LIMIT_PLAY_PER_MIN)
    cached = _find_cached_file(video_id)
    if cached:
        _record_access(video_id)
        return {"url": f"/api/stream/{cached.name}", "cached": True}

    event = _download_events.get(video_id)
    if event is not None:
        await event.wait()
        cached = _find_cached_file(video_id)
        if cached:
            _record_access(video_id)
            return {"url": f"/api/stream/{cached.name}", "cached": False}
        raise HTTPException(status_code=502, detail="Download failed")

    event = asyncio.Event()
    _download_events[video_id] = event

    try:
        _check_disk_space(MAX_FILESIZE_BYTES)
        async with _ytdl_download_semaphore:
            loop = asyncio.get_running_loop()
            await loop.run_in_executor(None, _download_with_retry, video_id)
    except HTTPException:
        raise
    except Exception as e:
        _metrics["failures_by_reason"]["download_error"] += 1
        logger.error("Download failed for %s: %s", video_id, e)
        _sweep_partials(video_id)
        raise HTTPException(status_code=502, detail=f"Download failed: {str(e)}")
    finally:
        event.set()
        _download_events.pop(video_id, None)

    cached = _find_cached_file(video_id)
    if cached and _is_valid_media(cached):
        global _total_cache_bytes
        _total_cache_bytes += cached.stat().st_size
        _record_access(video_id)
        await _evict_if_needed(current_video_id=video_id)
        return {"url": f"/api/stream/{cached.name}", "cached": False}

    # Invalid/corrupt/missing — clean up so we don't serve or cache junk.
    if cached:
        logger.error("Downloaded file failed validation, discarding: %s", cached.name)
        try:
            cached.unlink()
        except OSError:
            pass
        _metrics["failures_by_reason"]["invalid_media"] += 1
    raise HTTPException(status_code=502, detail="Failed to download valid audio")


def _media_type_for(path: Path) -> str:
    ext = path.suffix.lower()
    return {
        ".m4a": "audio/mp4",
        ".mp4": "audio/mp4",
        ".webm": "audio/webm",
        ".ogg": "audio/ogg",
        ".opus": "audio/ogg",
    }.get(ext, "application/octet-stream")


@app.get("/api/stream/{file_name}")
async def stream(file_name: str):
    """Serve a cached audio file with Range request support for AVPlayer seeking."""
    # Allowlist before any filesystem touch: a cache file is always
    # "<11-char video id>.<format tag>.<ext>", so the leading segment must be a
    # valid video ID. This rejects traversal/garbage names up front, on top of
    # the path-containment check below (defence in depth).
    video_id = file_name.split(".", 1)[0]
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=400, detail="Invalid file name")

    file_path = (CACHE_DIR / file_name).resolve()
    if not file_path.is_relative_to(CACHE_DIR.resolve()):
        raise HTTPException(status_code=400, detail="Invalid file path")
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="File not found")

    _record_access(video_id)

    return FileResponse(file_path, media_type=_media_type_for(file_path))


@app.get("/api/search")
async def search(
    request: Request,
    q: str = Query(..., description="Search query"),
    limit: int = Query(25, ge=1, le=SEARCH_PAGE_MAX, description="Results per page"),
    offset: int = Query(0, ge=0, description="Number of leading results to skip"),
    _auth: None = Depends(_require_api_key),
):
    """
    Search YouTube for music. Returns list of {id, title, artist, thumbnail, duration}.
    Paginated via `limit`/`offset`; uses yt-dlp search with a short in-memory
    cache keyed by (query, fetch depth) — no API key needed.
    """
    _enforce_rate_limit(request, "search", RATE_LIMIT_SEARCH_PER_MIN)
    query = q.strip()[:MAX_QUERY_LEN]
    if not query:
        return []

    # yt-dlp has no offset, so fetch offset+limit and slice. Bound the fetch so
    # a deep page can't request an unbounded extraction; past the cap there are
    # simply no more results.
    if offset >= SEARCH_FETCH_MAX:
        return []
    fetch_count = min(offset + limit, SEARCH_FETCH_MAX)
    cache_key = f"{query}\x00{fetch_count}"

    now = time.time()
    cached = _search_cache.get(cache_key)
    if cached and now - cached[1] < _SEARCH_CACHE_TTL:
        return cached[0][offset:offset + limit]

    try:
        async with _ytdl_search_semaphore:
            loop = asyncio.get_running_loop()
            results = await loop.run_in_executor(None, _search_sync, query, fetch_count)
    except Exception as e:
        logger.error("Search failed for %r: %s", query, e)
        raise HTTPException(status_code=502, detail=f"Search failed: {str(e)}")

    _search_cache[cache_key] = (results, time.time())
    return results[offset:offset + limit]


@app.get("/api/resolve")
async def resolve(
    request: Request,
    video_id: str = Query(..., description="YouTube video ID"),
    _auth: None = Depends(_require_api_key),
):
    """
    Resolve a direct, immediately-playable audio stream URL without downloading.
    Lets the client start playback right away; the (signed, ~6h) URL should be
    re-resolved on playback failure. Runs under the search semaphore so it never
    queues behind downloads.
    """
    if not _VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=400, detail="Invalid video_id format")
    _enforce_rate_limit(request, "play", RATE_LIMIT_PLAY_PER_MIN)

    try:
        async with _ytdl_search_semaphore:
            loop = asyncio.get_running_loop()
            result = await loop.run_in_executor(None, _resolve_sync, video_id)
    except Exception as e:
        logger.error("Resolve failed for %s: %s", video_id, e)
        raise HTTPException(status_code=502, detail=f"Resolve failed: {str(e)}")

    if not result.get("url"):
        raise HTTPException(status_code=502, detail="Could not resolve stream URL")
    return result


@app.get("/api/radio")
async def radio(
    request: Request,
    seed: str = Query(..., description="Seed YouTube video ID"),
    limit: int = Query(25, ge=1, le=50, description="Max similar tracks"),
    _auth: None = Depends(_require_api_key),
):
    """
    Return tracks similar to `seed` from its YouTube Mix (RD<seed>) — true
    'radio', used to seed an endless autoplay queue. Same shape as /api/search.
    """
    if not _VIDEO_ID_RE.match(seed):
        raise HTTPException(status_code=400, detail="Invalid seed format")
    _enforce_rate_limit(request, "search", RATE_LIMIT_SEARCH_PER_MIN)

    try:
        async with _ytdl_search_semaphore:
            loop = asyncio.get_running_loop()
            results = await loop.run_in_executor(None, _radio_sync, seed, limit)
    except Exception as e:
        logger.error("Radio failed for %s: %s", seed, e)
        raise HTTPException(status_code=502, detail=f"Radio failed: {str(e)}")

    return results


@app.get("/api/cover")
async def cover(
    request: Request,
    title: str = Query(..., description="Track title"),
    artist: str = Query(..., description="Track artist"),
    duration: Optional[float] = Query(
        None, description="Track duration in seconds, used to break ties between releases"
    ),
    _auth: None = Depends(_require_api_key),
):
    """
    Look up the best album-cover image URL for a (title, artist[, duration])
    triple — used to populate artwork for local/offline tracks with no
    embedded cover art.

    Primary source is the iTunes Search API (upscaled to 600x600, no API
    key); if that yields nothing, falls back to a YouTube search thumbnail
    (ytsearch1, the same machinery /api/search uses). Always returns 200 with
    ``{"cover_url": <url or null>, "source": "itunes"|"youtube"|null}`` —
    never 404/500 on a miss or upstream failure, so the client can treat
    every response uniformly.
    """
    _enforce_rate_limit(request, "cover", RATE_LIMIT_COVER_PER_MIN)

    title = title.strip()[:MAX_QUERY_LEN]
    artist = artist.strip()[:MAX_QUERY_LEN]
    if not title or not artist:
        return {"cover_url": None, "source": None}

    cache_key = _cover_cache_key(title, artist, duration)
    now = time.time()
    cached = _cover_cache.get(cache_key)
    if cached and now - cached[1] < _COVER_CACHE_TTL:
        return cached[0]

    async with _ytdl_search_semaphore:
        loop = asyncio.get_running_loop()
        result = await loop.run_in_executor(
            None, _lookup_cover_sync, title, artist, duration
        )

    _cover_cache[cache_key] = (result, now)
    if len(_cover_cache) > COVER_CACHE_MAX_KEYS:
        _prune_cover_cache()
    return result


@app.delete("/api/cache")
async def clear_cache(request: Request, _auth: None = Depends(_require_api_key)):
    """Delete all cached audio files.

    Auth is opt-in: gated by X-API-Key only when ARIA_API_KEY is set (per
    project decision, so local dev stays keyless). The rate limit applies
    regardless, so an unauthenticated deployment still can't be cache-wiped in
    a tight loop (a forced-redownload / cost-amplification DoW)."""
    _enforce_rate_limit(request, "cache", RATE_LIMIT_CACHE_PER_MIN)
    global _total_cache_bytes
    count = 0
    for f in CACHE_DIR.glob("*.*"):
        if f.is_file() and not f.name.startswith("."):
            f.unlink()
            count += 1
    _total_cache_bytes = 0
    _stream_access_times.clear()
    _save_access_times()
    logger.info("Cache cleared: %d files removed", count)
    return {"deleted": count}


@app.get("/api/health")
async def health():
    """Health check, cache stats, dependency versions, and error rate.

    Designed to be polled by an external uptime monitor: it reports enough for
    the monitor to alert on a degraded node/yt-dlp install or a rising error
    rate, not just 'is the process up'."""
    files = [f for f in CACHE_DIR.glob("*.*") if not f.name.startswith(".")]
    total = _metrics["total_requests"]
    errors = _metrics["total_errors"]
    return {
        "status": "ok",
        "version": app.version,
        "uptime_seconds": round(time.time() - _SERVER_START, 1),
        "yt_dlp_version": _ytdlp_version(),
        "node": {"path": NODE_PATH, "available": NODE_PATH is not None},
        "cached_files": len(files),
        "cache_size_mb": round(_total_cache_bytes / (1024 * 1024), 1),
        "cache_limit_gb": MAX_CACHE_GB,
        "access_tracked": len(_stream_access_times),
        "total_requests": total,
        "total_errors": errors,
        "error_rate": round(errors / total, 4) if total else 0.0,
    }


@app.get("/api/metrics")
async def metrics():
    """Per-endpoint p50/p95 latency, request counts, and failure-by-reason
    counters — the observability surface for cost/latency monitoring."""
    endpoints = {}
    for ep, samples in _metrics["latency"].items():
        endpoints[ep] = {
            "count": _metrics["requests_by_endpoint"].get(ep, 0),
            "p50_ms": round(_percentile(samples, 50), 1),
            "p95_ms": round(_percentile(samples, 95), 1),
            "samples": len(samples),
        }
    return {
        "uptime_seconds": round(time.time() - _SERVER_START, 1),
        "total_requests": _metrics["total_requests"],
        "total_errors": _metrics["total_errors"],
        "failures_by_reason": dict(_metrics["failures_by_reason"]),
        "endpoints": endpoints,
    }
