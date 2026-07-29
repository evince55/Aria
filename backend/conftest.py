"""Shared pytest fixtures for the Aria backend test suite.

These tests never touch the network: every yt-dlp entry point
(`_download_sync` / `_resolve_sync` / `_radio_sync` / `_search_sync`) is
monkeypatched per-test. A throwaway cache directory is injected so eviction,
validation, and LRU-persistence behaviour can be exercised hermetically.
"""
import os
import sys

import pytest

# Make `import app` work regardless of pytest's rootdir.
sys.path.insert(0, os.path.dirname(__file__))

import app as appmod  # noqa: E402


@pytest.fixture
def cache_dir(tmp_path, monkeypatch):
    """Redirect the module-level cache dir at a fresh temp path and reset all
    in-process state (metrics, rate-limit log, LRU table, byte counter,
    library index)."""
    d = tmp_path / "song_cache"
    d.mkdir()
    monkeypatch.setattr(appmod, "CACHE_DIR", d)
    # Point the library index at a throwaway DB so tests never touch (or
    # create) a real ./library_index.db, and reset the lazy singleton.
    monkeypatch.setattr(appmod, "LIBRARY_DB_PATH", tmp_path / "library_index.db")
    appmod._reset_library_index()
    appmod._total_cache_bytes = 0
    appmod._stream_access_times.clear()
    appmod._request_log.clear()
    appmod._download_events.clear()
    appmod._search_cache.clear()
    appmod._resolve_cache.clear()
    appmod._cover_cache.clear()
    appmod._reset_metrics()
    yield d
    appmod._reset_library_index()


@pytest.fixture
def client(cache_dir):
    from fastapi.testclient import TestClient

    with TestClient(appmod.app) as c:
        yield c
