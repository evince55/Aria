# Progressive Streaming + Radio Autoplay — Design

Status: **scoping** · Branch: `feat/progressive-radio` · Date: 2026-06-27

## Problem

The backend fully downloads each track before `/api/play` returns. Two consequences:

1. **First-play / EQ-switch latency** — 10–15 s of silence while the whole file
   downloads (worst when EQ forces the engine path on an uncached track).
2. **Runaway-download saturation** — skipping a track cancels the *client* request
   but not the *server* download; orphaned full downloads (some 20–30 min long
   videos) occupy the 2 download-semaphore slots, so every other `/api/play`
   times out. (Partially mitigated by the `MAX_DURATION_SECONDS` cap, but the
   real fix is to not pre-download.)

Plus a product gap: tapping a search result auto-queues the **raw search list**
(random, often hour-long videos) instead of *similar* songs.

## Decisions (locked)

- **Streaming = Hybrid.** `/api/resolve` returns the direct googlevideo URL
  instantly for the AVPlayer (no-EQ) path → playback starts immediately. A
  background task still downloads+caches via the existing `/api/play` so the EQ
  engine path, offline, and repeat keep working.
- **Radio = Endless autoplay.** Seed the queue from the tapped track's YouTube
  Mix (`RD<video_id>` playlist = true "radio"); refill in the background as the
  queue runs low so it never ends.

## Backend (this branch, safe to ship independently)

Three additive endpoints; existing `/api/play` and `/api/stream` unchanged.

### `GET /api/resolve?video_id=<id>`
Extract the direct audio stream URL **without downloading** (yt-dlp
`extract_info(download=False)`). Returns `{url, duration, title, expires_hint}`.
Runs under the **search** semaphore (cheap, metadata-only — must not queue behind
downloads). Multi-client fallback + `video_id` validation reused.

> Caveat: googlevideo URLs are signed and expire (~6 h). The client treats a
> playback failure on a resolved URL as "re-resolve," not a hard error.

### `GET /api/radio?seed=<video_id>&limit=25`
Extract the `RD<seed>` Mix playlist (flat) → list of `{id,title,artist,
thumbnail,duration}`, excluding the seed. Same shape as `/api/search`. Search
semaphore. This is YouTube's own "radio," so results are genuinely similar.

### Unchanged
`/api/play` stays the full-download path — now used only as the **background
cache+EQ** fetch, not the blocking foreground call.

## Client (Phase 2 — DEFERRED behind `feat/local-eq`)

These edits live in `PlayerManager` / `StreamResolver` / the search views — the
exact play/queue path opencode is actively rewriting on `feat/local-eq`. Do
**not** start until that branch merges, then rebase onto it.

1. `StreamResolver.resolve(videoID)` → `/api/resolve`; `PlayerManager` plays the
   direct URL on AVPlayer immediately. Kick off the `/api/play` cache download in
   the background; when EQ is on (or toggled), switch to the engine on the cached
   file once ready.
2. On playback failure of a resolved URL → re-resolve once before surfacing an
   error (handles signed-URL expiry).
3. Replace search-list auto-queue with `/api/radio` seeding + background refill
   when `queue.count` drops below a threshold (e.g. 5).
4. Don't auto-advance on a **failed** load — only on genuine track end (prevents
   the skip-cascade seen in the runaway logs).

## Phasing

- **P1 (now):** backend `/api/resolve` + `/api/radio`. Deploy to homelab. No
  client change → zero risk to current behavior.
- **P2 (after `feat/local-eq` merges):** client wiring for instant playback +
  radio queue, on a rebased branch.
- **P3:** next-track prefetch, refill tuning, telemetry (resolve vs download
  latency, cache hit rate) — feeds the LLMOps cost/observability goal.

## Conflict surface

- Backend (`backend/app.py`) — not git-tracked here, deployed via scp. No overlap.
- Client P2 — heavy overlap with `feat/local-eq`. Gated on its merge.
