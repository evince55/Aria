# Aria

iOS music player combining YouTube streaming (backend-mediated) with a
local high-quality file library (FLAC, MP3, AAC, ALAC, AIFF, WAV) and
a 10-band parametric EQ. iOS 16.6+, Swift 5, no third-party dependencies.

## Features

- **YouTube streaming** — search and play are routed through a backend
  (`/api/play?video_id=...`) that resolves stream URLs. The iOS app
  holds no YouTube Data API key.
- **Local file library** — import FLAC/MP3/AAC/ALAC/AIFF/WAV from the
  Files app; AVFoundation handles decoding. Files are copied into the
  app sandbox and re-located across launches (security-scoped bookmarks
  are not used).
- **10-band parametric EQ** — global EQ that runs through `AVAudioEngine`
  for local files. Presets (Flat, Bass Boost, Treble Boost, Vocal,
  Lounge, Rock, Pop, Classical) plus per-band control.
- **Lock-screen / control-center integration** — `MPNowPlayingInfoCenter`
  + `MPRemoteCommandCenter` configured in `NowPlayingService`.
- **Robust library management** — missing files are detected on
  launch and on every Library tab visit; missing tracks can be re-imported
  or removed via a dedicated repair sheet.
- **Search, sort, group, persist** — in-library search; sort by
  recently-added / title / artist / duration / file size; group by
  album or artist; sort/group preferences persist across launches
  via `@AppStorage`.

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
       ├─ LibraryViewModel    (search/sort/group, @AppStorage persistence)
       └─ FavoritesManager, PlaylistsManager, RecentlyPlayedManager

Views/
  Root/      ContentView, custom tab bar, NavigationCoordinator
  Library/   LibraryView, LibraryTrackRow, LibrarySectionView,
             MissingTrackRepairSheet, LibraryViewModel
  Player/    FullScreenPlayerView, MiniPlayerView, EqualizerView,
             QueueView, AddToQueueModifier
  Search/    SearchView
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

## Build

Open `Aria.xcodeproj` in Xcode 26.5+ and run the `Aria - Music Browser`
scheme on an iOS 16.6+ simulator or device.

CLI build:

```sh
xcodebuildmcp build_sim --scheme "Aria - Music Browser"
```

## Test

```sh
xcodebuildmcp test_sim --scheme AriaTests
```

157 tests across 19 files. `AriaTests` includes `LocalLibraryManagerTests`
(import, metadata, orphan cleanup, repair, atomic write, format gate,
cloud + zero-byte rejection), `PlayerManagerTests` and
`PlayerManagerMissingTrackTests` (queue, play generation, EQ
transitions, network, local-track routing, playSlice with missing
tracks), `LibraryViewModelTests` (search/sort/group/persistence), and
the rest of the suite (`EQController`, `EqualizerState`, `Debouncer`,
`FavoritesManager`, `PlaylistsManager`, `PlaybackState`, `Loadable`,
`FloatClamp`, `TLSPinningDelegate`, `YouTubeSearchService`).

## Configuration

### Backend URL

`PlayerManager.backendURL` resolves at launch in this order:

1. `Bundle.main.object(forInfoDictionaryKey: "ARIA_BACKEND_URL")` — set
   the `ARIA_BACKEND_URL` key in `Aria---Music-Browser-Info.plist` (or
   a build-config override) to point at your backend.
2. **DEBUG build** — falls back to the dev-backend URL, built from
   `ARIA_HOMELAB_HOST` in Info.plist (see "Dev homelab setup" below).
3. **Release build** — falls back to the public Render URL
   `https://aria-backend-px9s.onrender.com`.

### Dev homelab setup

The DEBUG-build fallback is for talking to a local backend over a
Tailscale tunnel. The original Tailscale IP and the matching
`NSExceptionDomains` entry in `Aria---Music-Browser-Info.plist` have
been **scrubbed from this public source and replaced with the
RFC 5737 TEST-NET-1 placeholder `192.0.2.1`** (reserved for
documentation, URL-safe, never routable). The `192.0.2.1` placeholder
appears in 6 places:

- `Aria---Music-Browser-Info.plist` (ATS exception key + the
  `ARIA_HOMELAB_HOST` value)
- `Managers/PlayerManager.swift` (DEBUG `backendURL` fallback)
- `Services/TLSPinningDelegate.swift` (doc comment + hostname gate)
- `Tests/YouTubeSearchServiceTests.swift`
- `Tests/TLSPinningDelegateTests.swift` (3 sites)

**The single override you need: set `ARIA_HOMELAB_HOST` in
`Aria---Music-Browser-Info.plist` (or via a User-Defined build
setting that flows into Info.plist) to your actual Tailscale IP.**
Both the `PlayerManager.backendURL` and the `TLSPinningDelegate`
hostname gate resolve from this one key. The Info.plist ATS exception
key for `192.0.2.1` becomes a no-op once the URL is overridden; the
existing `NSAllowsLocalNetworking = true` covers any Tailscale IP.

The 2 live integration tests
(`test_LiveSearchReachesHomelab`,
`test_LivePinningToHomelabBackend`) skip when `ARIA_HOMELAB_HOST` is
the placeholder — they need a real reachable host to exercise the
full URLSession → TLS → pin path. Once you set the key, the tests
will run.

To use the dev backend, after setting the key:

1. Run the backend on `<your-ip>:8000` (HTTP) and `<your-ip>:8443`
   (HTTPS, with a self-signed cert if you want the
   `TLSPinningDelegate` path to fire).
2. The `TLSPinningDelegate` only pins the dev host in DEBUG; in
   Release it accepts public-CA certificates without pinning.

### ATS / TLS

`Aria---Music-Browser-Info.plist` sets:

- `NSAllowsArbitraryLoads = true` (Release builds still talk to
  `googlevideo.com` which serves mixed HTTP/HLS; this is the smallest
  config that works without per-resource exceptions for every Google
  CDN host).
- `NSAllowsLocalNetworking = true` (lets the simulator talk to a
  local backend without HTTPS).
- `NSExceptionDomains` for `googlevideo.com` (insecure HTTP allowed,
  with subdomains) and `192.0.2.1` (the placeholder homelab Tailscale
  IP — see "Dev homelab setup").

## Local files in more detail

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

## Manual smoke test (per the design spec)

After building locally, the per-phase smoke tests in
`docs/superpowers/specs/2026-06-25-offline-player-robustness-design.md`
walk through the user-visible flows. The TLSPinningDelegate
integration test (`test_LivePinningToHomelabBackend`) is a live test
that requires the homelab to be reachable; it will fail under the
placeholder configuration by design.

## License

MIT — see `LICENSE`.

## Sample data (optional, for first-run friendliness)

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

## Project memory

`AGENTS.md` at the workspace root (one level up from this repo) is
loaded by the assistant for this project. Update it when the build
commands, architecture, or conventions change.
