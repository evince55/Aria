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
    monkeypatch.setattr(appmod, "_search_sync", lambda q: [])
    for _ in range(3):
        assert client.get("/api/search", params={"q": "hello"}).status_code == 200
    assert client.get("/api/search", params={"q": "hello"}).status_code == 429


def test_rate_limit_is_per_ip(client, monkeypatch):
    # Behind one trusted proxy, X-Forwarded-For is honoured as the client IP.
    monkeypatch.setattr(appmod, "TRUSTED_PROXY_COUNT", 1)
    monkeypatch.setattr(appmod, "RATE_LIMIT_SEARCH_PER_MIN", 1)
    monkeypatch.setattr(appmod, "_search_sync", lambda q: [])
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
    monkeypatch.setattr(appmod, "_search_sync", lambda q: [])
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "1.1.1.1"}).status_code == 200
    # A rotating spoofed XFF does NOT escape the limit — same real peer.
    assert client.get("/api/search", params={"q": "a"}, headers={"X-Forwarded-For": "9.9.9.9"}).status_code == 429


def test_client_ip_picks_hop_left_of_trusted_proxies(monkeypatch):
    monkeypatch.setattr(appmod, "TRUSTED_PROXY_COUNT", 1)

    class _Req:
        headers = {"x-forwarded-for": "203.0.113.7, 10.0.0.1"}
        client = None

    # Rightmost hop (10.0.0.1) is our proxy; the real client is just left of it.
    assert appmod._client_ip(_Req()) == "203.0.113.7"


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


def test_eviction_respects_grace_and_current(cache_dir, monkeypatch):
    monkeypatch.setattr(appmod, "MAX_CACHE_GB", 1.0 / (1024 * 1024))
    monkeypatch.setattr(appmod, "CACHE_EVICT_GRACE_SECONDS", 300)
    f = _make_file(cache_dir, "ccccccccccc.bestaudio.m4a", 2 * 1024 * 1024)
    appmod._stream_access_times["ccccccccccc"] = time.time()  # just accessed -> within grace
    appmod._total_cache_bytes = f.stat().st_size
    asyncio.run(appmod._evict_if_needed())
    assert f.exists()  # protected by grace window


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


def test_detect_node_returns_none_when_absent(monkeypatch):
    monkeypatch.delenv("NODE_PATH", raising=False)
    monkeypatch.setattr(appmod.shutil, "which", lambda b: None)
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
    monkeypatch.setattr(appmod, "_search_sync", lambda q: [])
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
