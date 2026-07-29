# SPEC: RAG Library Search ("Ask Your Library")

**Status:** Draft — awaiting owner review
**Date:** 2026-07-28
**Feature:** Natural-language semantic search and playlist generation over the user's own
library ("mellow late-night guitar", "upbeat 90s stuff I haven't played in a while"),
powered by a retrieval pipeline on the BYO backend.

**Why this feature:** It is the retrieval-engineering practice slice for the LLMOps
portfolio (embeddings, hybrid search, reranking, retrieval evals) AND a ranked user want
from the 2026-07 niche research (smart search over self-hosted libraries is a named
Symfonium gap). It strengthens the BYO-server story: the server does real work beyond
resolving streams.

---

## 1. Scope

### In scope
- Backend: per-device library index (SQLite + FTS5 + sqlite-vec), delta sync endpoint,
  hybrid BM25+vector query endpoint with RRF fusion, embedding client against the
  homelab llama-swap `/v1/embeddings` endpoint, graceful BM25-only degradation.
- iOS: library snapshot sync (debounced, delta-based), a "Ask Your Library" search
  scope, results list → one-tap "Save as playlist".
- Eval harness: hand-labeled golden query set, recall@10 / nDCG@10, run in CI with a
  **stubbed embedder** (recorded fixtures — hermeticity rule).
- Telemetry: embed/query latency + token counts into the existing llmops telemetry.
- Privacy: explicit index-delete endpoint; feature hidden entirely in local-only mode
  and when `BackendConfig` resolves no URL.

### Out of scope (do not build)
- Retrieval over all of YouTube / global catalog search (`/api/search` stays as-is).
- Audio-content embeddings (CLAP etc.), lyrics ingestion, cross-user features.
- LLM answer generation / chat UI. This is retrieval → ranked tracks, not RAG-with-
  generation. (A later slice may add query expansion via the llmops router; see §8.)
- Reranker cross-encoder (stretch slice only, §8).
- Any new third-party iOS dependency (hard rule: zero deps, iOS 16.6, Swift 5).

---

## 2. Architecture

```
iOS (LibrarySyncService) ──POST /api/library/sync──▶ FastAPI (app.py)
                                                        │ upsert docs
                                                        ▼
                                              SQLite: library_index.db
                                              (docs + FTS5 + sqlite-vec)
                                                        ▲
iOS (LibrarySearchService) ──GET /api/library/query──▶ hybrid retrieve
                                                        │ 1. FTS5 BM25 top-50
                                                        │ 2. vector top-50
                                                        │ 3. RRF fusion → top-k
                                                        ▼
                              embeddings: llama-swap /v1/embeddings (homelab)
                              model: nomic-embed-text-v1.5 GGUF (768-dim)
```

- **One document per track. No chunking.** A track's searchable doc is small; the
  interesting design work is doc *composition*, not splitting (§4).
- **Per-device namespace.** Sync payload carries a client-generated stable `device_id`
  (UUID persisted in `KeyValueStore`); all rows are scoped to it. No account system.
- **Degradation:** if the embedding server is unreachable, `/api/library/query` serves
  BM25-only and sets `"mode": "lexical"` in the response so the client can (silently)
  proceed. Never fail the query because the GPU box is asleep.

## 3. Backend changes (`backend/`)

New module **`backend/library_index.py`** (keep `app.py` from growing; `app.py` only
gains the route handlers and wiring). New file **`backend/tests/test_library_index.py`**.

### 3.1 Storage
- `library_index.db` (SQLite) next to `song_cache/`, WAL mode.
- Tables:
  - `tracks(device_id, track_id, doc_hash, doc_text, meta_json, updated_at)` —
    PK `(device_id, track_id)`.
  - `tracks_fts` — FTS5 external-content table over `doc_text`.
  - `track_vecs` — sqlite-vec virtual table, 768-dim float, rowid-joined to `tracks`.
  - `index_meta(device_id, embed_model, embed_dim, schema_version)` — if
    `embed_model` changes, all vectors for that device are invalidated and re-embedded
    lazily on next sync (model/version pinning; this is the model-versioning story).
- New Python deps: `sqlite-vec` only. **Verify provenance before adding** (real
  package, Alex Garcia, active history — SCA rule from the SDLC guidance; do not accept
  a hallucinated alternative name).

### 3.2 Embedding client
- `Embedder` class in `library_index.py`: POSTs OpenAI-format
  `/v1/embeddings` to `ARIA_EMBED_URL` (env; default
  `http://127.0.0.1:8090/v1/embeddings` — llama-swap on the homelab; model alias
  `nomic-embed` registered in the llama-swap config in `tools/llmops/configs/`).
- Batch ≤ 64 docs per call, 10 s timeout, single retry; on failure mark rows
  `needs_embedding=1` and continue (picked up on next sync or query-time backfill).
- Query embedding cached in-process (LRU 256) keyed by normalized query text.

### 3.3 Endpoints (all behind existing `_require_api_key` + `_enforce_rate_limit`)
- **`POST /api/library/sync`** — body: `{device_id, embed_model?, tracks:
  [{track_id, doc_hash, fields...}], deleted_track_ids: [...]}`.
  Upserts only rows whose `doc_hash` changed (client computes hash; server verifies).
  Embeds new/changed docs. Returns `{indexed, skipped, deleted, pending_embeddings}`.
  Rate limit: reuse the existing per-IP limiter; cap payload at 2 MB / 5000 tracks.
- **`GET /api/library/query?device_id=&q=&k=25`** — hybrid retrieval:
  1. FTS5 BM25 top-50 (query sanitized — FTS5 syntax chars escaped; injection surface).
  2. sqlite-vec cosine top-50 on the query embedding.
  3. Reciprocal Rank Fusion (k=60), return top-`k`:
     `{results: [{track_id, score, matched: "lexical"|"vector"|"both"}], mode}`.
  `matched` is the explanation seam — the client shows nothing in v1, but evals use it.
- **`DELETE /api/library?device_id=`** — drops all rows for the device. Privacy
  requirement, not optional. Wire it to the same path as the iOS "sign out of server" /
  backend-URL-change flow.
- `/api/health` gains `"library_index": {"tracks": n, "embedder": "ok"|"down"}`;
  `/api/metrics` gains p50/p95 for the two new endpoints via the existing
  `_record_metric` middleware (no new code needed — the middleware already covers new
  routes; verify in tests).

### 3.4 Logging/guardrails
- **Do not log raw query text or doc_text** in server logs or telemetry — library
  contents are personal data. Log query length, k, mode, latency, result count only.
  (This is the PII-in-telemetry rule; the flywheel must never train on library data.)

## 4. Document composition (the retrieval-quality lever)

`doc_text` per track, one line per field, lowercase:

```
title: {title}
artist: {artist}
album: {album}
genre: {genre or "unknown"}
duration: {"short"|"medium"|"long"}            # <2:30 / 2:30–6:00 / >6:00
playlists: {names of playlists containing it}
affinity: {"favorite"? "recent"? "frequent"? "dormant"?}   # from client-computed flags
```

- `playlists:` and `affinity:` are what make "upbeat stuff I haven't played in a while"
  answerable — `dormant` (not played in 60+ days, client-computed) is a term BM25 and
  the embedder can both hit. The client maps NL time-phrases nowhere; the *doc* carries
  the vocabulary. Keep the vocabulary list documented in `library_index.py` docstring.
- `doc_hash` = SHA-256 of `doc_text`; affinity flags use coarse buckets so the hash
  (and hence re-embedding) doesn't churn on every play event.

## 5. iOS changes

New files:
- **`Services/LibrarySyncService.swift`** — assembles the snapshot from
  `FavoritesManager`, `PlaylistsManager`, `LocalLibraryManager`,
  `RecentlyPlayedManager`; computes per-track `doc_hash` (CryptoKit SHA-256) and
  affinity buckets; POSTs deltas. Sync triggers: app-foreground and after library
  mutations via the existing per-manager `Debouncer` pattern (0.5 s debounce feeding a
  60 s min-interval sync gate — do NOT invent a new persistence/debounce mechanism).
  Last-synced hashes persisted via `KeyValueStore`; flushed in
  `ContentView.flushAllStores()`.
- **`Services/LibrarySearchService.swift`** — query endpoint client. Uses
  `URLSessionProtocols.swift` seams so tests stub the network (hermeticity rule:
  these tests must pass on a real-IP device worktree).
- **`Managers/LibrarySearchManager.swift`** — `ObservableObject` (NOT `@Observable`),
  `@Published var results: Loadable<[Track]>` (use `Models/Loadable.swift`, no
  hand-rolled `isLoading`), injected via `.environmentObject` in
  `App/AppEnvironment.swift` like every other manager.

UI:
- New scope in the existing search screen ("Library" vs "YouTube") — not a new tab.
- Result rows reuse the existing track row component; toolbar action "Save as
  playlist" calls `PlaylistsManager` with the query as the default name.
- **Gating:** scope is visible only when `BackendConfig` resolves a URL AND local-only
  mode is off AND the `/api/health` `library_index` probe succeeded this session.
  Copy for the hidden/error states goes through owner review (paywall/gate copy has
  shipped broken with green tests before).
- URL/key resolution goes through `Services/BackendConfig.swift` — never frozen in a
  `static let`.

## 6. Evals (the portfolio deliverable — not optional)

- **Golden set:** ~40 queries hand-labeled by the owner against a frozen snapshot of
  their real library (export via a debug action in `LibrarySyncService`). Labels are
  owner-authored, never model-generated (eval-set-construction rule: labelers
  independent of the system under test). Stored as
  `backend/tests/fixtures/library_eval.jsonl` with the library snapshot beside it.
- **Metrics:** recall@10 and nDCG@10, reported per-mode (lexical / vector / hybrid) so
  the hybrid's lift over BM25-only is a number, not a claim.
- **Harness:** `backend/tests/test_retrieval_eval.py` — runs the full pipeline with a
  **fixture embedder** (embeddings pre-recorded to `library_eval_vecs.npz` by a
  one-time script against the real model; CI never touches the network).
- **CI gate:** hybrid recall@10 must be ≥ baseline recorded in
  `backend/tests/fixtures/eval_baseline.json`; a PR that regresses it fails CI
  ("set the bar at the eval, not the demo"). Baseline updates are a deliberate,
  reviewed diff.
- **Latency SLO:** `/api/library/query` p95 < 400 ms warm (embed ~50 ms + retrieve
  ~10 ms + fusion negligible) measured via `/api/metrics` on the homelab; record the
  measured number in this doc's changelog when known.

## 7. Delivery slices (one PR each, per working agreements)

1. **Slice 1 — backend index, lexical only.** `library_index.py`, sync + query +
   delete endpoints, FTS5/BM25 path, tests. No embedder. Deployable and useful alone.
2. **Slice 2 — embeddings + hybrid.** llama-swap embed model config (PR to
   aria-llmops repo), `Embedder`, sqlite-vec, RRF, degradation path, health/metrics.
3. **Slice 3 — iOS integration.** The three new Swift files + search scope UI.
   Device-test gated (real-IP plist swap; simulator drive before "done" — green tests
   are not completion for UI work).
4. **Slice 4 — eval harness + CI gate.** Golden set, fixtures, baseline, `ci.yml` wire.

Slices 1–2 are backend-only and independently shippable via the standard
`scp app.py` + `library_index.py` deploy (deploy script gains the second file —
update the CLAUDE.md deploy line in the same PR).

## 8. Stretch (separate spec before building — do not scope-creep into 1–4)

- Cross-encoder rerank of the fused top-50 (homelab-served; shadow-compare against
  RRF-only using the eval set before promoting — the shadow-deployment practice slice).
- Query expansion via the llmops router (SIMPLE-tier task: "mellow late-night" →
  genre/mood terms) — trajectory-logged through existing telemetry.
- Embedding-model swap experiment (nomic vs bge-small@384) as a registry+shadow drill.

## 9. Risks / decisions made

- **sqlite-vec over FAISS/Chroma:** single-file, no service, fits the backend's
  SQLite-adjacent style; index size at 5k tracks × 768 floats ≈ 15 MB — trivial.
- **768-dim nomic-embed-text-v1.5:** GGUF runs on the existing llama.cpp/llama-swap
  stack; if VRAM contention with the chat models is an issue, truncate to 256 dims
  (matryoshka) — decide in Slice 2 with a measured eval delta, not up front.
- **Library metadata leaves the device:** acceptable only because the destination is
  the user's own BYO server (product positioning). The delete endpoint, log redaction,
  and local-only gating are the mitigations; all three are in scope, not follow-ups.
- **Sync abuse surface:** payload caps + existing rate limiter + API key. The sync
  endpoint writes to disk — `_check_disk_space` is called before upsert batches.

## 10. End-to-end verification (definition of done for the feature)

On a device worktree (real-IP plist swap applied), with the homelab backend deployed
and llama-swap serving `nomic-embed`:

1. Fresh install → library scope hidden (no backend configured). Configure backend →
   scope appears after health probe.
2. Favorite ~20 known tracks spanning two genres; background the app → foreground →
   `/api/health` shows `tracks ≥ 20`.
3. Query "mellow acoustic" in Library scope → top-10 contains the expected acoustic
   tracks and none of the metal ones; response `mode == "hybrid"`.
4. Stop the embed model (llama-swap unload) → same query still returns results,
   `mode == "lexical"`, no user-visible error.
5. "Save as playlist" → playlist appears in `PlaylistsManager`, survives app restart
   (flush path).
6. Delete backend URL in settings → `DELETE /api/library` fired; re-adding the URL and
   querying before any sync returns empty, not stale results.
7. `python -m pytest tests/ -q` green (backend) and the AriaTests suite green with
   **no network** (Wi-Fi off on the CI-style run) — proves the stubs are real.
