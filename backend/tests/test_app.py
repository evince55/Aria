"""Test suite for the Aria FastAPI backend.

Covers the LLMOps-hardening cluster: video_id validation, rate limiting,
single-flight download, retry classification, cache eviction, file validation,
disk-full guard, format-aware cache key, node detection, persisted LRU
metadata, structured request IDs, and the /api/resolve, /api/radio,
/api/health, /api/metrics endpoints.
"""
import asyncio
import os
import sys
import time

import httpx
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import app as appmod  # noqa: E402


# ---------------------------------------------------------------------------
# video_id validation
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad", ["", "short", "toolongvideoid", "bad id chars!", "../etc/passwd"])
def test_play_rejects_bad_video_id(client, bad):
    assert client.get("/api/play", params={"video_id": bad}).status_code == 400


@pytest.mark.parametrize("endpoint,param", [("/api/resolve", "video_id"), ("/api/radio", "seed")])
def test_resolve_and_radio_reject_bad_id(client, endpoint, param):
    assert client.get(endpoint, params={param: "nope"}).status_code == 400


def test_valid_video_id_passes_validation(client, monkeypatch):
    monkeypatch.setattr(appmod, "_resolve_sync", lambda vid: {"url": "https://x/y", "duration": 100, "title": "t"})
    r = client.get("/api/resolve", params={"video_id": "dQw4w9WgXcQ"})
    assert r.status_code == 200
    assert r.json()["url"] == "https://x/y"


# ---------------------------------------------------------------------------
# rate limiting
# ---------------------------------------------------------------------------

def test_search_rate_limit_returns_429(client, monkeypatch):
    monkeypatch.setattr(appmod, "RATE_LIMIT_SEARCH_PER_MIN", 3)
    monkeypatch.setattr(appmod, "_search_sync", lambda q, count=25: [])
    for _ in range(3):
        assert client.get("/api/search", params={"q": "hello"}).status_code == 200
    assert client.get("/api/search", params={"q": "hello"}).status_code == 429


def _fake_search(query, count=25):
    return [
        {"id": f"id{i}", "title": f"t{i}", "artist": "a",
         "thumbnail": "x", "duration": i}
        for i in range(count)
    ]


def test_search_pagination_slices_by_offset(client, monkeypatch):
    monkeypatch.setattr(appmod, "_search_sync", _fake_search)
    page1 = client.get("/api/search", params={"q": "x", "limit": 10, "offset": 0}).json()
    assert [r["id"] for r in page1] == [f"id{i}" for i in range(10)]
    page2 = client.get("/api/search", params={"q": "x", "limit": 10, "offset": 10}).json()
    assert [r["id"] for r in page2] == [f"id{i}" for i in range(10, 20)]


def test_search_offset_past_fetch_cap_is_empty(client, monkeypatch):
    monkeypatch.setattr(appmod, "_search_sync", _fake_search)
    monkeypatch.setattr(appmod, "SEARCH_FETCH_MAX", 100)
    assert client.get("/api/search", params={"q": "x", "offset": 100}).json() == []


def test_search_query_length_capped(client, monkeypatch):
    seen = {}

    def fake(query, count=25):
        seen["q"] = query
        return []

    monkeypatch.setattr(appmod, "_search_sync", fake)
    monkeypatch.setattr(appmod, "MAX_QUERY_LEN", 10)
    client.get("/api/search", params={"q": "z" * 50})
    assert len(seen["q"]) == 10


def test_search_returns_duration(client, monkeypatch):
    monkeypatch.setattr(appmod, "_search_sync", _fake_search)
    r = client.get("/api/search", params={"q": "x", "limit": 3, "offset": 0}).json()
    assert r[2]["duration"] == 2


def test_rate_limit_is_per_ip(client, monkeypatch):
    # Behind one trusted proxy, X-Forwarded-For is honoured as the client IP.
    monkeypatch.setattr(appmod, "TRUSTED_PROXY_COUNT", 1)
    monkeypatch.setattr(appmod, "RATE_LIMIT_SEARCH_PER_MIN", 1)
    monkeypatch.setattr(appmod, "_search_sync", lambda q, count=25: [])
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 200
    # different IP is unaffected
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "2.2.2.2"}).status_code == 200
    # same IP again is limited
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 429


def test_xff_ignored_without_trusted_proxy(client, monkeypatch):
    """Default TRUSTED_PROXY_COUNT=0: a spoofed X-Forwarded-For cannot forge a
    fresh rate-limit identity — every request collapses onto the socket peer."""
    monkeypatch.setattr(appmod, "TRUSTED_PROXY_COUNT", 0)
    monkeypatch.setattr(appmod, "RATE_LIMIT_SEARCH_PER_MIN", 1)
    monkeypatch.setattr(appmod, "_search_sync", lambda q, count=25: [])
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 200
    # A rotating spoofed XFF does NOT escape the limit — same real peer.
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "9.9.9.9"}).status_code == 429


def test_client_ip_uses_nth_hop_from_right(monkeypatch):
    # With one trusted proxy, only the rightmost entry (which the proxy appended)
    # is trustworthy; a client-prepended forgery on the left must be ignored.
    monkeypatch.setattr(appmod, "TRUSTED_PROXY_COUNT", 1)

    class _Req:
        headers = {"x-forwarded-for": "9.9.9.9, 203.0.113.7"}  # 9.9.9.9 forged
        client = None

    assert appmod._client_ip(_Req()) == "203.0.113.7"


def test_client_ip_ignores_spoof_beyond_trusted_hops(monkeypatch):
    # Fewer forwarded hops than trusted proxies ⇒ header can't be trusted ⇒
    # fall through to the socket peer instead of returning a forged entry.
    monkeypatch.setattr(appmod, "TRUSTED_PROXY_COUNT", 2)

    class _Client:
        host = "10.0.0.5"

    class _Req:
        headers = {"x-forwarded-for": "1.2.3.4"}
        client = _Client()

    assert appmod._client_ip(_Req()) == "10.0.0.5"


def test_client_ip_trusts_cf_connecting_ip_from_loopback():
    # Cloudflare Tunnel: the local cloudflared arrives on loopback and sets
    # CF-Connecting-IP to the real remote client — that's the rate-limit identity.
    class _Client:
        host = "127.0.0.1"

    class _Req:
        headers = {"cf-connecting-ip": "198.51.100.7"}
        client = _Client()

    assert appmod._client_ip(_Req()) == "198.51.100.7"


def test_client_ip_ignores_cf_connecting_ip_from_direct_peer():
    # A caller reaching the origin directly (Tailscale/LAN, non-loopback peer)
    # must NOT be able to forge a rate-limit identity via CF-Connecting-IP.
    class _Client:
        host = "100.64.0.9"  # Tailscale-range peer, not loopback

    class _Req:
        headers = {"cf-connecting-ip": "1.2.3.4"}  # forged
        client = _Client()

    assert appmod._client_ip(_Req()) == "100.64.0.9"


def test_prune_request_log_bounds_memory(monkeypatch):
    monkeypatch.setattr(appmod, "RATE_LIMIT_MAX_KEYS", 5)
    appmod._request_log.clear()
    now = appmod.time.time()
    for i in range(20):
        appmod._request_log[f"play:{i}"].append(now)
    appmod._prune_request_log(now)
    assert len(appmod._request_log) <= 5
    appmod._request_log.clear()


def test_prune_request_log_drops_stale_keys(monkeypatch):
    appmod._request_log.clear()
    now = appmod.time.time()
    appmod._request_log["play:fresh"].append(now)
    appmod._request_log["play:stale"].append(now - appmod.RATE_LIMIT_WINDOW_SECONDS - 1)
    appmod._prune_request_log(now)
    assert "play:fresh" in appmod._request_log
    assert "play:stale" not in appmod._request_log
    appmod._request_log.clear()


# ---------------------------------------------------------------------------
# retry classification
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("msg", [
    "HTTP Error 403: Forbidden",
    "fragment 1 not found, unable to continue",
    "ffmpeg exited with code 8",
    "[Errno 104] Connection reset by peer",
    "Read timed out",
    "SSL: WRONG_VERSION_NUMBER",
])
def test_transient_errors_classified(msg):
    assert appmod._is_transient_error(msg) is True


@pytest.mark.parametrize("msg", [
    "Video unavailable",
    "Private video",
    "This video is not available in your country",
    "Sign in to confirm your age",
])
def test_permanent_errors_classified(msg):
    assert appmod._is_transient_error(msg) is False


def test_retry_stops_after_max_attempts(monkeypatch):
    calls = {"n": 0}

    def boom(vid):
        calls["n"] += 1
        raise RuntimeError("HTTP Error 403: Forbidden")

    monkeypatch.setattr(appmod, "_download_sync", boom)
    monkeypatch.setattr(appmod.time, "sleep", lambda s: None)
    with pytest.raises(RuntimeError):
        appmod._download_with_retry("dQw4w9WgXcQ", max_attempts=3)
    assert calls["n"] == 3


def test_no_retry_on_permanent_error(monkeypatch):
    calls = {"n": 0}

    def boom(vid):
        calls["n"] += 1
        raise RuntimeError("Video unavailable")

    monkeypatch.setattr(appmod, "_download_sync", boom)
    monkeypatch.setattr(appmod.time, "sleep", lambda s: None)
    with pytest.raises(RuntimeError):
        appmod._download_with_retry("dQw4w9WgXcQ", max_attempts=3)
    assert calls["n"] == 1


# ---------------------------------------------------------------------------
# cache eviction
# ---------------------------------------------------------------------------

def _make_file(d, name, size):
    p = d / name
    p.write_bytes(b"\0" * size)
    return p


def test_eviction_removes_oldest_first(cache_dir, monkeypatch):
    monkeypatch.setattr(appmod, "MAX_CACHE_GB", 1.0 / 1024)  # 1 MB limit
    monkeypatch.setattr(appmod, "CACHE_EVICT_GRACE_SECONDS", 0)
    old = _make_file(cache_dir, "aaaaaaaaaaa.bestaudio.m4a", 700 * 1024)
    new = _make_file(cache_dir, "bbbbbbbbbbb.bestaudio.m4a", 700 * 1024)
    now = time.time()
    appmod._stream_access_times["aaaaaaaaaaa"] = now - 1000
    appmod._stream_access_times["bbbbbbbbbbb"] = now - 1
    appmod._total_cache_bytes = old.stat().st_size + new.stat().st_size
    asyncio.run(appmod._evict_if_needed())
    assert not old.exists()
    assert new.exists()


def test_eviction_respects_grace_when_cap_still_reachable(cache_dir, monkeypatch):
    # A within-grace file is protected as long as evicting older files can bring
    # the cache under cap without touching it.
    monkeypatch.setattr(appmod, "MAX_CACHE_GB", 1.0 / 1024)  # 1 MB limit
    monkeypatch.setattr(appmod, "CACHE_EVICT_GRACE_SECONDS", 300)
    now = time.time()
    fresh = _make_file(cache_dir, "ccccccccccc.bestaudio.m4a", 700 * 1024)
    old = _make_file(cache_dir, "ddddddddddd.bestaudio.m4a", 700 * 1024)
    appmod._stream_access_times["ccccccccccc"] = now          # within grace
    appmod._stream_access_times["ddddddddddd"] = now - 10000  # old, evictable
    appmod._total_cache_bytes = fresh.stat().st_size + old.stat().st_size
    asyncio.run(appmod._evict_if_needed())
    assert fresh.exists()       # protected — evicting the old file met the cap
    assert not old.exists()


def test_eviction_overrides_grace_when_cap_unreachable(cache_dir, monkeypatch):
    # Every file is within grace but we're over cap: the hard cap must win
    # (override grace) rather than let the cache grow unbounded. The current
    # track stays protected even under override.
    monkeypatch.setattr(appmod, "MAX_CACHE_GB", 1.0 / 1024)  # 1 MB
    monkeypatch.setattr(appmod, "CACHE_EVICT_GRACE_SECONDS", 300)
    now = time.time()
    a = _make_file(cache_dir, "eeeeeeeeeee.bestaudio.m4a", 700 * 1024)
    b = _make_file(cache_dir, "fffffffffff.bestaudio.m4a", 700 * 1024)
    appmod._stream_access_times["eeeeeeeeeee"] = now - 5  # within grace, older
    appmod._stream_access_times["fffffffffff"] = now - 1  # within grace, newer
    appmod._total_cache_bytes = a.stat().st_size + b.stat().st_size
    asyncio.run(appmod._evict_if_needed(current_video_id="fffffffffff"))
    assert not a.exists()  # oldest force-evicted despite grace
    assert b.exists()      # current track protected


def test_eviction_uses_mtime_when_lru_entry_missing(cache_dir, monkeypatch):
    # Post-corrupt-load state: file on disk with no access-times entry must be
    # aged by its mtime (recent), not epoch 0 — otherwise it sorts oldest and is
    # wrongly evicted before genuinely-old tracked files.
    monkeypatch.setattr(appmod, "MAX_CACHE_GB", 1.0 / 1024)  # 1 MB
    monkeypatch.setattr(appmod, "CACHE_EVICT_GRACE_SECONDS", 300)
    now = time.time()
    untracked = _make_file(cache_dir, "ggggggggggg.bestaudio.m4a", 700 * 1024)
    old = _make_file(cache_dir, "hhhhhhhhhhh.bestaudio.m4a", 700 * 1024)
    appmod._stream_access_times["hhhhhhhhhhh"] = now - 10000  # tracked, ancient
    # no entry for "ggggggggggg" — its fresh mtime should protect it
    appmod._total_cache_bytes = untracked.stat().st_size + old.stat().st_size
    asyncio.run(appmod._evict_if_needed())
    assert untracked.exists()
    assert not old.exists()


def test_sweep_partials_removes_only_partial_artifacts(cache_dir):
    vid = "dQw4w9WgXcQ"
    part = _make_file(cache_dir, f"{vid}.bestaudio.m4a.part", 100)
    good = _make_file(cache_dir, f"{vid}.bestaudio.m4a", 100)
    other = _make_file(cache_dir, "otherVideo1.bestaudio.m4a.part", 100)
    appmod._sweep_partials(vid)
    assert not part.exists()   # this video's partial swept
    assert good.exists()       # completed file untouched
    assert other.exists()      # a different video's partial untouched


# ---------------------------------------------------------------------------
# file validation & partial cleanup
# ---------------------------------------------------------------------------

def test_zero_byte_file_is_invalid(cache_dir, monkeypatch):
    monkeypatch.setattr(appmod.shutil, "which", lambda b: None)  # no ffprobe
    p = _make_file(cache_dir, "ddddddddddd.bestaudio.m4a", 0)
    assert appmod._is_valid_media(p) is False


def test_sufficiently_large_file_is_valid_without_ffprobe(cache_dir, monkeypatch):
    monkeypatch.setattr(appmod.shutil, "which", lambda b: None)
    p = _make_file(cache_dir, "eeeeeeeeeee.bestaudio.m4a", appmod.MIN_VALID_FILE_BYTES + 10)
    assert appmod._is_valid_media(p) is True


def test_find_cached_file_skips_partial_and_zero_byte(cache_dir):
    _make_file(cache_dir, "fffffffffff.bestaudio.m4a.part", 5000)
    _make_file(cache_dir, "fffffffffff.bestaudio.m4a", 0)
    assert appmod._find_cached_file("fffffffffff") is None


def test_cleanup_removes_partial_artifacts(cache_dir):
    _make_file(cache_dir, "ggggggggggg.bestaudio.m4a.part", 100)
    _make_file(cache_dir, "ggggggggggg.bestaudio.webm.ytdl", 100)
    _make_file(cache_dir, "hhhhhhhhhhh.bestaudio.m4a", 0)
    keep = _make_file(cache_dir, "iiiiiiiiiii.bestaudio.m4a", 5000)
    removed = appmod._cleanup_partial_files()
    assert removed == 3
    assert keep.exists()


# ---------------------------------------------------------------------------
# format-aware cache key (deterministic extension preference)
# ---------------------------------------------------------------------------

def test_find_cached_file_prefers_m4a(cache_dir):
    _make_file(cache_dir, "jjjjjjjjjjj.bestaudio.webm", 5000)
    _make_file(cache_dir, "jjjjjjjjjjj.bestaudio.m4a", 5000)
    found = appmod._find_cached_file("jjjjjjjjjjj")
    assert found is not None and found.suffix == ".m4a"


def test_cache_basename_includes_format_tag():
    assert appmod.AUDIO_FORMAT_TAG in appmod._cache_basename("dQw4w9WgXcQ")


# ---------------------------------------------------------------------------
# disk-full guard
# ---------------------------------------------------------------------------

def test_disk_space_guard_raises_when_full(cache_dir, monkeypatch):
    from collections import namedtuple
    Usage = namedtuple("Usage", "total used free")
    monkeypatch.setattr(appmod.shutil, "disk_usage", lambda p: Usage(100, 100, 0))
    with pytest.raises(appmod.HTTPException) as ei:
        appmod._check_disk_space()
    assert ei.value.status_code == 507


def test_disk_space_guard_passes_when_room(cache_dir, monkeypatch):
    from collections import namedtuple
    Usage = namedtuple("Usage", "total used free")
    monkeypatch.setattr(appmod.shutil, "disk_usage", lambda p: Usage(10**12, 0, 10**12))
    appmod._check_disk_space()  # should not raise


# ---------------------------------------------------------------------------
# node detection
# ---------------------------------------------------------------------------

def test_detect_node_prefers_valid_env(monkeypatch, tmp_path):
    fake = tmp_path / "node"
    fake.write_text("#!/bin/sh\n")
    fake.chmod(0o755)
    monkeypatch.setenv("NODE_PATH", str(fake))
    assert appmod._detect_node_path() == str(fake)


def test_detect_node_falls_back_to_which(monkeypatch):
    monkeypatch.delenv("NODE_PATH", raising=False)
    monkeypatch.setattr(appmod.shutil, "which", lambda b: "/opt/homebrew/bin/node")
    assert appmod._detect_node_path() == "/opt/homebrew/bin/node"


def test_detect_node_falls_back_to_candidate_paths(monkeypatch, tmp_path):
    """With nothing on NODE_PATH or PATH, the common install locations are probed."""
    fake = tmp_path / "node"
    fake.write_text("#!/bin/sh\n")
    monkeypatch.delenv("NODE_PATH", raising=False)
    monkeypatch.setattr(appmod.shutil, "which", lambda b: None)
    monkeypatch.setattr(appmod, "_NODE_CANDIDATES", ("/nonexistent/node", str(fake)))
    assert appmod._detect_node_path() == str(fake)


def test_detect_node_returns_none_when_absent(monkeypatch):
    monkeypatch.delenv("NODE_PATH", raising=False)
    monkeypatch.setattr(appmod.shutil, "which", lambda b: None)
    # Stub the candidate paths too: otherwise this asserts against whatever the
    # host has installed. CI runners ship node at /usr/local/bin/node, so probing
    # the real filesystem made the test pass locally and fail in CI.
    monkeypatch.setattr(appmod, "_NODE_CANDIDATES", ())
    assert appmod._detect_node_path() is None


# ---------------------------------------------------------------------------
# persisted LRU access metadata
# ---------------------------------------------------------------------------

def test_access_times_survive_reload(cache_dir):
    appmod._stream_access_times["kkkkkkkkkkk"] = 12345.0
    appmod._save_access_times()
    appmod._stream_access_times.clear()
    appmod._load_access_times()
    assert appmod._stream_access_times.get("kkkkkkkkkkk") == 12345.0


def test_record_access_persists(cache_dir):
    appmod._record_access("lllllllllll")
    appmod._stream_access_times.clear()
    appmod._load_access_times()
    assert "lllllllllll" in appmod._stream_access_times


# ---------------------------------------------------------------------------
# metrics & percentiles
# ---------------------------------------------------------------------------

def test_percentile_nearest_rank():
    samples = [10, 20, 30, 40, 50]
    assert appmod._percentile(samples, 50) == 30
    assert appmod._percentile(samples, 95) == 50
    assert appmod._percentile([], 50) == 0


def test_metrics_endpoint_tracks_requests(client, monkeypatch):
    monkeypatch.setattr(appmod, "_search_sync", lambda q, count=25: [])
    client.get("/api/search", params={"q": "abc"})
    m = client.get("/api/metrics").json()
    assert m["total_requests"] >= 1
    assert "endpoints" in m


def test_request_id_header_present(client):
    r = client.get("/api/health")
    assert r.headers.get("X-Request-ID")


# ---------------------------------------------------------------------------
# /api/resolve and /api/radio behaviour
# ---------------------------------------------------------------------------

def test_resolve_returns_502_when_unresolvable(client, monkeypatch):
    monkeypatch.setattr(appmod, "_resolve_sync", lambda vid: {"url": None})
    assert client.get("/api/resolve", params={"video_id": "dQw4w9WgXcQ"}).status_code == 502


def test_resolve_caches_repeat_calls(client, monkeypatch):
    calls = {"n": 0}

    def fake(video_id):
        calls["n"] += 1
        return {"url": "https://googlevideo.example/audio", "duration": 100}

    monkeypatch.setattr(appmod, "_resolve_sync", fake)
    r1 = client.get("/api/resolve", params={"video_id": "dQw4w9WgXcQ"})
    r2 = client.get("/api/resolve", params={"video_id": "dQw4w9WgXcQ"})
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json()["url"] == r2.json()["url"]
    assert calls["n"] == 1  # second call served from cache — no re-extraction
    # a different id still resolves
    client.get("/api/resolve", params={"video_id": "abcdefghijk"})
    assert calls["n"] == 2


def test_resolve_does_not_cache_failures(client, monkeypatch):
    monkeypatch.setattr(appmod, "_resolve_sync", lambda vid: {"url": None})
    assert client.get("/api/resolve", params={"video_id": "dQw4w9WgXcQ"}).status_code == 502
    assert "dQw4w9WgXcQ" not in appmod._resolve_cache


def test_radio_filters_seed_and_returns_list(client, monkeypatch):
    monkeypatch.setattr(appmod, "_radio_sync", lambda seed, limit: [
        {"id": "aaaaaaaaaaa", "title": "x", "artist": "y", "thumbnail": "t", "duration": 1},
    ])
    r = client.get("/api/radio", params={"seed": "dQw4w9WgXcQ"})
    assert r.status_code == 200
    assert isinstance(r.json(), list) and r.json()[0]["id"] == "aaaaaaaaaaa"


# ---------------------------------------------------------------------------
# health enrichment
# ---------------------------------------------------------------------------

def test_health_reports_versions_and_node(client):
    h = client.get("/api/health").json()
    assert h["status"] == "ok"
    assert "yt_dlp_version" in h
    assert "node" in h and "available" in h["node"]
    assert "uptime_seconds" in h


# ---------------------------------------------------------------------------
# single-flight download (concurrent callers share one download)
# ---------------------------------------------------------------------------

def test_single_flight_download(cache_dir, monkeypatch):
    counter = {"n": 0}

    def fake_download(vid):
        counter["n"] += 1
        time.sleep(0.2)
        (cache_dir / f"{appmod._cache_basename(vid)}.m4a").write_bytes(b"\0" * (appmod.MIN_VALID_FILE_BYTES + 10))

    monkeypatch.setattr(appmod, "_download_with_retry", fake_download)
    monkeypatch.setattr(appmod, "_is_valid_media", lambda p: True)

    async def hammer():
        transport = httpx.ASGITransport(app=appmod.app)
        async with httpx.AsyncClient(transport=transport, base_url="http://t") as ac:
            return await asyncio.gather(
                ac.get("/api/play", params={"video_id": "dQw4w9WgXcQ"}),
                ac.get("/api/play", params={"video_id": "dQw4w9WgXcQ"}),
            )

    results = asyncio.run(hammer())
    assert all(r.status_code == 200 for r in results)
    assert counter["n"] == 1  # only one actual download despite two callers


# ---------------------------------------------------------------------------
# /api/stream filename allowlist
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["short.m4a", "etcpasswd", "0123456789", "toolongvideoid.m4a"])
def test_stream_rejects_non_video_id_filename(client, name):
    # Leading segment isn't a valid 11-char video ID → 400 before any FS touch.
    assert client.get(f"/api/stream/{name}").status_code == 400


def test_stream_valid_id_name_missing_file_is_404(client):
    # Passes the allowlist + path-containment, but the file doesn't exist.
    r = client.get("/api/stream/dQw4w9WgXcQ.bestaudio.m4a")
    assert r.status_code == 404


def test_stream_serves_valid_cached_file(cache_dir, client):
    name = f"{appmod._cache_basename('dQw4w9WgXcQ')}.m4a"
    (cache_dir / name).write_bytes(b"\0" * 32)
    r = client.get(f"/api/stream/{name}")
    assert r.status_code == 200


# ---------------------------------------------------------------------------
# DELETE /api/cache rate limiting
# ---------------------------------------------------------------------------

def test_cache_delete_is_rate_limited(client, monkeypatch):
    monkeypatch.setattr(appmod, "RATE_LIMIT_CACHE_PER_MIN", 2)
    assert client.delete("/api/cache").status_code == 200
    assert client.delete("/api/cache").status_code == 200
    assert client.delete("/api/cache").status_code == 429


# ---------------------------------------------------------------------------
# GET /api/cover
# ---------------------------------------------------------------------------

def _itunes_result(track_name="Song", artist_name="Artist",
                    artwork="https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg",
                    track_time_millis=200000):
    return {
        "trackName": track_name,
        "artistName": artist_name,
        "artworkUrl100": artwork,
        "trackTimeMillis": track_time_millis,
    }


def test_cover_itunes_hit_returns_upscaled_url_and_source(client, monkeypatch):
    monkeypatch.setattr(
        appmod, "_itunes_search_sync",
        lambda term: [_itunes_result()],
    )
    r = client.get("/api/cover", params={"title": "Song", "artist": "Artist"})
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "itunes"
    assert body["cover_url"] == "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg"


def test_cover_duration_tie_break_picks_closest_track(client, monkeypatch):
    # Two candidates for the same title/artist but different releases (e.g. a
    # live version); the one whose trackTimeMillis is closest to the supplied
    # duration should win.
    candidates = [
        _itunes_result(artwork="https://x/live/100x100bb.jpg", track_time_millis=300000),
        _itunes_result(artwork="https://x/studio/100x100bb.jpg", track_time_millis=201000),
    ]
    monkeypatch.setattr(appmod, "_itunes_search_sync", lambda term: candidates)
    r = client.get("/api/cover", params={"title": "Song", "artist": "Artist", "duration": 200})
    assert r.status_code == 200
    assert r.json()["cover_url"] == "https://x/studio/600x600bb.jpg"


def test_cover_itunes_miss_falls_back_to_youtube(client, monkeypatch):
    monkeypatch.setattr(appmod, "_itunes_search_sync", lambda term: [])
    monkeypatch.setattr(
        appmod, "_youtube_thumbnail_sync",
        lambda term: "https://i.ytimg.com/vi/abc123/hqdefault.jpg",
    )
    r = client.get("/api/cover", params={"title": "Obscure Song", "artist": "Nobody"})
    assert r.status_code == 200
    body = r.json()
    assert body["source"] == "youtube"
    assert body["cover_url"] == "https://i.ytimg.com/vi/abc123/hqdefault.jpg"


def test_cover_both_miss_returns_null(client, monkeypatch):
    monkeypatch.setattr(appmod, "_itunes_search_sync", lambda term: [])
    monkeypatch.setattr(appmod, "_youtube_thumbnail_sync", lambda term: None)
    r = client.get("/api/cover", params={"title": "Nothing", "artist": "Nobody"})
    assert r.status_code == 200
    body = r.json()
    assert body["cover_url"] is None
    assert body["source"] is None


def test_cover_itunes_malformed_json_is_graceful(client, monkeypatch):
    def boom(term):
        raise ValueError("bad json")
    monkeypatch.setattr(appmod, "_itunes_search_sync", boom)
    monkeypatch.setattr(appmod, "_youtube_thumbnail_sync", lambda term: None)
    r = client.get("/api/cover", params={"title": "Song", "artist": "Artist"})
    assert r.status_code == 200
    assert r.json()["cover_url"] is None


def test_cover_itunes_network_error_is_graceful(client, monkeypatch):
    def boom(term):
        raise OSError("network down")
    monkeypatch.setattr(appmod, "_itunes_search_sync", boom)
    monkeypatch.setattr(appmod, "_youtube_thumbnail_sync", lambda term: None)
    r = client.get("/api/cover", params={"title": "Song", "artist": "Artist"})
    assert r.status_code == 200
    assert r.json()["cover_url"] is None


def test_cover_cache_hit_avoids_second_outbound_call(client, monkeypatch):
    calls = {"n": 0}

    def fake_itunes(term):
        calls["n"] += 1
        return [_itunes_result()]

    monkeypatch.setattr(appmod, "_itunes_search_sync", fake_itunes)
    r1 = client.get("/api/cover", params={"title": "Song", "artist": "Artist"})
    r2 = client.get("/api/cover", params={"title": "Song", "artist": "Artist"})
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json() == r2.json()
    assert calls["n"] == 1


def test_cover_rate_limit_returns_429(client, monkeypatch):
    monkeypatch.setattr(appmod, "RATE_LIMIT_COVER_PER_MIN", 2)
    monkeypatch.setattr(appmod, "_itunes_search_sync", lambda term: [])
    monkeypatch.setattr(appmod, "_youtube_thumbnail_sync", lambda term: None)
    assert client.get("/api/cover", params={"title": "a", "artist": "b"}).status_code == 200
    assert client.get("/api/cover", params={"title": "c", "artist": "d"}).status_code == 200
    assert client.get("/api/cover", params={"title": "e", "artist": "f"}).status_code == 429
