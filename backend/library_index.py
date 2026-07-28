"""Per-device library search index for "Ask Your Library" (RAG Slice 1).

Lexical-only for now: SQLite + FTS5 BM25. Slice 2 adds a `track_vecs`
sqlite-vec virtual table (rowid-joined to `tracks`) and an `Embedder`;
the schema below is laid out so that lands without a migration:

- `tracks` keeps its implicit integer rowid as the join key for vectors.
- `tracks.needs_embedding` already exists (every row is 1 until Slice 2
  embeds it) so vector backfill state needs no ALTER TABLE.
- `index_meta(device_id, embed_model, embed_dim, schema_version)` pins the
  embedding model per device; a model change invalidates that device's
  vectors for lazy re-embedding.

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
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger("aria.library_index")

SCHEMA_VERSION = 1

# Slice 2 replaces this constant with live embedder state ("ok"|"down").
EMBEDDER_STATUS = "absent"

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

    # -- introspection ------------------------------------------------------

    def journal_mode(self) -> str:
        with self._lock:
            return self._conn.execute("PRAGMA journal_mode").fetchone()[0].lower()

    def schema_version(self) -> int:
        return SCHEMA_VERSION

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
             deleted_track_ids: list[str]) -> dict:
        """Delta upsert: rows whose stored doc_hash already matches are
        skipped; changed/new rows are (re)written and marked needs_embedding
        for Slice 2. Returns {indexed, skipped, deleted, pending_embeddings}."""
        started = time.perf_counter()
        indexed = skipped = deleted = hash_mismatches = 0
        now = time.time()
        with self._lock, self._conn:
            self._conn.execute(
                """INSERT INTO index_meta(device_id, schema_version)
                   VALUES (?, ?)
                   ON CONFLICT(device_id)
                   DO UPDATE SET schema_version = excluded.schema_version""",
                (device_id, SCHEMA_VERSION))
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
            for tid in deleted_track_ids:
                cur = self._conn.execute(
                    "DELETE FROM tracks WHERE device_id = ? AND track_id = ?",
                    (device_id, tid))
                deleted += cur.rowcount if cur.rowcount > 0 else 0
        latency_ms = (time.perf_counter() - started) * 1000
        # Guardrail: counts and latency only — never doc_text.
        logger.info(
            "library sync device=%s… indexed=%d skipped=%d deleted=%d "
            "hash_mismatches=%d (%.0fms)",
            device_id[:8], indexed, skipped, deleted, hash_mismatches,
            latency_ms)
        return {"indexed": indexed, "skipped": skipped, "deleted": deleted,
                "pending_embeddings": 0}

    def delete_device(self, device_id: str) -> int:
        """Drop every row for a device (the privacy delete endpoint)."""
        with self._lock, self._conn:
            cur = self._conn.execute(
                "DELETE FROM tracks WHERE device_id = ?", (device_id,))
            self._conn.execute(
                "DELETE FROM index_meta WHERE device_id = ?", (device_id,))
            removed = cur.rowcount if cur.rowcount > 0 else 0
        logger.info("library delete device=%s… removed=%d",
                    device_id[:8], removed)
        return removed

    # -- retrieval ----------------------------------------------------------

    def query(self, device_id: str, q: str, k: int) -> list[dict]:
        """FTS5 BM25 top-k for one device. Score is -bm25() so higher is
        better. `matched` is always "lexical" in Slice 1 (the explanation
        seam the hybrid slice extends to "vector"/"both")."""
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
                (match_expr, device_id, k)).fetchall()
        return [
            {"track_id": tid, "score": round(-score, 4), "matched": "lexical"}
            for tid, score in rows
        ]

    def close(self) -> None:
        with self._lock:
            self._conn.close()
