# Developing Aria

For installing and using Aria, see the [README](../README.md).

## Build and test

```sh
make help      # list the available targets
make doctor    # check your setup
make sim       # build and run in the simulator
make install   # build and install on a connected iPhone
make test      # run the iOS tests
python3 -m pytest backend/tests
bash backend/tests/docker_smoke.sh   # needs Docker
```

`make` works out your Team ID and picks a bundle ID you can use. You can override
what it detects:

```sh
make install TEAM=ABCDE12345 BUNDLE_ID=com.you.aria DEVICE=<udid>
make sim SIM="iPhone 17 Pro"
```

The committed `DEVELOPMENT_TEAM` and bundle ID are the maintainer's, so running
from Xcode fails signing until you change them.

## Architecture

```
AriaApp
  └─ AppEnvironment (typed env keys)
       ├─ PlayerManager       (playback state; AVPlayer + engine paths)
       │    ├─ NowPlayingService
       │    ├─ EQController (+ EqualizerState debounce bridge)
       │    ├─ EQCache
       │    ├─ AVPlayerPath    (no-EQ AVPlayer path)
       │    ├─ StreamResolver  (async /api/play fetcher)
       │    └─ TLSPinningDelegate (dev-only cert pin)
       ├─ LocalLibraryManager (file import, metadata extraction, persistence)
       │    └─ KeyValueStore → JSONFileStore
       ├─ LibrarySyncService  (doc composition, SHA-256 delta sync)
       ├─ LibrarySearchService / LibrarySearchManager (Ask Your Library)
       ├─ LibraryViewModel    (search/sort/group, @AppStorage persistence)
       └─ FavoritesManager, PlaylistsManager, RecentlyPlayedManager

Views/
  Root/      ContentView, custom tab bar, NavigationCoordinator
  Library/   LibraryView, LibraryTrackRow, LibrarySectionView,
             MissingTrackRepairSheet, LibraryViewModel
  Player/    FullScreenPlayerView, MiniPlayerView, EqualizerView,
             QueueView, AddToQueueModifier
  Search/    SearchView (YouTube + Library scopes)
  Playlists/ PlaylistsView, PlaylistDetailView
  Favorites/ FavoritesView
  More/      SettingsView, etc.
  Shared/    TrackThumbnail, TrackRow, AsyncCachedImage, ShimmerView
```

Data flow: views observe `@Published` state on `@MainActor` managers;
players are injected via `.environmentObject(...)` from `AriaApp`.
Managers own their long-lived state (no shared globals); services
(EQCache, StreamResolver, NowPlayingService) are owned by their
respective managers.

## Backend configuration

`Services/BackendConfig.swift` owns this. It is resolved **per read**, not
frozen at launch, so a change in Settings applies without a restart:

1. The in-app override — **More → Backend**, stored in `UserDefaults`.
   This is how a self-built copy is meant to be pointed at a server; no
   source edit needed.
2. The `ARIA_BACKEND_URL` Info.plist key.
3. `http://<ARIA_HOMELAB_HOST>:8000` (see "Dev homelab setup" below).

Both plists ship `ARIA_BACKEND_URL` empty and `ARIA_HOMELAB_HOST` set to
the RFC 5737 placeholder `192.0.2.1`, so a fresh build talks to **no
server at all** and runs as a local-files-only player — the Search tab
hides until you configure one. It cannot phone home to anyone else's
backend.

`BackendConfig.serverKind` picks the protocol: `aria` for the yt-dlp
backend in [`backend/`](backend/), `subsonic` for any Subsonic-compatible
server. Subsonic additionally needs a username and password; the password
is held in the Keychain, never `UserDefaults`, and is never transmitted
(Aria sends a salted MD5 token).

## Testing against your own server

Debug builds allow plain HTTP, so you can use a private address such as a Tailscale
IP. Enter it under **More → Backend**, or set `ARIA_HOMELAB_HOST` in
`Aria---Music-Browser-Info.plist` and keep that edit out of git:

```sh
git update-index --assume-unchanged Aria---Music-Browser-Info.plist
```

The repo must keep the placeholder `192.0.2.1`. The two live tests,
`test_LiveSearchReachesHomelab` and `test_LivePinningToHomelabBackend`, skip on the
placeholder. With a real address they contact that server, and they send no API key.

Release builds have no blanket ATS bypass, so a server that works from Xcode can
still be refused by a `make install` build. Use HTTPS there.

## Ask Your Library

Natural-language search across your own library — "mellow acoustic stuff I
played a lot last winter" rather than an exact title match. Built in four
slices against `docs/design/2026-07-28-rag-library-search-spec.md`.

**How retrieval works.** Each track is composed into a short document
(title, artist, album, duration bucket, playlist membership, affinity
flags) and hashed with SHA-256; only changed docs are re-synced. The
backend indexes those docs two ways and fuses the results:

```
query ──┬─► FTS5 / BM25          top-50 ─┐
        └─► sqlite-vec cosine     top-50 ─┴─► Reciprocal Rank Fusion (k=60) ─► top-k
                (768-dim, nomic-embed-text-v1.5 via llama-swap)
```

Each hit is labelled `lexical`, `vector`, or `both`. If the embedder is
unreachable the query degrades to BM25-only and reports `mode: lexical`
rather than failing — vectors are backfilled on a later sync.

**Privacy.** Indexes are per-device and scoped by a stable `device_id`.
Raw query text and document text are never logged — only lengths, counts,
latency and mode; `aria-backend.service` passes `--no-access-log` so
uvicorn cannot journal `/api/library/query?q=...`. Changing the backend URL
issues `DELETE /api/library` and resets local state. FTS5 input is
sanitized against query injection.

**Quality is gated in CI.** `tests/eval_harness.py` measures recall@k and
nDCG@k over hand-labeled fixtures served by a fixture embedder, so no
network is needed in CI. The golden-set test skips loudly until the
fixtures exist, then fails the build if hybrid recall@10 or nDCG@10 drops
below `eval_baseline.json`, and warns if the hybrid lift over lexical
inverts. Labels are authored by hand — never model-generated — so the
labeller is independent of the system under test.

**Endpoints.** `POST /api/library/sync` (delta upsert, 2 MB / 5000-track
caps), `GET /api/library/query`, `DELETE /api/library`. All behind the API
key and a dedicated rate-limit bucket. `/api/health` reports
`library_index {tracks, embedder}`.

**Config.** `ARIA_EMBED_URL` points at an OpenAI-format `/v1/embeddings`
endpoint — in this deployment, llama-swap on the Windows GPU box over the
tailnet, serving `nomic-embed-text-v1.5` (Q8_0, 768-dim). Without it the
feature runs lexical-only.

## Local files

### Import

`LocalLibraryManager.importFile(at:)` is the entry point. It:

1. Starts access on the security-scoped URL.
2. Rejects the import if the file is in iCloud Drive and not yet
   downloaded.
3. Rejects the import if the file is zero bytes.
4. Probes the file extension via `AudioFormat.detect(extension:)`
   (synchronous, no AVFoundation call) and, for unknown extensions,
   `AVURLAsset.load(.tracks)` (async, one probe call). Rejects
   unsupported formats (OGG/Opus/WMA/APE) with a typed
   `ImportError.unsupportedFormat(...)`.
5. Copies the file into `Documents/AriaLibrary/<uuid>.<ext>` via
   `AtomicFileWriter.writeAtomically(_:to:)` (temp-and-rename with
   rollback on failure).
6. Extracts title/artist/duration/artwork from
   `AVAsset.commonMetadata` and `commonMetadata` (album extraction
   added in B3).
7. Persists via `KeyValueStore` → `JSONFileStore` in
   `Documents/local_library.json`.

### Missing-file tracking

`LocalLibraryManager.auditMissingFlags()` walks the library on init
and on every Library tab appearance, setting `LocalTrack.isMissing`
based on `FileManager.fileExists`. `PlayerManager.playLocal` refuses
to play missing files (sets `PlayerError.trackMissing(...)` and
`playbackState = .ended`). `playSlice` filters missing tracks from
the playable queue. The `MissingTrackRepairSheet` lets users
re-import a replacement file or remove the broken entry.

### Orphan cleanup

`LocalLibraryManager.cleanupOrphans()` runs on init and on
`scenePhase = .active` (ContentView wires it). It walks
`AriaLibrary/` and removes any audio or artwork file whose UUID
prefix isn't in the current `tracks` set, keyed on
`fileName.prefix(36)` (not `id.uuidString` — repaired tracks have a
fresh on-disk UUID with the same stable `id`).

### Format validation

`AudioFormat` is a Swift enum covering the supported set
(mp3, aac, alac, flac, aiff, wav) and the rejected set
(ogg, opus, wma, ape). `ImportError` carries the format and a
human-readable description; `LibraryView.importURLs(_:)` switches
over the three cases (`.unsupportedFormat`, `.fileNotDownloaded`,
`.zeroByteFile`) to surface actionable alert text per case.

### Library scale UX

`LibraryViewModel` mirrors `LocalLibraryManager.tracks` via Combine
and exposes `searchText`, `sortOrder` (5 options), and `groupBy`
(3 options) as `@Published` properties. The view layer owns
`@AppStorage("librarySortOrder")` and `@AppStorage("libraryGroupBy")`
and passes the resolved values into the VM at init. The
`LibraryView` body uses `ScrollView { LazyVStack { ForEach(vm.sections)
{ LibrarySectionView } } }` for explicit virtualization at any
library size.

## Sample data

The `LocalLibraryManager.sampleData/` directory in the repo is a
**gitignored template** for sample audio files. The app checks a
runtime location (`Documents/AriaLibrary.sampleData/` in the app
sandbox) on every launch and imports any audio files it finds that
aren't already in the library. See
`LocalLibraryManager.sampleData/README.md` for the import workflow
(simulator + device paths, how to copy files in, gitignore rationale).

The directory is intentionally empty in the repo — drop your own
sample `.mp3` / `.flac` / etc. files in there locally for testing.
Audio files are gitignored so the repo doesn't bloat and so you
don't accidentally commit licensed content.

## Releasing

See [`DEPLOYMENT.md`](DEPLOYMENT.md) for TestFlight and App Store steps.
