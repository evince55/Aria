"""Tests for the per-device library search index (Slice 1: lexical/BM25 only).

Covers: delta sync upsert/skip/delete semantics, payload caps (bytes + track
count), disk-space guard wiring, FTS5 BM25 ranking, FTS5 query-syntax
escaping (injection surface), device-scoped isolation, the privacy delete
endpoint, API-key auth, /api/health enrichment, observability-middleware
metrics coverage, rate limiting, and the no-raw-text logging guardrail.

Hermetic: everything runs against a temp SQLite file; no network, no real IPs.
"""
import logging
import os
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import app as appmod  # noqa: E402
import library_index as libindex  # noqa: E402


DEVICE = "11111111-1111-1111-1111-111111111111"
OTHER_DEVICE = "22222222-2222-2222-2222-222222222222"


def _track(track_id, title="Song", artist="Artist", album="Album",
           genre="rock", duration=200, playlists=None, affinity=None):
    return {
        "track_id": track_id,
        "title": title,
        "artist": artist,
        "album": album,
        "genre": genre,
        "duration": duration,
        "playlists": playlists or [],
        "affinity": affinity or [],
    }


def _sync(client, tracks=None, deleted=None, device_id=DEVICE, headers=None):
    body = {"device_id": device_id, "tracks": tracks or [],
            "deleted_track_ids": deleted or []}
    return client.post("/api/library/sync", json=body, headers=headers or {})


# ---------------------------------------------------------------------------
# doc composition (spec §4)
# ---------------------------------------------------------------------------

def test_compose_doc_layout_and_lowercase():
    doc = libindex.compose_doc(_track("t1", title="Hey JUDE", artist="The Beatles",
                                      genre=None, duration=100,
                                      playlists=["Road Trip"], affinity=["favorite"]))
    lines = doc.splitlines()
    assert lines[0] == "title: hey jude"
    assert lines[1] == "artist: the beatles"
    assert "genre: unknown" in lines
    assert "duration: short" in lines
    assert "playlists: road trip" in lines
    assert "affinity: favorite" in lines


@pytest.mark.parametrize("seconds,bucket", [
    (0, "short"), (149, "short"), (150, "medium"), (360, "medium"),
    (361, "long"), (3600, "long"), (None, "medium"),
])
def test_compose_doc_duration_buckets(seconds, bucket):
    doc = libindex.compose_doc(_track("t1", duration=seconds))
    assert f"duration: {bucket}" in doc


def test_doc_hash_is_sha256_of_doc_text():
    import hashlib
    fields = _track("t1")
    doc = libindex.compose_doc(fields)
    assert libindex.doc_hash(doc) == hashlib.sha256(doc.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# storage bootstrap
# ---------------------------------------------------------------------------

def test_index_uses_wal_and_records_schema_version(tmp_path):
    idx = libindex.LibraryIndex(tmp_path / "library_index.db")
    try:
        assert idx.journal_mode() == "wal"
        assert idx.schema_version() == libindex.SCHEMA_VERSION
    finally:
        idx.close()


# ---------------------------------------------------------------------------
# sync: upsert / delta / delete
# ---------------------------------------------------------------------------

def test_sync_upserts_new_tracks(client):
    r = _sync(client, [_track("t1"), _track("t2", title="Other")])
    assert r.status_code == 200
    body = r.json()
    assert body["indexed"] == 2
    assert body["skipped"] == 0
    assert body["deleted"] == 0
    # conftest's embedder is down, so newly indexed rows stay pending
    # (Slice 2 semantics; the hybrid tests cover the embedded-at-sync case).
    assert body["pending_embeddings"] == 2


def test_sync_delta_skips_unchanged_doc_hash(client):
    assert _sync(client, [_track("t1"), _track("t2")]).json()["indexed"] == 2
    # identical payload → nothing re-indexed
    again = _sync(client, [_track("t1"), _track("t2")]).json()
    assert again["indexed"] == 0 and again["skipped"] == 2
    # one changed field → only that row re-indexed
    third = _sync(client, [_track("t1", title="Changed"), _track("t2")]).json()
    assert third["indexed"] == 1 and third["skipped"] == 1


def test_sync_deletes_tracks(client):
    _sync(client, [_track("t1"), _track("t2")])
    r = _sync(client, deleted=["t1", "never-existed"])
    assert r.status_code == 200
    assert r.json()["deleted"] == 1
    h = client.get("/api/health").json()
    assert h["library_index"]["tracks"] == 1


def test_sync_rejects_over_track_cap(client, monkeypatch):
    monkeypatch.setattr(libindex, "MAX_SYNC_TRACKS", 2)
    r = _sync(client, [_track(f"t{i}") for i in range(3)])
    assert r.status_code == 413


def test_sync_rejects_oversize_payload(client, monkeypatch):
    monkeypatch.setattr(appmod, "MAX_SYNC_BYTES", 64)
    r = _sync(client, [_track("t1", title="x" * 200)])
    assert r.status_code == 413


@pytest.mark.parametrize("body", [
    {"tracks": []},                                   # missing device_id
    {"device_id": "", "tracks": []},                  # empty device_id
    {"device_id": "bad id!", "tracks": []},           # invalid device_id chars
    {"device_id": DEVICE, "tracks": "not-a-list"},    # tracks wrong type
    {"device_id": DEVICE, "tracks": [{"title": "no track_id"}]},
])
def test_sync_invalid_payload_is_400(client, body):
    assert client.post("/api/library/sync", json=body).status_code == 400


def test_sync_not_json_is_400(client):
    r = client.post("/api/library/sync", content=b"\x00 not json",
                    headers={"Content-Type": "application/json"})
    assert r.status_code == 400


def test_sync_checks_disk_space_before_upsert(client, monkeypatch):
    from fastapi import HTTPException

    def full(_needed=0):
        raise HTTPException(status_code=507, detail="full")

    monkeypatch.setattr(appmod, "_check_disk_space", full)
    assert _sync(client, [_track("t1")]).status_code == 507
    monkeypatch.setattr(appmod, "_check_disk_space", lambda needed=0: None)
    assert client.get("/api/health").json()["library_index"]["tracks"] == 0


# ---------------------------------------------------------------------------
# query: BM25 ranking + shape
# ---------------------------------------------------------------------------

def test_query_returns_lexical_mode_and_shape(client):
    _sync(client, [_track("t1", title="Midnight Guitar", genre="acoustic")])
    r = client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": "guitar", "k": 5})
    assert r.status_code == 200
    body = r.json()
    assert body["mode"] == "lexical"
    assert len(body["results"]) == 1
    hit = body["results"][0]
    assert hit["track_id"] == "t1"
    assert hit["matched"] == "lexical"
    assert isinstance(hit["score"], float)


def test_query_ranks_stronger_match_first(client):
    _sync(client, [
        _track("weak", title="Guitar Song"),
        _track("strong", title="Guitar Guitar", artist="Guitar Band",
               playlists=["guitar practice"]),
        _track("miss", title="Piano Piece", artist="Someone", genre="classical"),
    ])
    r = client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": "guitar", "k": 10}).json()
    ids = [h["track_id"] for h in r["results"]]
    assert ids[0] == "strong"
    assert "weak" in ids
    assert "miss" not in ids


def test_query_matches_affinity_vocabulary(client):
    _sync(client, [
        _track("old", title="Forgotten Tune", affinity=["dormant"]),
        _track("new", title="Daily Driver", affinity=["favorite", "frequent"]),
    ])
    r = client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": "dormant", "k": 10}).json()
    assert [h["track_id"] for h in r["results"]] == ["old"]


def test_query_respects_k(client):
    _sync(client, [_track(f"t{i}", title=f"guitar {i}") for i in range(5)])
    r = client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": "guitar", "k": 2}).json()
    assert len(r["results"]) == 2


def test_query_is_scoped_per_device(client):
    _sync(client, [_track("mine", title="guitar")], device_id=DEVICE)
    _sync(client, [_track("theirs", title="guitar")], device_id=OTHER_DEVICE)
    r = client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": "guitar"}).json()
    assert [h["track_id"] for h in r["results"]] == ["mine"]


def test_query_updated_doc_is_searchable_under_new_text_only(client):
    _sync(client, [_track("t1", title="banjo tune")])
    _sync(client, [_track("t1", title="fiddle tune")])
    hits = client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "banjo"}).json()["results"]
    assert hits == []
    hits = client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "fiddle"}).json()["results"]
    assert [h["track_id"] for h in hits] == ["t1"]


@pytest.mark.parametrize("evil", [
    'guitar" OR device_id:*',
    "NEAR(a b, 2)",
    "title: ^ * ( ) -",
    '"unbalanced',
    "a AND b) OR (c",
    "col:val*",
    "*",
    "-",
    "   ",
])
def test_query_fts5_syntax_is_escaped_not_executed(client, evil):
    """FTS5 query syntax in user input is an injection surface: it must never
    raise an OperationalError (500) nor act as column filters / operators."""
    _sync(client, [_track("t1", title="guitar")])
    r = client.get("/api/library/query", params={"device_id": DEVICE, "q": evil})
    assert r.status_code == 200
    assert r.json()["mode"] == "lexical"


def test_query_terms_are_or_matched_for_recall(client):
    # A multi-term NL query must not require every term (AND) — "mellow
    # late-night guitar" should still surface a track matching one term.
    _sync(client, [_track("t1", title="guitar ballad")])
    r = client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": "mellow late-night guitar"}).json()
    assert [h["track_id"] for h in r["results"]] == ["t1"]


def test_query_invalid_device_id_is_400(client):
    assert client.get("/api/library/query",
                      params={"device_id": "nope!", "q": "x"}).status_code == 400


# ---------------------------------------------------------------------------
# delete (privacy endpoint)
# ---------------------------------------------------------------------------

def test_delete_drops_all_rows_for_device_only(client):
    _sync(client, [_track("t1"), _track("t2")], device_id=DEVICE)
    _sync(client, [_track("t3")], device_id=OTHER_DEVICE)
    r = client.request("DELETE", "/api/library", params={"device_id": DEVICE})
    assert r.status_code == 200
    assert r.json()["deleted"] == 2
    assert client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "song"}).json()["results"] == []
    other = client.get("/api/library/query",
                       params={"device_id": OTHER_DEVICE, "q": "song"}).json()
    assert len(other["results"]) == 1
    assert client.get("/api/health").json()["library_index"]["tracks"] == 1


def test_delete_missing_device_is_zero_not_error(client):
    r = client.request("DELETE", "/api/library", params={"device_id": DEVICE})
    assert r.status_code == 200
    assert r.json()["deleted"] == 0


# ---------------------------------------------------------------------------
# auth + rate limiting
# ---------------------------------------------------------------------------

def test_library_endpoints_require_api_key_when_set(client, monkeypatch):
    monkeypatch.setattr(appmod, "ARIA_API_KEY", "sekret")
    assert _sync(client, [_track("t1")]).status_code == 401
    assert client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "x"}).status_code == 401
    assert client.request("DELETE", "/api/library",
                          params={"device_id": DEVICE}).status_code == 401
    # with the key, all three pass auth
    hdr = {"X-API-Key": "sekret"}
    assert _sync(client, [_track("t1")], headers=hdr).status_code == 200
    assert client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "x"},
                      headers=hdr).status_code == 200
    assert client.request("DELETE", "/api/library",
                          params={"device_id": DEVICE}, headers=hdr).status_code == 200


def test_library_rate_limit_returns_429(client, monkeypatch):
    monkeypatch.setattr(appmod, "RATE_LIMIT_LIBRARY_PER_MIN", 2)
    assert client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "x"}).status_code == 200
    assert client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "x"}).status_code == 200
    assert client.get("/api/library/query",
                      params={"device_id": DEVICE, "q": "x"}).status_code == 429


# ---------------------------------------------------------------------------
# health + metrics observability
# ---------------------------------------------------------------------------

def test_health_reports_library_index(client):
    h = client.get("/api/health").json()
    # conftest stubs the embedder down; Slice 2's hybrid tests cover "ok".
    assert h["library_index"] == {"tracks": 0, "embedder": "down"}
    _sync(client, [_track("t1")])
    h = client.get("/api/health").json()
    assert h["library_index"]["tracks"] == 1


def test_metrics_middleware_covers_library_routes(client):
    _sync(client, [_track("t1")])
    client.get("/api/library/query", params={"device_id": DEVICE, "q": "song"})
    client.request("DELETE", "/api/library", params={"device_id": DEVICE})
    eps = client.get("/api/metrics").json()["endpoints"]
    for path in ("/api/library/sync", "/api/library/query", "/api/library"):
        assert path in eps, f"middleware did not record {path}"
        assert eps[path]["count"] >= 1
        assert "p95_ms" in eps[path]


# ---------------------------------------------------------------------------
# logging guardrail (spec §3.4): never log raw query text or doc_text
# ---------------------------------------------------------------------------

def test_raw_query_and_doc_text_never_logged(client, caplog):
    secret_title = "zanzibar-unicorn-melody-9931"
    secret_query = "walrus-tangerine-search-4482"
    with caplog.at_level(logging.DEBUG):
        _sync(client, [_track("t1", title=secret_title, artist=secret_title)])
        client.get("/api/library/query",
                   params={"device_id": DEVICE, "q": secret_query})
    # Scope to the server's own loggers ("aria", "aria.library_index", uvicorn
    # would be caught here too): the test client's httpx logger echoes request
    # URLs client-side, which is not the guardrail surface. Server-side access
    # logging is disabled in aria-backend.service (--no-access-log).
    server_text = "\n".join(
        r.getMessage() for r in caplog.records
        if not r.name.startswith(("httpx", "httpcore"))
    )
    assert secret_title not in server_text
    assert secret_query not in server_text


def test_service_unit_disables_uvicorn_access_log():
    """uvicorn's access line would log the full /api/library/query?q=... URL
    into journald — the deploy unit must run with --no-access-log."""
    unit = os.path.join(os.path.dirname(__file__), "..", "aria-backend.service")
    with open(unit) as f:
        content = f.read()
    assert "--no-access-log" in content
