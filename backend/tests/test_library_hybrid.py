"""Tests for RAG Slice 2: embeddings + hybrid (BM25 + vector) retrieval.

Covers: the Embedder HTTP client seam (batching, prefixes, LRU query cache),
embed-at-sync, needs_embedding backfill (sync-time and bounded query-time),
embed-model-change invalidation, in-place migration from a real Slice-1
library_index.db, RRF fusion ordering (a case where hybrid beats each single
mode), per-result `matched` labels, lexical degradation when the embedder is
down or sqlite-vec is unavailable, /api/health embedder states with probe
caching, and the no-raw-text logging guardrail on the hybrid path.

Hermetic: the embedder is stubbed at the `Embedder._post`/`Embedder._probe`
seam with deterministic fake vectors — no network, no real IPs. sqlite-vec
itself IS exercised for real (it is a local loadable extension, not a network
dependency).
"""
import logging
import math
import os
import re
import sqlite3
import sys

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import app as appmod  # noqa: E402
import library_index as libindex  # noqa: E402


DEVICE = "33333333-3333-3333-3333-333333333333"

# Deterministic fake embedding space: a tiny synonym vocabulary mapped onto
# fixed dimensions, so "calm" and "mellow" land on the same axis (something
# BM25 can never do) while unrelated words stay orthogonal.
_SYNONYM_DIMS = {
    "mellow": 0, "calm": 0, "chill": 0, "tranquil": 0,
    "guitar": 1,
    "acoustic": 2,
    "piano": 3,
    "metal": 4, "loud": 4,
    "upbeat": 5, "energetic": 5,
    "dormant": 6,
}


def _fake_vec(text: str) -> list[float]:
    v = [0.0] * libindex.EMBED_DIM
    for w in re.findall(r"[a-z0-9]+", text.lower()):
        if w in _SYNONYM_DIMS:
            v[_SYNONYM_DIMS[w]] += 1.0
    if not any(v):
        v[-1] = 1.0  # neutral corner for out-of-vocabulary docs
    norm = math.sqrt(sum(x * x for x in v))
    return [x / norm for x in v]


class FakeEmbedder(libindex.Embedder):
    """Deterministic stub at the HTTP seam. Never touches the network."""

    def __init__(self, model="nomic-embed", fail=False, **kw):
        super().__init__(url="http://embedder.invalid/v1/embeddings",
                         model=model, **kw)
        self.fail = fail
        self.post_calls = 0
        self.probe_calls = 0
        self.posted_texts = []      # every text sent, prefix included
        self.batch_sizes = []

    def _post(self, texts):
        self.post_calls += 1
        self.batch_sizes.append(len(texts))
        if self.fail:
            raise libindex.EmbedderError("stubbed: embedder down")
        self.posted_texts.extend(texts)
        return [_fake_vec(t) for t in texts]

    def _probe(self):
        self.probe_calls += 1
        return not self.fail

    def doc_posts(self):
        return [t for t in self.posted_texts
                if t.startswith(libindex.DOC_PREFIX)]

    def query_posts(self):
        return [t for t in self.posted_texts
                if t.startswith(libindex.QUERY_PREFIX)]


@pytest.fixture
def up(client, monkeypatch):
    """A reachable fake embedder installed as the app singleton."""
    e = FakeEmbedder()
    monkeypatch.setattr(appmod, "_embedder", e)
    return e


def _track(track_id, title="Song", artist="Artist", album="Album",
           genre="rock", duration=200, playlists=None, affinity=None):
    return {
        "track_id": track_id, "title": title, "artist": artist,
        "album": album, "genre": genre, "duration": duration,
        "playlists": playlists or [], "affinity": affinity or [],
    }


def _sync(client, tracks=None, deleted=None, device_id=DEVICE):
    return client.post("/api/library/sync", json={
        "device_id": device_id, "tracks": tracks or [],
        "deleted_track_ids": deleted or []})


def _query(client, q, k=25, device_id=DEVICE):
    return client.get("/api/library/query",
                      params={"device_id": device_id, "q": q, "k": k})


# ---------------------------------------------------------------------------
# Embedder unit behaviour (batching, retry, LRU cache)
# ---------------------------------------------------------------------------

def test_requirements_pin_sqlite_vec_exactly():
    req = os.path.join(os.path.dirname(__file__), "..", "requirements.txt")
    with open(req) as f:
        content = f.read()
    assert re.search(r"^sqlite-vec==\d", content, re.M), \
        "sqlite-vec must be pinned to an exact version"


def test_embedder_batches_at_most_64_docs(tmp_path):
    idx = libindex.LibraryIndex(tmp_path / "db.sqlite")
    try:
        emb = FakeEmbedder()
        _, tracks, _ = libindex.parse_sync_payload({
            "device_id": DEVICE,
            "tracks": [_track(f"t{i}", title=f"song number {i}")
                       for i in range(130)],
        })
        out = idx.sync(DEVICE, tracks, [], embedder=emb)
        assert out["pending_embeddings"] == 0
        assert len(emb.doc_posts()) == 130
        assert all(s <= libindex.EMBED_BATCH for s in emb.batch_sizes)
        assert emb.post_calls == math.ceil(130 / libindex.EMBED_BATCH)
    finally:
        idx.close()


def test_embedder_retries_once_then_gives_up():
    calls = []

    class Flaky(FakeEmbedder):
        def _post(self, texts):
            calls.append(len(texts))
            raise libindex.EmbedderError("boom")

    with pytest.raises(libindex.EmbedderError):
        Flaky().embed_batch(["a"])
    assert len(calls) == 2  # original + exactly one retry


def test_query_embedding_lru_cache_normalizes_and_evicts():
    emb = FakeEmbedder(cache_size=2)
    emb.embed_query("  Mellow   GUITAR ")
    emb.embed_query("mellow guitar")          # cache hit (normalized key)
    assert len(emb.query_posts()) == 1
    emb.embed_query("piano")                  # fills slot 2
    emb.embed_query("metal")                  # evicts "mellow guitar"
    emb.embed_query("mellow guitar")          # miss again
    assert len(emb.query_posts()) == 4


# ---------------------------------------------------------------------------
# sync-time embedding + backfill
# ---------------------------------------------------------------------------

def test_sync_embeds_new_docs_when_embedder_up(client, up):
    r = _sync(client, [_track("t1"), _track("t2"), _track("t3")])
    assert r.status_code == 200
    assert r.json()["pending_embeddings"] == 0
    assert len(up.doc_posts()) == 3


def test_sync_marks_pending_when_embedder_down(client):
    # conftest installs a down embedder by default
    r = _sync(client, [_track("t1"), _track("t2"), _track("t3")])
    assert r.status_code == 200, "embedder outage must never fail the sync"
    assert r.json()["pending_embeddings"] == 3


def test_later_sync_backfills_pending_rows(client, monkeypatch):
    _sync(client, [_track("t1"), _track("t2"), _track("t3")])  # down → pending
    e = FakeEmbedder()
    monkeypatch.setattr(appmod, "_embedder", e)
    r = _sync(client)  # empty delta
    assert r.json()["pending_embeddings"] == 0
    assert len(e.doc_posts()) == 3


def test_changed_doc_is_reembedded_not_skipped(client, up):
    _sync(client, [_track("t1", title="banjo tune")])
    _sync(client, [_track("t1", title="fiddle tune")])
    docs = up.doc_posts()
    assert len(docs) == 2
    assert "fiddle" in docs[-1]


def test_query_time_backfill_is_bounded(client, monkeypatch):
    _sync(client, [_track(f"t{i}", title=f"guitar {i}") for i in range(3)])
    e = FakeEmbedder()
    monkeypatch.setattr(appmod, "_embedder", e)
    monkeypatch.setattr(libindex, "QUERY_BACKFILL_CAP", 1)
    r = _query(client, "guitar")
    assert r.status_code == 200
    body = r.json()
    assert body["mode"] == "hybrid"
    # hard cap honored: exactly one doc embedded during the query
    assert len(e.doc_posts()) == 1
    # matched labels: the backfilled row is visible to both retrievers, the
    # two still-pending rows can only match lexically
    labels = sorted(h["matched"] for h in body["results"])
    assert labels == ["both", "lexical", "lexical"]
    # remaining rows stay pending (observable via an empty delta sync)
    e2 = FakeEmbedder()
    monkeypatch.setattr(appmod, "_embedder", e2)
    _sync(client)
    assert len(e2.doc_posts()) == 2


# ---------------------------------------------------------------------------
# model-change invalidation (spec §3.1)
# ---------------------------------------------------------------------------

def test_embed_model_change_invalidates_and_reembeds(client, up, monkeypatch):
    _sync(client, [_track("t1"), _track("t2")])
    assert len(up.doc_posts()) == 2

    swapped = FakeEmbedder(model="nomic-embed-v2")
    monkeypatch.setattr(appmod, "_embedder", swapped)
    r = _sync(client)  # empty delta under the new model
    assert r.json()["pending_embeddings"] == 0
    assert len(swapped.doc_posts()) == 2, \
        "a model change must re-embed every row for the device"

    # index_meta records the new model + dim
    db = sqlite3.connect(appmod.LIBRARY_DB_PATH)
    model, dim = db.execute(
        "SELECT embed_model, embed_dim FROM index_meta WHERE device_id = ?",
        (DEVICE,)).fetchone()
    db.close()
    assert model == "nomic-embed-v2"
    assert dim == libindex.EMBED_DIM


# ---------------------------------------------------------------------------
# migration: a real Slice-1 database upgrades in place, no data loss
# ---------------------------------------------------------------------------

SLICE1_SCHEMA = """
    CREATE TABLE tracks(
        device_id TEXT NOT NULL,
        track_id TEXT NOT NULL,
        doc_hash TEXT NOT NULL,
        doc_text TEXT NOT NULL,
        meta_json TEXT NOT NULL DEFAULT '{}',
        updated_at REAL NOT NULL,
        needs_embedding INTEGER NOT NULL DEFAULT 1,
        UNIQUE(device_id, track_id)
    );
    CREATE VIRTUAL TABLE tracks_fts USING fts5(
        doc_text, content='tracks', content_rowid='rowid');
    CREATE TRIGGER tracks_fts_ai AFTER INSERT ON tracks BEGIN
        INSERT INTO tracks_fts(rowid, doc_text) VALUES (new.rowid, new.doc_text);
    END;
    CREATE TRIGGER tracks_fts_ad AFTER DELETE ON tracks BEGIN
        INSERT INTO tracks_fts(tracks_fts, rowid, doc_text)
        VALUES ('delete', old.rowid, old.doc_text);
    END;
    CREATE TRIGGER tracks_fts_au AFTER UPDATE OF doc_text ON tracks BEGIN
        INSERT INTO tracks_fts(tracks_fts, rowid, doc_text)
        VALUES ('delete', old.rowid, old.doc_text);
        INSERT INTO tracks_fts(rowid, doc_text) VALUES (new.rowid, new.doc_text);
    END;
    CREATE TABLE index_meta(
        device_id TEXT PRIMARY KEY,
        embed_model TEXT NOT NULL DEFAULT '',
        embed_dim INTEGER NOT NULL DEFAULT 0,
        schema_version INTEGER NOT NULL
    );
"""


def _make_slice1_db(path):
    db = sqlite3.connect(path)
    db.executescript(SLICE1_SCHEMA)
    for tid, title in (("t1", "banjo tune"), ("t2", "guitar ballad")):
        doc = libindex.compose_doc(_track(tid, title=title))
        db.execute(
            """INSERT INTO tracks(device_id, track_id, doc_hash, doc_text,
                                  meta_json, updated_at, needs_embedding)
               VALUES (?, ?, ?, ?, '{}', 0, 1)""",
            (DEVICE, tid, libindex.doc_hash(doc), doc))
    db.execute(
        "INSERT INTO index_meta(device_id, schema_version) VALUES (?, 1)",
        (DEVICE,))
    db.commit()
    db.close()


def test_slice1_db_migrates_in_place_without_data_loss(tmp_path):
    path = tmp_path / "library_index.db"
    _make_slice1_db(path)
    idx = libindex.LibraryIndex(path)
    try:
        assert idx.track_count(DEVICE) == 2
        hits = idx.query(DEVICE, "banjo", 10)["results"]
        assert [h["track_id"] for h in hits] == ["t1"]
        # schema bumped, vec table present
        db = sqlite3.connect(path)
        assert db.execute("PRAGMA user_version").fetchone()[0] \
            == libindex.SCHEMA_VERSION
        names = {r[0] for r in db.execute(
            "SELECT name FROM sqlite_master WHERE name LIKE 'track_vecs%'")}
        db.close()
        assert names, "track_vecs virtual table missing after migration"
        # pre-existing rows are pending and backfillable
        emb = FakeEmbedder()
        out = idx.sync(DEVICE, [], [], embedder=emb)
        assert out["pending_embeddings"] == 0
        assert len(emb.doc_posts()) == 2
        # hybrid retrieval works on the migrated data
        res = idx.query(DEVICE, "guitar", 10, embedder=emb)
        assert res["mode"] == "hybrid"
        assert "t2" in [h["track_id"] for h in res["results"]]
    finally:
        idx.close()


# ---------------------------------------------------------------------------
# hybrid retrieval: RRF ordering + matched labels
# ---------------------------------------------------------------------------

def _seed_rrf_corpus(client):
    _sync(client, [
        # matches "calm guitar" both lexically (guitar) and semantically
        # (mellow ≈ calm in the fake embedding space)
        _track("both_doc", title="mellow guitar instrumental"),
        # crushes BM25 for "guitar" but has no calm/mellow semantics
        _track("lex_doc", title="guitar guitar guitar", artist="guitar band",
               playlists=["guitar practice"]),
        # BM25 can never find this for "calm guitar"; only the vector can
        _track("vec_doc", title="tranquil chill piece"),
        # noise
        _track("noise", title="loud metal anthem"),
    ])


def test_hybrid_rrf_beats_each_single_mode(client, up):
    _seed_rrf_corpus(client)
    body = _query(client, "calm guitar").json()
    assert body["mode"] == "hybrid"
    hits = {h["track_id"]: h for h in body["results"]}
    ids = [h["track_id"] for h in body["results"]]

    # Lexical alone ranks lex_doc first (see below); vector alone can't see
    # lex_doc's BM25 strength. Fusion puts the doc that is good on BOTH lists
    # on top — that ordering is achievable by neither single mode.
    assert ids[0] == "both_doc"
    # vector-only discovery: no query term appears in vec_doc's text
    assert "vec_doc" in ids
    assert hits["vec_doc"]["matched"] == "vector"
    assert hits["both_doc"]["matched"] == "both"
    # scores are the RRF fusion scores, descending
    scores = [h["score"] for h in body["results"]]
    assert scores == sorted(scores, reverse=True)


def test_lexical_mode_alone_ranks_differently(client, up, monkeypatch):
    _seed_rrf_corpus(client)
    up.fail = True  # embedder goes down after sync
    body = _query(client, "calm guitar").json()
    assert body["mode"] == "lexical"
    ids = [h["track_id"] for h in body["results"]]
    assert ids[0] == "lex_doc"          # BM25's pick, not the hybrid's
    assert "vec_doc" not in ids         # lexical can't discover it
    assert all(h["matched"] == "lexical" for h in body["results"])


# ---------------------------------------------------------------------------
# degradation paths — never fail the query
# ---------------------------------------------------------------------------

def test_query_degrades_to_lexical_when_embedder_down(client, up):
    _sync(client, [_track("t1", title="midnight guitar")])
    up.fail = True
    r = _query(client, "guitar")
    assert r.status_code == 200
    body = r.json()
    assert body["mode"] == "lexical"
    assert [h["track_id"] for h in body["results"]] == ["t1"]


def test_query_degrades_when_sqlite_vec_unavailable(client, monkeypatch):
    monkeypatch.setattr(libindex, "VEC_AVAILABLE", False)
    appmod._reset_library_index()
    e = FakeEmbedder()
    monkeypatch.setattr(appmod, "_embedder", e)
    r = _sync(client, [_track("t1", title="midnight guitar")])
    assert r.status_code == 200
    assert r.json()["pending_embeddings"] == 1  # nowhere to store vectors
    q = _query(client, "guitar")
    assert q.status_code == 200
    assert q.json()["mode"] == "lexical"
    assert len(q.json()["results"]) == 1


def test_deleted_tracks_drop_their_vectors(client, up):
    _sync(client, [_track("t1", title="guitar one"),
                   _track("t2", title="guitar two")])
    idx = appmod._get_library_index()
    assert idx.vector_count() == 2
    _sync(client, deleted=["t1"])
    assert idx.vector_count() == 1
    client.request("DELETE", "/api/library", params={"device_id": DEVICE})
    assert idx.vector_count() == 0


# ---------------------------------------------------------------------------
# /api/health embedder probe
# ---------------------------------------------------------------------------

def test_health_reports_embedder_ok_and_down(client, up):
    h = client.get("/api/health").json()
    assert h["library_index"]["embedder"] == "ok"
    down = FakeEmbedder(fail=True)
    # fresh instance → fresh probe cache
    import app as appmod_local
    appmod_local._embedder = down
    try:
        h = client.get("/api/health").json()
        assert h["library_index"]["embedder"] == "down"
    finally:
        appmod_local._embedder = up


def test_health_probe_is_cached_not_hammered(client, up):
    client.get("/api/health")
    client.get("/api/health")
    client.get("/api/health")
    assert up.probe_calls <= 1


# ---------------------------------------------------------------------------
# logging guardrail holds on the hybrid path
# ---------------------------------------------------------------------------

def test_hybrid_path_never_logs_raw_text(client, up, caplog):
    secret_title = "quixotic-lighthouse-serenade-7714"
    secret_query = "porcupine-nebula-search-2093"
    with caplog.at_level(logging.DEBUG):
        _sync(client, [_track("t1", title=secret_title)])
        _query(client, secret_query)
    server_text = "\n".join(
        r.getMessage() for r in caplog.records
        if not r.name.startswith(("httpx", "httpcore")))
    assert secret_title not in server_text
    assert secret_query not in server_text
