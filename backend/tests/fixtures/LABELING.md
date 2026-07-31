# Retrieval eval fixtures — owner labeling & recording guide

This directory holds the golden fixtures for the "Ask Your Library" retrieval
eval (spec §6, `docs/design/2026-07-28-rag-library-search-spec.md`). Until all
four files below exist, `tests/test_retrieval_eval.py::
test_golden_hybrid_meets_committed_baseline` **skips** and CI stays green.
Committing them arms the regression gate automatically: any later PR whose
hybrid recall@10 / nDCG@10 drops below `eval_baseline.json` fails CI.

| File | What | Who writes it |
|------|------|---------------|
| `library_eval_snapshot.jsonl` | Frozen library, one track per line, sync-payload field shape | exported from the backend DB (step 2) |
| `library_eval.jsonl` | Golden queries + relevant track ids | **you, by hand** (step 1) |
| `library_eval_vecs.npz` | Pre-recorded embeddings (doc_hash / normalized-query keys) | `record_eval_fixtures.py` (step 3) |
| `eval_baseline.json` | Per-mode recall@10 + nDCG@10 floor | `record_eval_fixtures.py` (step 3) |

Activation is three steps: **label → export snapshot → record.**

---

## The independence rule (non-negotiable)

The labels must be **owner-authored and independent of the system under
test** (memory: `eval-set-construction`):

- Write the queries and their relevant tracks **from memory of your library,
  BEFORE playing with the Library search feature.** If you've already played
  with it, write the labels without it open and don't peek.
- **Never** let the system's output pick or trim the labels — no "run the
  query, then bless the top results". That measures agreement with the
  system, not quality.
- **Never** generate queries or labels with a model. Model-generated evals
  inflate the very pipelines models power.
- It is fine (expected) for some queries to have relevant tracks the system
  will miss — that headroom is the point.

## Step 1 — author ~40 golden queries (`library_eval.jsonl`)

One JSON object per line:

```json
{"query_id": "q01", "query": "mellow late night acoustic", "relevant_track_ids": ["dQw4...", "kXYi..."], "note": "the two fingerstyle albums"}
```

- `query_id`: unique, stable (`q01`…`q40`); `note` is optional context for
  future-you.
- `relevant_track_ids`: every track you'd consider a correct top-10 hit
  (typically 1–8). Must exist in the snapshot (the recorder validates).
  Track ids are the same ids the app syncs (see the snapshot export).
- Phrase queries the way you'd actually type them, not the way the index
  stores them.

Spread roughly evenly across:

1. **Mood/genre phrases** — "mellow late-night guitar", "upbeat 90s rock".
2. **Affinity phrases** — "stuff I haven't played in a while" (dormant),
   "my favorites that are short", "what I've been playing lately" (recent).
3. **Playlist-adjacent** — phrasings that orbit a playlist's theme without
   naming it exactly ("songs for the gym drive").
4. **Artist-adjacent** — "that band that sounds like X", an artist's side
   project, a misremembered artist name.
5. **Deliberately hard negatives** — queries where the lexically obvious
   match is wrong (a track literally titled "Happy" that is a dirge; "metal"
   meaning the genre while an unrelated track has "metal" in its title).
   Label only the genuinely relevant tracks; the trap track's exclusion IS
   the label.

## Step 2 — export the frozen snapshot (`library_eval_snapshot.jsonl`)

The iOS app has already synced your library to the backend, so the simplest
export is a sqlite3 query against `library_index.db` on the homelab, dumping
device rows back to the sync-payload shape. On the homelab
(`ssh eugene@<homelab-host>`, DB lives next to the deployed `app.py`,
default `~/MusicAppIOS/backend/library_index.db`):

```bash
# find your device_id first
sqlite3 ~/MusicAppIOS/backend/library_index.db \
  "SELECT device_id, COUNT(*) FROM tracks GROUP BY device_id;"

# export (fill in <device-id>)
sqlite3 ~/MusicAppIOS/backend/library_index.db "SELECT json_object(
  'track_id', track_id,
  'doc_hash', doc_hash,
  'title',  json_extract(meta_json, '\$.title'),
  'artist', json_extract(meta_json, '\$.artist'),
  'album',  json_extract(meta_json, '\$.album'),
  'genre',  json_extract(meta_json, '\$.genre'),
  'duration', json_extract(meta_json, '\$.duration'),
  'playlists', substr(doc_text,
       instr(doc_text, char(10)||'playlists: ') + 12,
       instr(doc_text, char(10)||'affinity: ') - instr(doc_text, char(10)||'playlists: ') - 12),
  'affinity', substr(doc_text, instr(doc_text, char(10)||'affinity: ') + 11)
) FROM tracks WHERE device_id = '<device-id>' ORDER BY track_id;" \
  > library_eval_snapshot.jsonl
```

then `scp` it into `backend/tests/fixtures/`.

Notes:
- `playlists`/`affinity` come out as **space-joined strings** parsed from the
  indexed `doc_text` (structured lists aren't stored server-side); the
  harness splits them on whitespace, which composes to the identical
  `doc_text`. Verified round-trip: the export includes `doc_hash`, and the
  recorder recomposes every doc and refuses to run on any mismatch — so a
  broken export cannot silently poison the vectors.
- The snapshot is **frozen**: don't re-export casually. The baseline records
  its SHA-256 (`snapshot_hash`); the gate fails on drift until you re-record.

## Step 3 — record embeddings + baseline (`record_eval_fixtures.py`)

Needs the real embedding endpoint reachable on the tailnet — wake the
embedding box first. From `backend/`, in a venv with
`pip install -r requirements-dev.txt`:

```bash
ARIA_EMBED_URL=http://<embed-host-tailscale-ip>:<port>/v1/embeddings \
  python tests/record_eval_fixtures.py
```

(Unset, it defaults to the homelab llama-swap at
`http://127.0.0.1:8090/v1/embeddings` — i.e. run it on the homelab itself.
**Never commit a real tailnet IP anywhere in the repo.**)

The script refuses to run without your labels, embeds every snapshot doc and
query, writes the `.npz` and `eval_baseline.json` from a full harness run
(lexical / vector / hybrid), and prints the summary table including the
hybrid-vs-lexical lift. Review the diff, then commit all four files together.
The skipped CI test arms on the next push.

## Updating the baseline (deliberate path only)

The gate compares every PR's hybrid metrics against the **committed**
baseline. When a change legitimately moves the numbers (better retrieval, new
embedding model, refreshed snapshot or labels):

1. Re-run `record_eval_fixtures.py` (same command as step 3).
2. Review the diff — the metric movement should be explainable, and the
   summary table is the evidence for the PR description.
3. Commit fixtures + baseline in the PR that caused the movement.

Never hand-edit `eval_baseline.json`; the drift checks (snapshot hash, query
count) exist to make sneaking past the gate harder than re-recording.

## Latency SLO (after fixtures land)

Spec §6 sets `/api/library/query` p95 < 400 ms warm. Once the golden set is
live on the homelab, read the measured p95 from `/api/metrics` and record the
number in the spec changelog (`docs/design/2026-07-28-rag-library-search-spec.md`)
— that's a one-line owner task, not a load-test harness.
