"""Shared retrieval-eval harness for RAG Slice 4 (spec §6).

Used by two callers, which is why it lives outside any test_*.py file:

- `test_retrieval_eval.py` — the CI regression gate + harness self-tests.
- `record_eval_fixtures.py` — the owner-run script that records real
  embeddings into `fixtures/library_eval_vecs.npz` and (re)computes
  `fixtures/eval_baseline.json`.

Everything here drives the REAL retrieval code paths in `library_index.py`
(`parse_sync_payload` → `LibraryIndex.sync` → `LibraryIndex.query`); the only
substitution is the embedder, which serves pre-recorded vectors instead of
calling the network. CI therefore never opens a socket (hermeticity rule).

Fixture key contract (shared with record_eval_fixtures.py):
- track vectors are keyed by the track's `doc_hash` (SHA-256 hex of the
  composed doc_text), so a vector is invalidated exactly when its doc changes;
- query vectors are keyed by the normalized query string (whitespace
  collapsed, stripped, lowercased) — the same normalization
  `Embedder.embed_query` applies before hitting the network.
"""
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import library_index as libindex  # noqa: E402

FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
SNAPSHOT_PATH = FIXTURES_DIR / "library_eval_snapshot.jsonl"
QUERIES_PATH = FIXTURES_DIR / "library_eval.jsonl"
VECS_PATH = FIXTURES_DIR / "library_eval_vecs.npz"
BASELINE_PATH = FIXTURES_DIR / "eval_baseline.json"
GOLDEN_FILES = (SNAPSHOT_PATH, QUERIES_PATH, VECS_PATH, BASELINE_PATH)

EVAL_DEVICE_ID = "eval-harness-device"
MODES = ("lexical", "vector", "hybrid")


class MissingFixtureVector(RuntimeError):
    """A required embedding is absent from the recorded fixture set.

    Deliberately NOT a `libindex.EmbedderError`: EmbedderError triggers the
    production degrade-to-lexical path, which would silently turn a broken
    fixture into a passing "hybrid" eval. This must abort instead.
    """


class FixtureEmbedder(libindex.Embedder):
    """Serves embeddings from an in-memory {key: vector} mapping (loaded from
    the .npz). Never touches the network; raises MissingFixtureVector on any
    text it has no recording for."""

    def __init__(self, vectors: dict):
        dim = len(next(iter(vectors.values()))) if vectors \
            else libindex.EMBED_DIM
        super().__init__(url="http://fixture.invalid/v1/embeddings", dim=dim)
        self._vectors = vectors

    def _post(self, texts):
        out = []
        for text in texts:
            if text.startswith(libindex.DOC_PREFIX):
                doc_text = text[len(libindex.DOC_PREFIX):]
                key = libindex.doc_hash(doc_text)
                kind = "doc"
            elif text.startswith(libindex.QUERY_PREFIX):
                key = text[len(libindex.QUERY_PREFIX):]
                kind = "query"
            else:  # pragma: no cover - Embedder always prefixes
                key, kind = text, "unprefixed"
            vec = self._vectors.get(key)
            if vec is None:
                raise MissingFixtureVector(
                    f"no recorded embedding for {kind} key {key[:60]!r} — "
                    "re-run backend/tests/record_eval_fixtures.py so the "
                    ".npz covers every snapshot doc and golden query")
            out.append(list(vec))
        return out

    def _probe(self):
        return True


# ---------------------------------------------------------------------------
# metrics
# ---------------------------------------------------------------------------

def recall_at_k(ranked_ids, relevant, k: int) -> float:
    """|relevant ∩ top-k| / |relevant| (binary relevance)."""
    relevant = set(relevant)
    if not relevant:
        return 0.0
    hits = sum(1 for tid in ranked_ids[:k] if tid in relevant)
    return hits / len(relevant)


def ndcg_at_k(ranked_ids, relevant, k: int) -> float:
    """Binary-relevance nDCG@k: DCG = Σ 1/log2(rank+1) over relevant hits in
    the top-k; IDCG = the same sum with all relevant docs ranked first."""
    import math
    relevant = set(relevant)
    if not relevant:
        return 0.0
    dcg = sum(1.0 / math.log2(i + 2)
              for i, tid in enumerate(ranked_ids[:k]) if tid in relevant)
    idcg = sum(1.0 / math.log2(i + 2)
               for i in range(min(len(relevant), k)))
    return dcg / idcg if idcg else 0.0


# ---------------------------------------------------------------------------
# fixture I/O
# ---------------------------------------------------------------------------

def _normalize_row(row: dict) -> dict:
    """Snapshot rows may carry playlists/affinity as lists (sync-payload
    shape) or as space-joined strings (the sqlite3 doc_text export in
    LABELING.md). Splitting on whitespace composes to the identical doc_text
    because compose_doc space-joins list items anyway."""
    row = dict(row)
    for field in ("playlists", "affinity"):
        value = row.get(field)
        if isinstance(value, str):
            row[field] = value.split()
    return row


def load_snapshot(path) -> list:
    rows = []
    seen = set()
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            row = json.loads(line)
            if not isinstance(row, dict) or not row.get("track_id"):
                raise ValueError(f"{path}:{lineno}: not a track object")
            if row["track_id"] in seen:
                raise ValueError(
                    f"{path}:{lineno}: duplicate track_id {row['track_id']!r}")
            seen.add(row["track_id"])
            rows.append(_normalize_row(row))
    if not rows:
        raise ValueError(f"{path}: empty snapshot")
    return rows


def load_queries(path) -> list:
    queries = []
    seen = set()
    with open(path, encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            if not line.strip():
                continue
            q = json.loads(line)
            qid = q.get("query_id") if isinstance(q, dict) else None
            if not qid or not isinstance(q.get("query"), str) \
                    or not q["query"].strip():
                raise ValueError(f"{path}:{lineno}: needs query_id and query")
            if qid in seen:
                raise ValueError(f"{path}:{lineno}: duplicate query_id {qid!r}")
            rel = q.get("relevant_track_ids")
            if not isinstance(rel, list) or not rel \
                    or not all(isinstance(t, str) and t for t in rel):
                raise ValueError(
                    f"{path}:{lineno}: relevant_track_ids must be a non-empty "
                    "list of track ids (unlabeled queries are not allowed)")
            seen.add(qid)
            queries.append(q)
    if not queries:
        raise ValueError(f"{path}: no queries")
    return queries


def validate_queries(queries, snapshot) -> None:
    """Every labeled track must exist in the frozen snapshot."""
    known = {row["track_id"] for row in snapshot}
    for q in queries:
        unknown = [t for t in q["relevant_track_ids"] if t not in known]
        if unknown:
            raise ValueError(
                f"query {q['query_id']!r} labels track ids missing from the "
                f"snapshot: {unknown} — labels and snapshot must be exported "
                "from the same frozen library")


def load_vectors(path) -> dict:
    import numpy as np
    with np.load(path) as data:
        return {key: data[key].astype(float).tolist() for key in data.files}


def snapshot_file_hash(path) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def normalize_query_key(q: str) -> str:
    """Must match Embedder.embed_query's cache-key normalization."""
    import re
    return re.sub(r"\s+", " ", q.strip().lower())


# ---------------------------------------------------------------------------
# the eval run
# ---------------------------------------------------------------------------

def build_index(snapshot, db_path, embedder) -> libindex.LibraryIndex:
    """Load the frozen snapshot through the real sync path (payload parsing,
    doc composition, embed-at-sync) in ≤MAX_SYNC_TRACKS chunks."""
    idx = libindex.LibraryIndex(db_path)
    if not idx.vector_search_available():
        idx.close()
        raise RuntimeError(
            "sqlite-vec unavailable — the eval must exercise the real hybrid "
            "path, not the lexical degradation (pip install sqlite-vec)")
    for start in range(0, len(snapshot), libindex.MAX_SYNC_TRACKS):
        chunk = snapshot[start:start + libindex.MAX_SYNC_TRACKS]
        _, tracks, _ = libindex.parse_sync_payload(
            {"device_id": EVAL_DEVICE_ID, "tracks": chunk})
        out = idx.sync(EVAL_DEVICE_ID, tracks, [], embedder=embedder)
        if out["pending_embeddings"]:
            idx.close()
            raise RuntimeError(
                f"{out['pending_embeddings']} docs left unembedded — the "
                "fixture .npz does not cover the snapshot")
    return idx


def run_eval(snapshot, queries, vectors, db_path, k: int = 10) -> dict:
    """Run every golden query in all three modes against a fresh index built
    from the snapshot. Returns per-mode mean recall@k / nDCG@k plus
    per-query details (ranked ids, per-query metrics, hybrid mode)."""
    embedder = FixtureEmbedder(vectors)
    idx = build_index(snapshot, db_path, embedder)
    per_query = []
    try:
        for q in queries:
            relevant = set(q["relevant_track_ids"])
            entry = {"query_id": q["query_id"], "relevant": sorted(relevant)}

            hybrid_out = idx.query(EVAL_DEVICE_ID, q["query"], k,
                                   embedder=embedder)
            if hybrid_out["mode"] != "hybrid":
                raise RuntimeError(
                    f"query {q['query_id']!r} did not run hybrid "
                    f"(got mode={hybrid_out['mode']!r})")
            lexical_out = idx.query(EVAL_DEVICE_ID, q["query"], k,
                                    embedder=None)
            qvec = embedder.embed_query(q["query"])
            vector_ids = idx._vector_search(EVAL_DEVICE_ID, qvec, k)

            ranked = {
                "hybrid": [h["track_id"] for h in hybrid_out["results"]],
                "lexical": [h["track_id"] for h in lexical_out["results"]],
                "vector": vector_ids,
            }
            for mode in MODES:
                entry[mode] = {
                    "ranked": ranked[mode],
                    "recall": recall_at_k(ranked[mode], relevant, k),
                    "ndcg": ndcg_at_k(ranked[mode], relevant, k),
                }
            entry["hybrid"]["mode"] = hybrid_out["mode"]
            per_query.append(entry)
    finally:
        idx.close()

    n = len(per_query)
    modes = {
        mode: {
            f"recall_at_{k}": sum(p[mode]["recall"] for p in per_query) / n,
            f"ndcg_at_{k}": sum(p[mode]["ndcg"] for p in per_query) / n,
        }
        for mode in MODES
    }
    return {"k": k, "n_queries": n, "modes": modes, "per_query": per_query}


def run_eval_tempdb(snapshot, queries, vectors, k: int = 10) -> dict:
    """run_eval against a throwaway SQLite file (for the recording script)."""
    with tempfile.TemporaryDirectory(prefix="aria-eval-") as tmp:
        return run_eval(snapshot, queries, vectors,
                        Path(tmp) / "eval_index.db", k=k)


def format_report(result: dict, baseline: dict = None) -> str:
    """Human-readable per-mode metric table (+ baseline deltas + lift line)."""
    k = result["k"]
    lines = [
        f"Retrieval eval — {result['n_queries']} queries, "
        f"metrics @ k={k}",
        f"{'mode':<10} {'recall@' + str(k):>12} {'nDCG@' + str(k):>12}"
        + ("   vs baseline" if baseline else ""),
    ]
    for mode in MODES:
        m = result["modes"][mode]
        row = (f"{mode:<10} {m[f'recall_at_{k}']:>12.4f} "
               f"{m[f'ndcg_at_{k}']:>12.4f}")
        if baseline and mode in baseline:
            dr = m[f"recall_at_{k}"] - baseline[mode][f"recall_at_{k}"]
            dn = m[f"ndcg_at_{k}"] - baseline[mode][f"ndcg_at_{k}"]
            row += f"   Δrecall {dr:+.4f}  Δndcg {dn:+.4f}"
        lines.append(row)
    hyb = result["modes"]["hybrid"][f"recall_at_{k}"]
    lex = result["modes"]["lexical"][f"recall_at_{k}"]
    lines.append(
        f"LIFT hybrid-vs-lexical recall@{k}: {hyb - lex:+.4f} "
        f"({'hybrid ahead' if hyb >= lex else 'HYBRID BEHIND LEXICAL'})")
    return "\n".join(lines)
