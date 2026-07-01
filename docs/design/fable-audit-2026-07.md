# Fable deep bug audit — 2026-07 (10 confirmed defects)

Targeted audit of three high-risk subsystems (real-time audio pipeline, iOS
concurrency under blanket `MainActor`, backend security/abuse). 11-finder
fan-out → dedup → 3-skeptic adversarial verification (≥2/3 to survive) → synthesis
filtered against `audit-findings-tracker.md`. 13 candidates → 10 confirmed. None
duplicates a previously-fixed finding.

Dominant theme: several `NotificationCenter` observers use the target/selector
overload with **no `queue:`**, so handlers run on iOS's background posting thread
and mutate `@Published` state — a race class the `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor` default hides from the compiler.

Status legend: ⬜ open · 🟡 in progress · ✅ fixed.

## Critical / High

| # | Sev | Status | File:line | Defect | Fix |
|---|-----|--------|-----------|--------|-----|
| 1 | Critical | ⬜ | `Services/AVPlayerPath.swift:264` | `.AVPlayerItemDidPlayToEndTime` observer registered with `player, selector:` and no `queue:`; `playerItemDidFinish` (`PlayerManager.swift:895`) mutates `@Published` queue/currentTrack/isPlaying off-main on **every** track end. SwiftUI-from-background violation; data race vs. QueueView edits. | MainActor-hop the selector body (move to `advanceAfterItemEnd`), or register block-based with `queue: .main`. |
| 2 | High | ⬜ | `Managers/PlayerManager.swift:226` | Interruption + route-change observers use `self, selector:` with no `queue:`; `handleInterruption`/`handleRouteChange` mutate `@Published` state off the audio-session thread. | Wrap each selector body in `Task { @MainActor [weak self] in … }` or register with `queue: .main`. |
| 3 | High | ⬜ | `Services/AVPlayerPath.swift:96` | Rate observer maps `rate==0 → .paused`, can't distinguish a stall from a user pause. Stall watchdog (line 141) is gated on `playbackState == .playing`; the two KVO callbacks race (no ordering), so a stall can set `.paused` first → watchdog never arms → stale signed URL never re-resolves → stuck in fake `.paused`. | Observe `timeControlStatus` (treat `.waitingToPlayAtSpecifiedRate` as rebuffering) instead of inferring from `rate`; and/or replace the gate with a `wasPlaying` flag. |
| 4 | High | ⬜ | `Services/AudioEQ.swift:146` | `au` is a non-atomic `AudioUnit?` with no lock. `setParam` (MainActor) copies the raw pointer then calls `AudioUnitSetParameter`; `unprepare()` (off-main from the tap C callback `AudioEQTap.swift:126`) does `AudioComponentInstanceDispose(au); au=nil`. Interleave → use-after-free. | Serialize all `au` access (guard + set + render + dispose) behind one `os_unfair_lock`/serial queue, or hop `unprepare()` to MainActor. |
| 5 | High | ⬜ | `backend/app.py:874` | `_evict_if_needed` skips `.part` files and never unlinks them; `_total_cache_bytes` ignores them; `_cleanup_partial_files()` runs only at startup. Partials accumulate, uncounted + unevictable → disk fills → permanent 507 until restart. | Sweep `<basename>.*.part` in the `/api/play` failure path; make eviction treat partials as deletable (or account their size). |
| 6 | High | ⬜ | `backend/app.py:306` | `idx = len(parts) - TRUSTED_PROXY_COUNT - 1` is one position too far left → returns an attacker-forged XFF hop as the client IP (verified: `['EVIL','203.0.113.9']`, N=1 → `'EVIL'`). Feeds the rate-limit key → per-request bucket rotation (bypass) or victim-pinning (targeted 429). Test `tests/test_app.py:118-126` enshrines the wrong index. **Latent until `TRUSTED_PROXY_COUNT ≥ 1`.** | `idx = len(parts) - TRUSTED_PROXY_COUNT`; if `idx < 0` fall through to socket peer. Fix the test to model the proxy appending the real IP on the right. |

## Medium

| # | Sev | Status | File:line | Defect | Fix |
|---|-----|--------|-----------|--------|-----|
| 7 | Medium | ⬜ | `backend/app.py:887` | Grace-period eviction `continue`s all candidates under `CACHE_EVICT_GRACE_SECONDS`; a fast run of distinct IDs keeps every file "fresh" → frees zero bytes, exceeds `MAX_CACHE_GB` unbounded (enforced only by 507). | If a full pass frees nothing while over cap, evict oldest non-current regardless of grace (hard-cap override), or scale grace with utilization. |
| 8 | Medium | ⬜ | `Services/AVPlayerPath.swift:130` | Stale item-A `.readyToPlay` block, enqueued to main before `play(url:)` swaps to item B, writes `self.playerItem?.forwardPlaybackEndTime` against **live B** (no identity guard). Can truncate B. Ordering hazard (not a race). | After the main hop, `guard self.playerItem === item else { return }`; write to captured `item`. |
| 9 | Medium | ⬜ | `backend/app.py:202` | Corrupt `.access_times.json` → `_load_access_times` leaves table empty; startup scan never re-seeds from mtime. All `last_access` default to 0 → grace protects nothing, eviction sort collapses to `glob()` order, can drop recently-played. Self-heals. | Fall back to `st_mtime` on parse failure and for missing vids; seed from mtimes in the startup scan. |
| 10 | Medium | ⬜ | `Managers/FavoritesManager.swift:19` | `deinit { debouncer.flush() }` runs `{ [weak self] in self?.performSave() }`; during deinit the weak load is nil → flush writes nothing, pending mutation dropped. Bounded today (app-lifetime `@StateObject` singletons; real durability via scenePhase/willTerminate `flushAllStores()`). Bites transient instances/tests. | Capture the store + a value snapshot strongly in the deinit flush, or save synchronously in `deinit`; else remove the misleading net. |

## Rejected in verification (transparency)
- Unclamped frame count into `AudioUnitRender` (>8192) — unreachable under normal render quantums.
- `Debouncer.flush()` ignores the inline `call(_:)` action — real footgun but untriggerable today (only `EqualizerState` uses `call(_:)`, never `flush()`).
- `NowPlayingService` artwork closure captures `self` — no cycle (`player`/`favorites` are `weak`), session-lifetime singleton.

## Fix plan & automation classification
See the companion plan; lanes grouped by disjoint write-set:
- **L1 Backend (#5,#6,#7,#9)** — all `backend/app.py` + pytest. Fully automatable end-to-end.
- **L2 Manager durability (#10)** — deinit flush; unit-testable. Fully automatable.
- **L3 AudioEQ UAF (#4)** — `AudioEQ.swift`/`AudioEQTap.swift`; lock. Automate + build; device-test EQ.
- **L4 Off-main + ordering (#1,#2,#8)** — `AVPlayerPath.swift`/`PlayerManager.swift`; MainActor hops + identity guard. Automate + build; device sanity (advance/interruption).
- **L5 Stall recovery (#3)** — `AVPlayerPath.swift` rate→`timeControlStatus`; sequence after L4; device-test heavy.
