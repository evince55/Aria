# Aria — Lanes & Dispatch Board

Companion to [`audit-findings-tracker.md`](audit-findings-tracker.md). The tracker is the
**findings ledger** (what's wrong, severity, current-code evidence). This file is the
**dispatch board**: it splits the work into non-overlapping *lanes* so concurrent
sessions never write the same file, and tracks who owns what.

## The one rule

**Concurrent sessions must have disjoint write-sets.** One lane = one git worktree = one
branch. `main` stays clean; PRs are the approval gate. If two pieces of work would write
the same file, they are the *same lane* and run sequentially — never in parallel.

## Lanes

| Lane | Owns (write-set) | Repo | Tracker sections | Active branch | Status |
|---|---|---|---|---|---|
| **llmops** | `tools/llmops/**` | aria-llmops | (telemetry / evals / routing-loop) | — | idle |
| **backend** | `backend/**` (esp. `app.py`), `Aria---Music-Browser-Info.plist` (ATS), `Services/TLSPinningDelegate.swift`, `.github/workflows/**` | Aria | Backend — Cache & Reliability · Security & Abuse · Streaming & Latency | `feat/backend-cover-art` | claimed |
| **playback** | `Managers/PlayerManager.swift`, `Services/AVPlayerPath.swift`, `Services/NowPlayingService.swift`, `Services/StreamResolver.swift`, `Services/RadioService.swift`, `Managers/EQ*`, queue logic | Aria | iOS — Playback Engine · System Integration · Networking & Offline; Product — Feature Gaps (shuffle/repeat/prev/sleep-timer/speed) | — | idle |
| **data** | `Managers/KeyValueStore.swift`, `Services/AtomicFileWriter.swift`, `Managers/LocalLibraryManager.swift`, `Models/*` stores, schema/migrations, queue persistence | Aria | iOS — Data, Queue & Persistence | — | idle |
| **ui** | `Views/**`, `Resources/DesignSystem*`, `ThemeManager`, `Services/AsyncCachedImage.swift`, Dynamic Type, VoiceOver, iPad | Aria | iOS — UX, Architecture & Accessibility; iOS — Search & Discovery (UI) | — | idle |

## Hotspots — single-owner, never parallelize

- `Managers/PlayerManager.swift` → **playback** only. (~1000-line god object; the #1 source of past overlap.)
- `backend/app.py` → **backend** only.
- `.github/workflows/ci.yml` → **backend** only (it also runs every lane's tests).

If your task needs a file in another lane's write-set, **stop** and hand it to that lane
via a PR comment or an issue — do not reach across the boundary.

## Claim protocol (the state machine)

Status flows: `open → claimed → in-PR → done` (or back to `open` on denial).

1. **Claim** — set the lane's **Status** to `claimed` and fill **Active branch**, then create a
   worktree on `feat/<lane>-<slug>`.
2. **One active worker per lane.** If a lane is `claimed` or `in-PR`, don't start another in it.
3. **Implement only inside your write-set.** Tests for your change travel with it.
4. **Open a PR** → set Status `in-PR`. **The user approves (merge) or denies (close).**
   - On **merge**: set the lane back to `idle`, mark the finding `✅ done` in the tracker.
   - On **deny**: set the lane back to `idle`, finding back to `open`, and append the rejection
     reason to [`lane-lessons.md`](lane-lessons.md).

## Cross-cutting

- **Tests** travel with the code; the CI workflow file is owned by **backend**.
- **Decisions/tradeoffs** → Obsidian vault. **Durable facts** → agent memory. **Mid-task state**
  → `.superpowers/sdd/progress.md` in the lane's worktree.
- **Self-improvement** → every denied or reworked PR adds a line to `lane-lessons.md`; the lane
  kickoff prompts in [`lane-kickoff-prompts.md`](lane-kickoff-prompts.md) are refined from those
  lessons over time.

## Automated dispatch (you-driven mode)

The cycle is automated up to the PR; the merge is always yours. Driven by the `/dispatch`
slash command (`~/.claude/commands/dispatch.md`), single-pass, one worker per invocation.

- **`/dispatch <lane>`** — picks the next `open` finding in that lane, spins up a worktree,
  runs one single-pass worker (no reviewer agent), opens a **draft PR**, sets the lane `in-PR`,
  and stops. You review and merge (or close).
- **After your verdict**, tell the dispatcher: *merged* → finding `✅ done`, lane `idle`,
  worktree removed; *denied* → finding `open`, lane `idle`, and a line appended to
  `lane-lessons.md`. Recurring lessons get folded into that lane's kickoff prompt
  (**self-improvement** — those prompt edits are themselves PR'd, so the loop never silently
  rewrites its own instructions).
- **Guarantees:** never auto-merges; one worker per lane; worker confined to the lane's
  write-set; one finding per PR; single-pass (no reviewer/meta agents) unless you opt in.

Run lanes with disjoint write-sets in parallel (`/dispatch backend` and `/dispatch ui` at once
is safe); never two that share a hotspot.
