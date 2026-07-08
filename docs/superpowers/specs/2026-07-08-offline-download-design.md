# Offline Download — Design Spec (2026-07-08)

## Goal

Let the user save a YouTube-sourced track to the device so it plays **offline**,
instantly, and without a backend round-trip — while the track keeps its YouTube
identity everywhere else in the app (no duplicate library entries).

Deploy target iOS 16.6, Swift 5, zero third-party deps. Managers injected via the
environment (`AppEnvironment`), persistence through `KeyValueStore` + `Debouncer`,
schema through `SchemaStore`/`VersionedEnvelope`, per existing conventions.

## Model (approved)

A download is **"save-offline, same track"** — NOT an import.

- The audio bytes are cached on disk keyed by **video id**.
- The `Track` is unchanged; there is no separate `LocalTrack` and no second
  identity. A song that is favorited *and* downloaded is one `Track`, shown in
  both Favorites and the new Library "YouTube Downloads" section.
- When playing a streamed `Track`, `PlayerManager` **prefers the local copy** if
  one exists → offline + instant, EQ tap works (it works on local files today).
- Trigger is **manual, per-track** (v1).

## Components

### `DownloadManager` (`ObservableObject`, env-injected)
Owns download state and the on-disk audio files.

Public API:
- `func state(for videoID: String) -> DownloadState` — `.none` / `.downloading(progress: Double)` / `.downloaded`
- `func localURL(for videoID: String) -> URL?` — the on-disk file, or `nil`
- `func download(_ track: Track) async` — guarded to streamed tracks (`!track.isLocal`, id is an 11-char video id)
- `func remove(_ videoID: String)` — delete file + record
- `@Published private(set) var downloads: [DownloadRecord]` — for the Library section
- `@Published private(set) var active: [String: Double]` — in-flight progress by id
- `func flushPendingWrites()` — for scenePhase/willTerminate parity with other managers

`DownloadState` is a small enum used by the UI (button + row).

### `DownloadStore` (persistence)
`KeyValueStore`-backed (`JSONFileStore(filename: "downloads.json")`), wrapped in
`SchemaStore`/`VersionedEnvelope` (schemaVersion = 1) exactly like the #10 stores.
Debounced writes (own `Debouncer`, 0.5s); flushed on scenePhase background /
`UIApplication.willTerminate` via the existing `flushAllStores()` path.

### `DownloadRecord` (`Codable`)
`{ videoID: String, fileName: String, sizeBytes: Int64, downloadedAt: Date,
   title: String, artist: String, thumbnailURL: URL? }`

The title/artist/thumbnail **snapshot** lets the Library render downloaded rows
offline without touching the network, and lets `download()` reconstruct a
playable `Track` from a record.

### Audio files
Stored at `Documents/Downloads/{videoID}.{ext}` (ext from the served file). One
file per video id. The `Downloads/` dir is created on first use.

### `DownloadButton` (SwiftUI view)
Reads `@EnvironmentObject var downloadManager`. Renders by `state(for:)`:
- `.none` → "download" icon (`arrow.down.circle`)
- `.downloading(p)` → determinate progress ring
- `.downloaded` → filled/checkmark (`checkmark.circle.fill`)

Tap: `.none` → `download(track)`, `.downloaded` → confirm → `remove(id)`.
Accessibility label reflects state.

## Download flow

1. User taps the download button on a streamed `Track`. Guard: `!track.isLocal`
   and `track.id` matches the 11-char video-id shape; otherwise no-op.
2. `download(_:)` sets `active[id] = 0`, then:
   `GET {backendURL}/api/play?video_id={id}` (+ `X-API-Key` when configured) —
   the backend downloads, validates, caches, and returns
   `{ "url": "/api/stream/{file}", "cached": Bool }`. Wrapped in `RetryPolicy`.
3. Stream `GET {backendURL}/api/stream/{file}` to `Downloads/{id}.{ext}`,
   **written to disk in chunks** (reuse the existing download-to-disk helper in
   `URLSessionProtocols`), updating `active[id]` from received/expected bytes.
4. On success: build a `DownloadRecord` (size from the file, title/artist/thumb
   from the `Track`), append to `downloads`, clear `active[id]`, debounced-save.
5. On failure (network, backend ≥400 after retries, disk-full): delete any
   partial file, clear `active[id]`, and set `DownloadManager.@Published var
   lastError: String?`. `ContentView` observes it and shows it through the same
   toast affordance it already uses for `PlayerManager.playerError` (cleared
   after display).

`X-API-Key`, `backendURL`, and the pinned/timeout `URLSession` come from the same
sources as `StreamResolver`/`PlayerManager` (opt-in key, `PlayerManager.backendURL`).

## Play-path integration

`PlayerManager` gains a `configureDownloads(_ manager: DownloadManager)` hook
(mirrors `configureFavorites`), wired in `ContentView.onAppear`.

In the streamed-play path, **before** resolving via `StreamPrefetcher`/
`StreamResolver`, check `downloads.localURL(for: track.id)`:
- present → play that file URL through `AVPlayerPath` (same as a local file: no
  network, EQ tap active). Set state as a normal local play.
- absent → existing resolve-and-stream path, unchanged.

`StreamPrefetcher` prewarm is skipped for a next-track that's already downloaded
(the check lives in `PlayerManager` before it asks the prefetcher).

## UI surfacing

**Trigger** (unchanged intent): `DownloadButton` in
- the full-screen player's secondary controls (next to favorite / share), and
- the track-row context menu.

**Browse / manage — Library tab, two sections** (`LibraryView`):
1. **On This Device** — existing imported local files (`LibraryViewModel` /
   `LocalLibraryManager`), unchanged, keeps sort/group/search.
2. **YouTube Downloads** — a new section fed by `DownloadManager.downloads`
   (v1: a plain list — artwork, title, artist, size; tap plays offline;
   swipe-to-remove; hidden when empty). No sort/search in v1.

A small "downloaded" glyph marks downloaded tracks in ordinary rows (search /
favorites / playlists) so offline availability is visible in context.

On launch, `DownloadManager` **reconciles**: drop any record whose file is
missing, and delete orphan files in `Downloads/` that have no matching record
(prevents leaked bytes after a crash mid-write).

## Error handling

- Backend/network error → partial-file cleanup + user-visible error + `RetryPolicy`.
- Disk-full (write throws) → caught, surfaced, partial cleaned up.
- Offline + not downloaded → plays as today (streamed path fails offline);
  downloaded tracks play fine.
- Corrupt/interrupted download → validated by size on completion; a too-small
  file is discarded (mirrors the backend's `_is_valid_media` size floor).

## Testing

`DownloadManagerTests` — hermetic (mock `URLSessionProtocol`, `InMemoryKeyValueStore`,
temp `Downloads/` dir), following `LocalLibraryManagerTests` conventions:
- `download` success writes both the record and the file; `state`/`localURL` reflect it.
- `remove` deletes file and record.
- reconcile drops records whose file is missing.
- the play-path prefers a downloaded local URL over resolving (via a
  `PlayerManager` test with a stubbed download manager).
- guard: `download` no-ops on a local (`isLocal`) track / malformed id.

## YAGNI — explicitly out of scope for v1 (future)

- Per-collection "Download all" (playlist / Favorites).
- Automatic / background download.
- `URLSession` **background** downloads (v1 is foreground-only).
- Global storage cap / LRU eviction (user manages via per-track remove).
- Sort / search within the YouTube Downloads section.

## File touch-list (for the plan)

- New: `Managers/DownloadManager.swift`, `Models/DownloadRecord.swift`,
  `Views/Shared/DownloadButton.swift`, `Tests/DownloadManagerTests.swift`.
- Edit: `App/AriaApp.swift` + `App/AppEnvironment.swift` (inject the manager),
  `Managers/PlayerManager.swift` (`configureDownloads` + prefer-local in play/prefetch),
  `Views/Root/ContentView.swift` (`configureDownloads`, flush on scenePhase/terminate),
  `Views/Library/LibraryView.swift` (second section),
  `Views/Player/FullScreenPlayerView.swift` + a row context menu (the trigger button).
