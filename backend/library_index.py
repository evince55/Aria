"""Per-device library search index for "Ask Your Library" (RAG Slice 2).

Hybrid retrieval: SQLite FTS5 BM25 + sqlite-vec cosine KNN fused with
Reciprocal Rank Fusion (spec §3.3). The join contract laid down in Slice 1:

- `tracks` keeps its implicit integer rowid as the join key for vectors —
  `track_vecs` (a sqlite-vec vec0 virtual table, 768-dim float32, cosine)
  is rowid-joined to it.
- `tracks.needs_embedding` is the backfill state: 1 until a row's vector is
  stored. Rows synced while the embedder is down stay pending and are picked
  up by later syncs or a BOUNDED query-time backfill (QUERY_BACKFILL_CAP).
- `index_meta(device_id, embed_model, embed_dim, schema_version)` pins the
  embedding model per device; a model change invalidates that device's
  vectors for lazy re-embedding (spec §3.1 model-versioning story).

Degradation contract: if the embedder is unreachable OR the sqlite-vec
extension is unavailable, queries serve BM25-only with `mode: "lexical"` —
a sleeping GPU box must never fail a query.

Embeddings come from an OpenAI-format `/v1/embeddings` endpoint (llama-swap
serving nomic-embed-text-v1.5, 768-dim) at env `ARIA_EMBED_URL`. nomic-embed
is trained with task prefixes, so documents are embedded as
"search_document: ..." and queries as "search_query: ..." (model card).

Document composition (spec §4 — the retrieval-quality lever)
------------------------------------------------------------
One document per track, one line per field, all lowercase:

    title: {title}
    artist: {artist}
    album: {album}
    genre: {genre or "unknown"}
    duration: {short|medium|long}     # <2:30 / 2:30-6:00 / >6:00
    playlists: {names of playlists containing the track}
    affinity: {flags}                 # favorite / recent / frequent / dormant

Controlled affinity vocabulary (client-computed, coarse buckets so the doc
hash does not churn on every play event):

    favorite  — the track is favorited
    recent    — played within the last 7 days
    frequent  — in the top play-count quartile
    dormant   — not played in 60+ days ("stuff I haven't played in a while")

`doc_hash` = SHA-256 hex of the composed doc_text. The client computes it for
delta sync; the server recomposes the doc from the submitted fields and its
own hash is authoritative (a mismatching client hash is counted, not trusted).

Privacy guardrail (spec §3.4): this module must NEVER log raw query text or
doc_text — library contents are personal data. Log lengths, counts, latency,
and mode only.
"""
import hashlib
import json
import logging
import os
import re
import sqlite3
import struct
import threading
import time
import urllib.error
import urllib.request
from collections import OrderedDict
from pathlib import Path
from typing import Optional

# The loadable vector-search extension (Alex Garcia's asg017/sqlite-vec,
# pinned in requirements.txt). Treated as OPTIONAL at runtime: if the module
# is missing or the extension fails to load, vector search is unavailable and
# every query degrades to BM25-only ("lexical" mode) instead of failing.
try:
    import sqlite_vec
    VEC_AVAILABLE = True
except ImportError:  # pragma: no cover - exercised via monkeypatch in tests
    sqlite_vec = None
    VEC_AVAILABLE = False

logger = logging.getLogger("aria.library_index")

SCHEMA_VERSION = 2

# --- embedding configuration (spec §3.2) -----------------------------------
EMBED_URL_ENV = "ARIA_EMBED_URL"
DEFAULT_EMBED_URL = "http://127.0.0.1:8090/v1/embeddings"
EMBED_MODEL = "nomic-embed"          # llama-swap model alias
EMBED_DIM = 768                      # nomic-embed-text-v1.5, full matryoshka
EMBED_BATCH = 64                     # max docs per /v1/embeddings call
EMBED_TIMEOUT_S = 10.0
PROBE_TIMEOUT_S = 3.0
HEALTH_PROBE_TTL_S = 30.0            # cache the health probe result this long
QUERY_CACHE_SIZE = 256               # in-process LRU for query embeddings
# nomic-embed-text is prefix-trained: retrieval quality drops without these.
DOC_PREFIX = "search_document: "
QUERY_PREFIX = "search_query: "

# --- hybrid retrieval (spec §3.3) -------------------------------------------
RRF_K = 60                           # Reciprocal Rank Fusion constant
CANDIDATE_POOL = 50                  # BM25 top-50 + vector top-50 pre-fusion
# Query-time backfill is HARD-CAPPED per request so a big pending backlog can
# never turn one query into an unbounded embedding loop.
QUERY_BACKFILL_CAP = 128

# Sync abuse caps (spec §3.3): payload bytes are enforced by the route (before
# JSON parse); the track-count cap is enforced here during payload validation.
MAX_SYNC_BYTES = 2 * 1024 * 1024
MAX_SYNC_TRACKS = 5000

# device_id is a client-generated UUID; track_id is an opaque client ID.
DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
MAX_TRACK_ID_LEN = 256
MAX_FIELD_LEN = 512          # per text field, pre-composition
MAX_LIST_ITEMS = 100         # playlists / affinity entries per track

# Duration buckets (seconds): <2:30 short, 2:30-6:00 medium, >6:00 long.
_DURATION_SHORT_MAX = 150
_DURATION_MEDIUM_MAX = 360


class InvalidPayload(ValueError):
    """Sync payload is malformed (route maps this to HTTP 400)."""


class PayloadTooLarge(ValueError):
    """Sync payload exceeds a cap (route maps this to HTTP 413)."""


def _clean_text(value, default: str = "") -> str:
    if value is None:
        return default
    if not isinstance(value, str):
        value = str(value)
    cleaned = re.sub(r"\s+", " ", value).strip().lower()
    return cleaned[:MAX_FIELD_LEN] or default


def _clean_list(value) -> list[str]:
    if not isinstance(value, (list, tuple)):
        return []
    items = [_clean_text(v) for v in value[:MAX_LIST_ITEMS]]
    return [i for i in items if i]


def _duration_bucket(seconds) -> str:
    if not isinstance(seconds, (int, float)):
        return "medium"
    if seconds <= _DURATION_SHORT_MAX - 1:
        return "short"
    if seconds <= _DURATION_MEDIUM_MAX:
        return "medium"
    return "long"


def compose_doc(fields: dict) -> str:
    """Compose the canonical searchable document for one track (spec §4)."""
    return "\n".join([
        f"title: {_clean_text(fields.get('title'))}",
        f"artist: {_clean_text(fields.get('artist'))}",
        f"album: {_clean_text(fields.get('album'))}",
        f"genre: {_clean_text(fields.get('genre'), default='unknown')}",
        f"duration: {_duration_bucket(fields.get('duration'))}",
        f"playlists: {' '.join(_clean_list(fields.get('playlists')))}",
        f"affinity: {' '.join(_clean_list(fields.get('affinity')))}",
    ])


def doc_hash(doc_text: str) -> str:
    return hashlib.sha256(doc_text.encode("utf-8")).hexdigest()


def sanitize_fts_query(q: str) -> str:
    """Turn arbitrary user text into a safe FTS5 MATCH expression.

    FTS5 query syntax (column filters, AND/OR/NOT/NEAR, *, ^, parens, quotes)
    is an injection surface: raw user text can raise OperationalError (a 500)
    or act as operators. We keep only alphanumeric word tokens and wrap each
    in double quotes (a quoted FTS5 string is never an operator), OR-joined —
    a multi-term natural-language query should surface partial matches and
    let BM25 rank them, not demand every term be present.

    Returns "" when nothing tokenizable remains (caller returns no results).
    """
    tokens = re.findall(r"[A-Za-z0-9À-￿]+", q)
    if not tokens:
        return ""
    return " OR ".join(f'"{t}"' for t in tokens[:32])


def validate_device_id(device_id) -> str:
    if not isinstance(device_id, str) or not DEVICE_ID_RE.match(device_id or ""):
        raise InvalidPayload("invalid or missing device_id")
    return device_id


def parse_sync_payload(payload) -> tuple[str, list[dict], list[str]]:
    """Validate a /api/library/sync body → (device_id, tracks, deleted_ids).

    Each returned track dict is {track_id, doc_text, doc_hash, client_hash,
    meta_json} — fully composed, ready for upsert.
    """
    if not isinstance(payload, dict):
        raise InvalidPayload("body must be a JSON object")
    device_id = validate_device_id(payload.get("device_id"))

    raw_tracks = payload.get("tracks", [])
    if not isinstance(raw_tracks, list):
        raise InvalidPayload("tracks must be a list")
    if len(raw_tracks) > MAX_SYNC_TRACKS:
        raise PayloadTooLarge(f"too many tracks (max {MAX_SYNC_TRACKS})")

    raw_deleted = payload.get("deleted_track_ids", [])
    if not isinstance(raw_deleted, list):
        raise InvalidPayload("deleted_track_ids must be a list")

    tracks = []
    for entry in raw_tracks:
        if not isinstance(entry, dict):
            raise InvalidPayload("each track must be an object")
        track_id = entry.get("track_id")
        if not isinstance(track_id, str) or not track_id.strip() \
                or len(track_id) > MAX_TRACK_ID_LEN:
            raise InvalidPayload("each track needs a valid track_id")
        text = compose_doc(entry)
        meta = {
            k: entry.get(k)
            for k in ("title", "artist", "album", "genre", "duration")
            if entry.get(k) is not None
        }
        tracks.append({
            "track_id": track_id,
            "doc_text": text,
            "doc_hash": doc_hash(text),
            "client_hash": entry.get("doc_hash"),
            "meta_json": json.dumps(meta, ensure_ascii=False),
        })

    deleted = []
    for tid in raw_deleted:
        if not isinstance(tid, str) or not tid or len(tid) > MAX_TRACK_ID_LEN:
            raise InvalidPayload("deleted_track_ids entries must be track ids")
        deleted.append(tid)

    return device_id, tracks, deleted


class EmbedderError(RuntimeError):
    """The embedding endpoint is unreachable or returned garbage."""


class Embedder:
    """OpenAI-format /v1/embeddings client for the homelab llama-swap box.

    - batches of at most EMBED_BATCH texts per call, EMBED_TIMEOUT_S timeout,
      exactly one retry; callers treat EmbedderError as "mark pending and
      move on" — an embedder outage must never fail a sync or a query.
    - query embeddings are cached in-process (LRU, QUERY_CACHE_SIZE) keyed by
      normalized query text.
    - `status()` is the /api/health probe: a cheap GET against the sibling
      /v1/models route, cached for HEALTH_PROBE_TTL_S so polling the health
      endpoint never hammers (or wakes) the GPU box. Real embed calls also
      refresh the cached status for free.

    Privacy guardrail (spec §3.4): no method of this class ever logs the
    texts it embeds.

    Tests stub the network at the `_post` / `_probe` seams.
    """

    def __init__(self, url: Optional[str] = None, model: str = EMBED_MODEL,
                 dim: int = EMBED_DIM, timeout: float = EMBED_TIMEOUT_S,
                 batch_size: int = EMBED_BATCH,
                 cache_size: int = QUERY_CACHE_SIZE):
        self.url = url or os.environ.get(EMBED_URL_ENV, DEFAULT_EMBED_URL)
        self.model = model
        self.dim = dim
        self.timeout = timeout
        self.batch_size = batch_size
        self.cache_size = cache_size
        self._lock = threading.Lock()
        self._query_cache: OrderedDict[str, list[float]] = OrderedDict()
        self._status: Optional[bool] = None
        self._status_at = 0.0

    # -- network seams (stubbed in tests) ------------------------------------

    def _post(self, texts: list[str]) -> list[list[float]]:
        """One POST to /v1/embeddings. Raises EmbedderError on any failure.
        Error messages carry exception types only — never the texts."""
        payload = json.dumps({"model": self.model, "input": texts})
        req = urllib.request.Request(
            self.url, data=payload.encode("utf-8"),
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = json.load(resp)
        except Exception as e:
            raise EmbedderError(
                f"embed request failed: {type(e).__name__}") from e
        data = body.get("data") if isinstance(body, dict) else None
        if not isinstance(data, list) or len(data) != len(texts):
            raise EmbedderError("embed response shape mismatch")
        data = sorted(data, key=lambda d: d.get("index", 0))
        vecs = [d.get("embedding") for d in data]
        for v in vecs:
            if not isinstance(v, list) or len(v) != self.dim:
                raise EmbedderError(
                    f"embedding dimension mismatch (want {self.dim})")
        return vecs

    def _probe(self) -> bool:
        """Cheap reachability check that does NOT force a model load:
        GET the sibling /v1/models route. Any HTTP response (even 404 from a
        server that lacks the route) proves the endpoint is up."""
        probe_url = self.url
        if probe_url.endswith("/embeddings"):
            probe_url = probe_url[: -len("/embeddings")] + "/models"
        req = urllib.request.Request(probe_url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=PROBE_TIMEOUT_S) as resp:
                return resp.status < 500
        except urllib.error.HTTPError as e:
            return e.code < 500
        except Exception:
            return False

    # -- public API -----------------------------------------------------------

    def embed_batch(self, texts: list[str],
                    prefix: str = DOC_PREFIX) -> list[list[float]]:
        """Embed one batch (caller keeps len(texts) <= batch_size).
        One retry, then EmbedderError. Refreshes the cached health status."""
        if not texts:
            return []
        prefixed = [prefix + t for t in texts]
        try:
            vecs = self._post(prefixed)
        except EmbedderError:
            try:
                vecs = self._post(prefixed)  # single retry (spec §3.2)
            except EmbedderError:
                self._mark(False)
                raise
        self._mark(True)
        return vecs

    def embed_query(self, q: str) -> list[float]:
        """Embed a query with the search_query prefix, LRU-cached on
        normalized query text."""
        key = re.sub(r"\s+", " ", q.strip().lower())
        with self._lock:
            if key in self._query_cache:
                self._query_cache.move_to_end(key)
                return self._query_cache[key]
        vec = self.embed_batch([key], prefix=QUERY_PREFIX)[0]
        with self._lock:
            self._query_cache[key] = vec
            self._query_cache.move_to_end(key)
            while len(self._query_cache) > self.cache_size:
                self._query_cache.popitem(last=False)
        return vec

    def status(self) -> str:
        """"ok" | "down" for /api/health, probe result cached ~30 s."""
        now = time.time()
        with self._lock:
            if self._status is not None \
                    and now - self._status_at < HEALTH_PROBE_TTL_S:
                return "ok" if self._status else "down"
        try:
            ok = bool(self._probe())
        except Exception:
            ok = False
        self._mark(ok)
        return "ok" if ok else "down"

    def _mark(self, ok: bool) -> None:
        with self._lock:
            self._status = ok
            self._status_at = time.time()


def rrf_fuse(lexical_ids: list[str], vector_ids: list[str],
             k: int) -> list[dict]:
    """Reciprocal Rank Fusion (constant RRF_K, spec §3.3) of the two ranked
    candidate lists → top-k with per-result provenance in `matched`."""
    scores: dict[str, float] = {}
    for rank, tid in enumerate(lexical_ids):
        scores[tid] = scores.get(tid, 0.0) + 1.0 / (RRF_K + rank + 1)
    for rank, tid in enumerate(vector_ids):
        scores[tid] = scores.get(tid, 0.0) + 1.0 / (RRF_K + rank + 1)
    lex, vec = set(lexical_ids), set(vector_ids)
    ordered = sorted(scores.items(), key=lambda item: (-item[1], item[0]))
    out = []
    for tid, score in ordered[:k]:
        matched = "both" if tid in lex and tid in vec \
            else ("lexical" if tid in lex else "vector")
        out.append({"track_id": tid, "score": round(score, 4),
                    "matched": matched})
    return out


class LibraryIndex:
    """SQLite-backed per-device track index (WAL, FTS5 external content).

    A single connection guarded by a lock: writes are tiny (≤5000-row
    batches) and reads are millisecond FTS lookups, so one serialized
    connection is simpler and safe across FastAPI's threadpool.
    """

    def __init__(self, db_path: Path | str):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=NORMAL")
        # Load the sqlite-vec extension; failure (missing wheel, a Python
        # built without loadable-extension support, ...) is survivable —
        # vector search reports unavailable and queries stay lexical.
        self._vec_enabled = False
        if VEC_AVAILABLE:
            try:
                self._conn.enable_load_extension(True)
                sqlite_vec.load(self._conn)
                self._conn.enable_load_extension(False)
                self._vec_enabled = True
            except Exception as e:
                logger.warning(
                    "sqlite-vec extension failed to load (%s) — vector "
                    "search unavailable, serving lexical-only",
                    type(e).__name__)
        self._create_schema()

    def _create_schema(self) -> None:
        with self._lock, self._conn:
            self._conn.executescript("""
                CREATE TABLE IF NOT EXISTS tracks(
                    device_id TEXT NOT NULL,
                    track_id TEXT NOT NULL,
                    doc_hash TEXT NOT NULL,
                    doc_text TEXT NOT NULL,
                    meta_json TEXT NOT NULL DEFAULT '{}',
                    updated_at REAL NOT NULL,
                    needs_embedding INTEGER NOT NULL DEFAULT 1,
                    UNIQUE(device_id, track_id)
                );
                CREATE VIRTUAL TABLE IF NOT EXISTS tracks_fts USING fts5(
                    doc_text,
                    content='tracks',
                    content_rowid='rowid'
                );
                CREATE TRIGGER IF NOT EXISTS tracks_fts_ai
                AFTER INSERT ON tracks BEGIN
                    INSERT INTO tracks_fts(rowid, doc_text)
                    VALUES (new.rowid, new.doc_text);
                END;
                CREATE TRIGGER IF NOT EXISTS tracks_fts_ad
                AFTER DELETE ON tracks BEGIN
                    INSERT INTO tracks_fts(tracks_fts, rowid, doc_text)
                    VALUES ('delete', old.rowid, old.doc_text);
                END;
                CREATE TRIGGER IF NOT EXISTS tracks_fts_au
                AFTER UPDATE OF doc_text ON tracks BEGIN
                    INSERT INTO tracks_fts(tracks_fts, rowid, doc_text)
                    VALUES ('delete', old.rowid, old.doc_text);
                    INSERT INTO tracks_fts(rowid, doc_text)
                    VALUES (new.rowid, new.doc_text);
                END;
                CREATE TABLE IF NOT EXISTS index_meta(
                    device_id TEXT PRIMARY KEY,
                    embed_model TEXT NOT NULL DEFAULT '',
                    embed_dim INTEGER NOT NULL DEFAULT 0,
                    schema_version INTEGER NOT NULL
                );
            """)
            # -- schema v2 (in-place migration from a Slice-1 db) ------------
            # Slice 1 shipped user_version 0 and pre-laid the join contract
            # (tracks.rowid + needs_embedding=1 on every row), so the whole
            # upgrade is additive: create the vector table, bump the version.
            # No tracks/FTS data is touched — nothing to lose.
            if self._vec_enabled:
                self._conn.execute(
                    f"""CREATE VIRTUAL TABLE IF NOT EXISTS track_vecs
                        USING vec0(embedding float[{EMBED_DIM}]
                                   distance_metric=cosine)""")
                # Self-heal: any row marked embedded without a stored vector
                # (e.g. a period where the extension was unavailable) goes
                # back to pending so backfill repairs it.
                self._conn.execute(
                    """UPDATE tracks SET needs_embedding = 1
                       WHERE needs_embedding = 0
                         AND rowid NOT IN (SELECT rowid FROM track_vecs)""")
            self._conn.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")

    # -- introspection ------------------------------------------------------

    def journal_mode(self) -> str:
        with self._lock:
            return self._conn.execute("PRAGMA journal_mode").fetchone()[0].lower()

    def schema_version(self) -> int:
        return SCHEMA_VERSION

    def vector_search_available(self) -> bool:
        return self._vec_enabled

    def vector_count(self) -> int:
        if not self._vec_enabled:
            return 0
        with self._lock:
            row = self._conn.execute(
                "SELECT COUNT(*) FROM track_vecs").fetchone()
            return int(row[0])

    def track_count(self, device_id: Optional[str] = None) -> int:
        with self._lock:
            if device_id is None:
                row = self._conn.execute("SELECT COUNT(*) FROM tracks").fetchone()
            else:
                row = self._conn.execute(
                    "SELECT COUNT(*) FROM tracks WHERE device_id = ?",
                    (device_id,)).fetchone()
            return int(row[0])

    # -- mutation -----------------------------------------------------------

    def sync(self, device_id: str, tracks: list[dict],
             deleted_track_ids: list[str],
             embedder: Optional[Embedder] = None) -> dict:
        """Delta upsert: rows whose stored doc_hash already matches are
        skipped; changed/new rows are (re)written and marked needs_embedding.
        If the configured embed model differs from the one pinned in
        index_meta, every vector for the device is invalidated (spec §3.1).
        New/changed/pending docs are then embedded in batches; on embedder
        failure they simply stay pending (picked up by a later sync or the
        bounded query-time backfill).
        Returns {indexed, skipped, deleted, pending_embeddings}."""
        started = time.perf_counter()
        indexed = skipped = deleted = hash_mismatches = 0
        invalidated = 0
        now = time.time()
        with self._lock, self._conn:
            self._conn.execute(
                """INSERT INTO index_meta(device_id, schema_version)
                   VALUES (?, ?)
                   ON CONFLICT(device_id)
                   DO UPDATE SET schema_version = excluded.schema_version""",
                (device_id, SCHEMA_VERSION))
            if embedder is not None:
                row = self._conn.execute(
                    "SELECT embed_model FROM index_meta WHERE device_id = ?",
                    (device_id,)).fetchone()
                prior_model = row[0] if row else ""
                if prior_model and prior_model != embedder.model:
                    # Model changed → every stored vector for this device is
                    # from the wrong space. Invalidate; re-embed lazily below.
                    if self._vec_enabled:
                        self._conn.execute(
                            """DELETE FROM track_vecs WHERE rowid IN
                               (SELECT rowid FROM tracks
                                WHERE device_id = ?)""", (device_id,))
                    cur = self._conn.execute(
                        """UPDATE tracks SET needs_embedding = 1
                           WHERE device_id = ?""", (device_id,))
                    invalidated = cur.rowcount if cur.rowcount > 0 else 0
                self._conn.execute(
                    """UPDATE index_meta SET embed_model = ?, embed_dim = ?
                       WHERE device_id = ?""",
                    (embedder.model, embedder.dim, device_id))
            existing = dict(self._conn.execute(
                "SELECT track_id, doc_hash FROM tracks WHERE device_id = ?",
                (device_id,)).fetchall())
            for t in tracks:
                if t["client_hash"] is not None \
                        and t["client_hash"] != t["doc_hash"]:
                    hash_mismatches += 1
                if existing.get(t["track_id"]) == t["doc_hash"]:
                    skipped += 1
                    continue
                self._conn.execute(
                    """INSERT INTO tracks(device_id, track_id, doc_hash,
                                          doc_text, meta_json, updated_at,
                                          needs_embedding)
                       VALUES (?, ?, ?, ?, ?, ?, 1)
                       ON CONFLICT(device_id, track_id) DO UPDATE SET
                           doc_hash = excluded.doc_hash,
                           doc_text = excluded.doc_text,
                           meta_json = excluded.meta_json,
                           updated_at = excluded.updated_at,
                           needs_embedding = 1""",
                    (device_id, t["track_id"], t["doc_hash"], t["doc_text"],
                     t["meta_json"], now))
                indexed += 1
                # A changed doc keeps its rowid; its old vector is now stale.
                if self._vec_enabled and t["track_id"] in existing:
                    self._conn.execute(
                        """DELETE FROM track_vecs WHERE rowid =
                           (SELECT rowid FROM tracks
                            WHERE device_id = ? AND track_id = ?)""",
                        (device_id, t["track_id"]))
            for tid in deleted_track_ids:
                if self._vec_enabled:
                    self._conn.execute(
                        """DELETE FROM track_vecs WHERE rowid =
                           (SELECT rowid FROM tracks
                            WHERE device_id = ? AND track_id = ?)""",
                        (device_id, tid))
                cur = self._conn.execute(
                    "DELETE FROM tracks WHERE device_id = ? AND track_id = ?",
                    (device_id, tid))
                deleted += cur.rowcount if cur.rowcount > 0 else 0
        # Embed outside the lock/transaction — HTTP must never block readers.
        embedded, pending = self._embed_pending(device_id, embedder)
        latency_ms = (time.perf_counter() - started) * 1000
        # Guardrail: counts and latency only — never doc_text.
        logger.info(
            "library sync device=%s… indexed=%d skipped=%d deleted=%d "
            "hash_mismatches=%d invalidated=%d embedded=%d pending=%d "
            "(%.0fms)",
            device_id[:8], indexed, skipped, deleted, hash_mismatches,
            invalidated, embedded, pending, latency_ms)
        return {"indexed": indexed, "skipped": skipped, "deleted": deleted,
                "pending_embeddings": pending}

    def delete_device(self, device_id: str) -> int:
        """Drop every row for a device (the privacy delete endpoint)."""
        with self._lock, self._conn:
            if self._vec_enabled:
                self._conn.execute(
                    """DELETE FROM track_vecs WHERE rowid IN
                       (SELECT rowid FROM tracks WHERE device_id = ?)""",
                    (device_id,))
            cur = self._conn.execute(
                "DELETE FROM tracks WHERE device_id = ?", (device_id,))
            self._conn.execute(
                "DELETE FROM index_meta WHERE device_id = ?", (device_id,))
            removed = cur.rowcount if cur.rowcount > 0 else 0
        logger.info("library delete device=%s… removed=%d",
                    device_id[:8], removed)
        return removed

    # -- embedding ------------------------------------------------------------

    def _pending_count(self, device_id: str) -> int:
        with self._lock:
            row = self._conn.execute(
                """SELECT COUNT(*) FROM tracks
                   WHERE device_id = ? AND needs_embedding = 1""",
                (device_id,)).fetchone()
            return int(row[0])

    def _embed_pending(self, device_id: str, embedder: Optional[Embedder],
                       limit: Optional[int] = None) -> tuple[int, int]:
        """Embed up to `limit` pending rows for a device (all when None).
        Returns (embedded, still_pending). Embedder failures stop the loop
        and leave the remainder pending — never raise past this point.
        HTTP happens outside the DB lock; the doc_hash guard on the write
        keeps a concurrently-updated row from receiving a stale vector."""
        if embedder is None or not self._vec_enabled:
            return 0, self._pending_count(device_id)
        with self._lock:
            sql = """SELECT rowid, doc_text, doc_hash FROM tracks
                     WHERE device_id = ? AND needs_embedding = 1
                     ORDER BY rowid"""
            args: tuple = (device_id,)
            if limit is not None:
                sql += " LIMIT ?"
                args = (device_id, limit)
            rows = self._conn.execute(sql, args).fetchall()
        embedded = 0
        batch = max(1, min(embedder.batch_size, EMBED_BATCH))
        for start in range(0, len(rows), batch):
            chunk = rows[start:start + batch]
            try:
                vecs = embedder.embed_batch([r[1] for r in chunk],
                                            prefix=DOC_PREFIX)
            except EmbedderError:
                logger.info(
                    "library embed backfill halted device=%s… embedded=%d "
                    "(embedder down)", device_id[:8], embedded)
                break
            with self._lock, self._conn:
                for (rowid, _text, dhash), vec in zip(chunk, vecs):
                    cur = self._conn.execute(
                        """UPDATE tracks SET needs_embedding = 0
                           WHERE rowid = ? AND doc_hash = ?
                             AND needs_embedding = 1""", (rowid, dhash))
                    if cur.rowcount:
                        self._conn.execute(
                            "DELETE FROM track_vecs WHERE rowid = ?",
                            (rowid,))
                        self._conn.execute(
                            """INSERT INTO track_vecs(rowid, embedding)
                               VALUES (?, ?)""",
                            (rowid, struct.pack(f"{len(vec)}f", *vec)))
                        embedded += 1
        return embedded, self._pending_count(device_id)

    # -- retrieval ----------------------------------------------------------

    def query(self, device_id: str, q: str, k: int,
              embedder: Optional[Embedder] = None) -> dict:
        """Hybrid retrieval (spec §3.3): FTS5 BM25 top-CANDIDATE_POOL +
        sqlite-vec cosine top-CANDIDATE_POOL → RRF → top-k, with per-result
        `matched: "lexical"|"vector"|"both"`. Degrades to BM25-only
        (`mode: "lexical"`) whenever the embedder is unreachable or the
        sqlite-vec extension is unavailable — never fails the query.
        If the device has pending needs_embedding rows and the embedder is
        reachable, a backfill hard-capped at QUERY_BACKFILL_CAP runs first."""
        lexical = self._lexical_search(device_id, q, CANDIDATE_POOL)
        mode = "lexical"
        vector_ids: list[str] = []
        if embedder is not None and self._vec_enabled and q.strip():
            try:
                if self._pending_count(device_id):
                    # Bounded: at most QUERY_BACKFILL_CAP rows per request,
                    # never an unbounded loop on the query path. Failures
                    # inside stay pending; embed_query below decides mode.
                    self._embed_pending(device_id, embedder,
                                        limit=QUERY_BACKFILL_CAP)
                qvec = embedder.embed_query(q)
                vector_ids = self._vector_search(device_id, qvec,
                                                 CANDIDATE_POOL)
                mode = "hybrid"
            except EmbedderError:
                mode = "lexical"
                vector_ids = []
        if mode == "hybrid":
            results = rrf_fuse([tid for tid, _ in lexical], vector_ids, k)
        else:
            results = [
                {"track_id": tid, "score": round(-score, 4),
                 "matched": "lexical"}
                for tid, score in lexical[:k]
            ]
        return {"results": results, "mode": mode}

    def _lexical_search(self, device_id: str, q: str,
                        pool: int) -> list[tuple[str, float]]:
        """FTS5 BM25 candidates: [(track_id, bm25_score)], best first.
        bm25() is ascending-better, so the raw score is kept for the caller
        (-bm25 is the user-facing lexical score)."""
        match_expr = sanitize_fts_query(q)
        if not match_expr:
            return []
        with self._lock:
            rows = self._conn.execute(
                """SELECT t.track_id, bm25(tracks_fts) AS rank_score
                   FROM tracks_fts
                   JOIN tracks t ON t.rowid = tracks_fts.rowid
                   WHERE tracks_fts MATCH ? AND t.device_id = ?
                   ORDER BY rank_score
                   LIMIT ?""",
                (match_expr, device_id, pool)).fetchall()
        return [(tid, score) for tid, score in rows]

    def _vector_search(self, device_id: str, qvec: list[float],
                       pool: int) -> list[str]:
        """sqlite-vec cosine KNN over one device's vectors → track_ids,
        nearest first. Rows still pending embedding simply have no vector
        and cannot appear here (they can still match lexically)."""
        packed = struct.pack(f"{len(qvec)}f", *qvec)
        with self._lock:
            rows = self._conn.execute(
                """SELECT v.rowid FROM track_vecs v
                   WHERE v.embedding MATCH ? AND k = ?
                     AND v.rowid IN
                         (SELECT rowid FROM tracks WHERE device_id = ?)
                   ORDER BY v.distance""",
                (packed, pool, device_id)).fetchall()
            if not rows:
                return []
            rowids = [r[0] for r in rows]
            placeholders = ",".join("?" * len(rowids))
            id_map = dict(self._conn.execute(
                f"SELECT rowid, track_id FROM tracks "
                f"WHERE rowid IN ({placeholders})", rowids).fetchall())
        return [id_map[r] for r in rowids if r in id_map]

    def close(self) -> None:
        with self._lock:
            self._conn.close()
