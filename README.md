# Aria

iOS music player combining YouTube streaming (backend-mediated) with a
local high-quality file library (FLAC, MP3, AAC, ALAC, AIFF, WAV), a
10-band parametric EQ, and natural-language search over your own library.
iOS 16.6+, Swift 5, no third-party dependencies.

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
- **Ask Your Library** — natural-language search over your own library,
  backed by hybrid lexical + vector retrieval. See
  [Ask Your Library](#ask-your-library) below.
- **Smart playlists** — rule-based playlists evaluated live against the
  library rather than frozen at creation time.
- **M3U import / export + bulk folder import** — round-trip playlists and
  import a directory tree in one action.
- **AutoEQ profiles** — browsable AutoEQ catalog; search your headphones
  and apply a measured correction curve in one tap, or import a profile.
- **Offline downloads** — hold-to-queue with an audio-quality badge.
- **Aria Pro** — StoreKit 2 one-time unlock gating parametric EQ + AutoEQ,
  smart playlists, and M3U/folder import.

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

## Build it yourself

Aria is MIT-licensed and there's no App Store build yet, so the way to get
it on your phone today is to build it. **You need a Mac** — Xcode is
macOS-only and there is no way around that.

Try it with no Apple ID and no phone at all:

```sh
make sim
```

Put it on your own iPhone:

```sh
make doctor    # tells you exactly what's missing, if anything
make install
```

That's it. `make` figures out your Team ID, picks a bundle ID nobody else
can be holding, provisions, builds, and installs over the cable. Plug the
phone in, unlock it, tap **Trust**, and run it.

### What you need

- **A Mac** with **Xcode 26.5+** (App Store, ~15 GB). Then
  `sudo xcode-select -s /Applications/Xcode.app`.
- **An Apple ID** — a free one is fine. Add it in Xcode → Settings →
  Accounts, then open `Aria.xcodeproj` once and pick your team under
  Signing & Capabilities. `make sim` doesn't need this.
- **An iPhone on iOS 16.6+**, for `make install`.

### The 7-day thing — read this before you start

**If you sign with a free Apple ID, the app stops launching after 7 days.**
Not the download, not the build: the installed app itself refuses to open
until you plug back into your Mac and re-run `make install`. Your music,
playlists, and settings survive; only the signature expires.

This is Apple's limit on free provisioning, not Aria's, and every
sideloaded iOS app has it. A paid Apple Developer account ($99/yr) raises
it to a year. If a weekly rebuild sounds like more than you signed up for,
that's a completely reasonable place to stop — watch the repo for a
TestFlight link instead.

Free provisioning also can't grant the CarPlay entitlement, so a
self-built copy won't have CarPlay even once it ships.

### Overrides

Everything auto-detects, but nothing is mandatory:

```sh
make install TEAM=ABCDE12345 BUNDLE_ID=com.you.aria DEVICE=<udid>
make sim SIM="iPhone 17 Pro"
```

The committed `DEVELOPMENT_TEAM` is the maintainer's, and the committed
bundle ID is already registered — building through `make` overrides both,
which is the whole reason it exists. Opening the project in Xcode and
hitting Run instead will fail signing until you change them by hand.

### After it's installed

Aria starts as a **local-file player with no server configured** — import
some FLACs from the Files app and you're done. If you self-host, point it
at your server under **More → Backend**: pick Subsonic for
Navidrome/Airsonic/Gonic, or Aria Backend if you deployed
[`backend/`](backend/) yourself. Plain `http://` to a LAN address works;
see [ATS / TLS](#ats--tls) if your server is somewhere else.

## Deployment

[`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) covers both avenues: personal
installs (Xcode direct / TestFlight, homelab backend over Tailscale) and App
Store submission (hardened Release plist, privacy manifest, export compliance,
and an honest 5.2.3 review-risk assessment). Release builds use
`Aria---Music-Browser-Info-Release.plist` — no ATS bypass, HTTPS backend
required.

## Test

```sh
make test
```

432 tests across 46 files in `AriaTests`, plus 149 backend tests
(`python3 -m pytest backend/tests`). `AriaTests` includes `LocalLibraryManagerTests`
(import, metadata, orphan cleanup, repair, atomic write, format gate,
cloud + zero-byte rejection), `PlayerManagerTests` and
`PlayerManagerMissingTrackTests` (queue, play generation, EQ
transitions, network, local-track routing, playSlice with missing
tracks), `LibraryViewModelTests` (search/sort/group/persistence), and
the rest of the suite (`EQController`, `EqualizerState`, `Debouncer`,
`FavoritesManager`, `PlaylistsManager`, `PlaybackState`, `Loadable`,
`FloatClamp`, `TLSPinningDelegate`, `YouTubeSearchService`).

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

## Configuration

### Backend URL

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

## Building for your device (with your Tailscale homelab)

> Maintainer-specific. If you just want Aria on your phone, use
> [Build it yourself](#build-it-yourself) and set your server in-app under
> More → Backend — you do not need any of this.

The GitHub source ships with `ARIA_HOMELAB_HOST = 192.0.2.1` (the
RFC 5737 placeholder). To run the app on your phone against your
own Tailscale homelab, set the host in **one** of two ways before
building. The GitHub source stays clean with the placeholder; the
real IP only lives in your local copy.

### Option A: Edit the Info.plist directly (simplest)

Open `Aria---Music-Browser-Info.plist` and change:

```xml
<key>ARIA_HOMELAB_HOST</key>
<string>192.0.2.1</string>
```

to:

```xml
<key>ARIA_HOMELAB_HOST</key>
<string>100.76.103.1</string>     <!-- your Tailscale IP -->
```

One-line change. `git status` will show this as a local modification
that you can keep unstaged (or `git update-index --skip-worktree`
the file so it never shows up again).

### Option B: Override at build time via User-Defined build setting (no source edit)

In Xcode: Project → Info → Configurations → select Debug (and Release
if you want) → click `+` to add a User-Defined Setting, name it
`ARIA_HOMELAB_HOST`, value = your Tailscale IP. Or via the command
line, add to your scheme's "Run" action's environment variables /
"Arguments Passed On Launch".

This requires changing the `Info.plist` key to use the
`$(ARIA_HOMELAB_HOST)` substitution syntax so the build setting
flows into the compiled Info.plist at build time:

```xml
<key>ARIA_HOMELAB_HOST</key>
<string>$(ARIA_HOMELAB_HOST)</string>
```

And adding a default build setting in `Aria.xcodeproj/project.pbxproj`
for both Debug and Release configurations so the build doesn't fail
if you forget to set it:

```
ARIA_HOMELAB_HOST = 192.0.2.1;
```

**If you go with Option B, commit that change as a separate, focused
commit** (e.g. "chore: use \$(ARIA_HOMELAB_HOST) substitution so the
host is overridable via build setting") so it's clearly opt-in and
easy to revert.

### What the host does

When `ARIA_HOMELAB_HOST` is set, both:
- `PlayerManager.backendURL` (DEBUG fallback only) — builds
  `http://<host>:8000`
- `TLSPinningDelegate.devHost` — gates the cert pin to `<host>`

read from it. The existing `ARIA_BACKEND_URL` Info.plist key still
wins if set (useful for pointing at a non-homelab backend without
rebuilding). Release builds keep the public Render URL by default.

### ATS

`NSAllowsLocalNetworking = true` is already in the Info.plist, so
any Tailscale IP is allowed without a per-IP `NSExceptionDomains`
entry. The existing `NSExceptionDomains` key for `192.0.2.1` becomes
a no-op once you set a real host; you can leave it in or remove it.

### Tailscale on the phone

The phone needs the [Tailscale app](https://tailscale.com/download/)
installed and logged in to the same tailnet as the homelab, with
the homelab node advertising the right MagicDNS name (or the phone
using the homelab's Tailscale IP). Tailscale handles the WireGuard
tunnel transparently.

## Project memory

`AGENTS.md` at the workspace root (one level up from this repo) is
loaded by the assistant for this project. Update it when the build
commands, architecture, or conventions change.
