# Subsonic client support — design spike

**Date:** 2026-07-27
**Status:** Design only. **Recommendation: build it, in two phases.** Phase 1 is ~2–3 days
and unlocks the largest audience Aria has access to.
**Driver:** ranked **#2** in the [niche research](../../../.claude/) — "which iOS client?" is the
single most-asked question in r/selfhosted, r/homelab, and r/navidrome, and iOS has no answer that
people are happy with.

---

## Why this matters more than another Pro feature

Today Aria's "bring your own server" story means *the owner's personal yt-dlp backend* — a thing
exactly one person runs. Subsonic support changes the sentence to **"connect your Navidrome /
Airsonic / Gonic / Astiga server,"** which is a real, populated market with an active community
that evangelises clients.

It also **bulletproofs the App Store story**: the app becomes a client for a widely-used open
protocol, with the YouTube backend demoted to one optional server type among several. That is the
Finamp/play:Sub/Amperfy precedent, and it is a materially safer 5.2.3 posture than we have now.

**Accuracy note:** Navidrome, Airsonic(-Advanced), Gonic, Astiga, Funkwhale, and Nextcloud Music
speak Subsonic natively. **Jellyfin does not** — it needs a community plugin (JellySonic), which is
experimental and not enabled by default. Marketing should say *"Navidrome, Airsonic, and any
Subsonic-compatible server"* and mention Jellyfin only with the plugin caveat. A native Jellyfin
client is a separate (larger) project.

---

## What I verified live (not assumed)

Run against the public Navidrome demo (`demo.navidrome.org`, Navidrome 0.63.2, API 1.16.1):

| Assumption | Result |
|---|---|
| JSON envelope shape | ✅ `{"subsonic-response": {"status":"ok","version":"1.16.1","type":"navidrome","openSubsonic":true}}` |
| `search3` returns usable songs | ✅ `id`, `title`, `artist`, `album`, `duration`, `suffix`, `bitRate`, `contentType`, `coverArt`, `path` |
| **`stream.view` is directly playable** | ✅ `HTTP 206`, `content-type: audio/mpeg`, `accept-ranges: bytes` |
| **Salted-token auth works** (no plaintext password) | ✅ `t=md5(password+salt)` + `s=salt` → `status: ok` |

The two facts that make this cheap: **the stream URL is deterministic and never expires**, and
**the server honours HTTP range requests**, so AVPlayer plays and seeks it natively.

---

## The seam fit — better than the YouTube path

### `StreamResolving` becomes trivial

```swift
// Subsonic: no network call, no expiry, no cache, no `fresh` semantics.
func resolve(for songID: String) async throws -> ResolvedStream {
    ResolvedStream(url: endpoint("stream", ["id": songID]), duration: nil)
}
func resolve(for songID: String, fresh: Bool) async throws -> ResolvedStream {
    try await resolve(for: songID)          // nothing to bust
}
func stream(for songID: String) async throws -> URL { try await resolve(for: songID).url }
```

Every hard problem from the YouTube path **disappears**: no signed-URL expiry, no resolve-cache
poisoning (the bug behind the permanent "unknown error"), no `fresh=1` plumbing, no yt-dlp
extraction latency, no datacenter-IP blocking. `StreamPrefetcher` still works unchanged (it just
never has anything to prefetch).

### What changes structurally

1. **`BackendConfig` gains a server *kind*.** It currently resolves one URL. It needs
   `{ kind: .ariaBackend | .subsonic, url, username, password }`. The password must go to the
   **Keychain**, not `UserDefaults` — this is the first real credential Aria stores. (`ARIA_API_KEY`
   today is a shared secret for a personal server; a Subsonic password is a user account.)
2. **Search needs a protocol.** `YouTubeSearchService` (102 lines) is concrete and constructed
   directly in `SearchView:24`. Extract `MusicSearching { search(query:limit:offset:) -> [Track] }`
   and let `SubsonicClient` conform. Low risk, mechanical.
3. **`Track.id` namespacing.** Local files already use `local:<uuid>`. Subsonic songs should use
   `subsonic:<id>` so `PlayerManager.startPlayback`'s dispatch stays a simple prefix check and
   downloads/favorites can't collide across server types.

### Features that light up for free

Because `search3` returns `suffix` + `bitRate` + `duration`, **existing shipped features work with
no extra effort**: the quality badge (`AudioQuality.forFile`), smart-playlist duration/lossless
rules, and `coverArt` for artwork. That is a meaningful multiplier on the work already done.

---

## Phasing

### Phase 1 — "connect and play" (~2–3 days)
The minimum that makes an r/navidrome post honest.
- `SubsonicClient`: auth (salted token), `ping`, `search3`, `stream` URL construction, `getCoverArt`.
- `BackendConfig` server-kind + Keychain credential storage.
- Settings UI: server URL / username / password + **Test Connection** (reuse the existing pattern —
  `ping` maps onto it exactly).
- `MusicSearching` protocol extraction; `SearchView` unchanged otherwise.
- Tests: envelope decoding (incl. the `"failed"` + error-code path), token generation, URL building,
  stubbed search→Track mapping. All hermetic via `URLSessionProtocol`.

### Phase 2 — "browse your library" (~3–4 days)
Subsonic users expect to *browse*, not just search — this is where clients get judged.
- `getArtists` / `getAlbumList2` / `getAlbum` and a browse UI (new views, the real cost here).
- `getPlaylists` → import server playlists.
- `scrobble` (play reporting) and `star` ↔ Aria favorites sync.

### Deliberately out of scope
Transcoding negotiation (`maxBitRate`/`format`), offline sync of a whole server, and multi-server
profiles. All are post-launch refinements.

---

## Risks

- **Credential handling is new.** Keychain, not `UserDefaults`; never log the password or token;
  the salt must be regenerated per request. Worth a focused review pass.
- **Server variance.** Gonic/Airsonic/Astiga differ in optional fields; decode defensively
  (everything except `id` optional) and test against ≥2 implementations. The demo server used here
  is a good CI-free smoke target.
- **`openSubsonic: true`** signals newer extensions we can opportunistically use, but the baseline
  must stay plain Subsonic 1.16.1.
- **Scope creep into a full server client** is the real danger. Phase 1 must ship before Phase 2
  starts.

## Effort summary

| Piece | Estimate |
|---|---|
| Phase 1 (connect + search + play) | **2–3 days** |
| Phase 2 (browse + playlists + scrobble) | 3–4 days |

For comparison, the analogous YouTube pieces are `StreamResolver` 158 lines + `YouTubeSearchService`
102 lines; `SubsonicClient` will be somewhat larger (more endpoints) but structurally simpler
because there is no resolve/expiry/cache machinery.

## Recommendation

**Build Phase 1 next, ahead of CarPlay.** CarPlay is blocked on an Apple entitlement with weeks of
lead time (apply the day the paid account exists — that clock should start regardless). Subsonic is
unblocked, it is the #2 ranked want, it makes the launch narrative true, and it makes the App Store
positioning defensible. Phase 2 can follow once real users report what they browse for.
