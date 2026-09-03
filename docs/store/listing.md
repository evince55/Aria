# App Store listing

Character limits are App Store Connect's. Copy is deliberately server-neutral:
it never names YouTube (see `docs/DEPLOYMENT.md` §B3) and describes the app as
what the store build actually is — a local-file player that can connect to a
server you run.

## App Information

**Name** (30 max, 24 used)
```
Aria: Hi-Fi Music Player
```
Availability is not guaranteed — check it in App Store Connect before anything
else (`submission-checklist.md` step 3). Fallback if taken: `Aria Music Player`.

**Subtitle** (30 max, 26 used)
```
FLAC, EQ & your own server
```

**Primary category:** Music
**Secondary category:** none

**Age rating:** 4+ — answer **No** to every content question. The app has no
web browser, no user-generated content, no gambling, no contests. Music comes
from the user's own files or a server they configure.

**Support URL:** `https://chai-homelab.com/aria/support`
**Marketing URL:** `https://github.com/evince55/Aria`
**Privacy Policy URL:** `https://chai-homelab.com/aria/privacy`

**Copyright:** `2026 Eugene Vincent`

## Version Information (1.0)

**Promotional text** (170 max — editable without a new build)
```
A music player for people who own their music. Play FLAC and hi-res files with a parametric EQ and AutoEQ headphone profiles, or stream from your own Navidrome, Airsonic, or Gonic server.
```

**Description** (4000 max)
```
Aria is a music player for your own library — the files on your phone and the server in your home. No accounts, no catalogue, no ads, no analytics.

PLAY YOUR FILES
Import FLAC, ALAC, AIFF, WAV, MP3 and AAC from the Files app. Hi-res files play at their native quality and the library shows you what each track really is: lossless, 320 kbps, or standard.

HEAR IT YOUR WAY
A 10-band parametric equalizer runs on everything you play. Build your own curve, or pick your headphones from the AutoEQ catalogue and apply a measured correction in one tap. Save profiles per headphone and switch between them.

BRING YOUR OWN SERVER
Run Navidrome, Airsonic, Gonic or any Subsonic-compatible server? Add it under More → Backend and search, stream and download from it directly. Your password is stored in the iOS Keychain and never transmitted — Aria uses the salted-token login the Subsonic API is built for.

BUILT FOR LISTENING
• Gapless queue with hold-to-add
• Download for offline, with quality badges
• Playlists, smart playlists, and M3U import/export
• Lock-screen and Control Centre controls
• Sleep timer, playback speed, resume where you left off
• Ask Your Library — describe what you feel like hearing, in your own words

ARIA PRO
A single one-time purchase unlocks the parametric EQ and AutoEQ catalogue, smart playlists, and folder and M3U import. No subscription. Everything else is free forever.

OPEN SOURCE
Aria's source is public. If you'd rather build it yourself, you can.
```

**Keywords** (100 max, comma-separated, no spaces — 98 used)
```
flac,music player,equalizer,autoeq,navidrome,subsonic,hi-res,lossless,offline,self-hosted,playlist
```

**What's New in This Version**
```
First release.
```

## In-App Purchase (App Store Connect → In-App Purchases)

| Field | Value |
|---|---|
| Type | Non-Consumable |
| Reference name | Aria Pro |
| Product ID | **decide with the bundle ID** — `Aria.storekit` and `Managers/ProStore.swift:25` currently say `com.chaitea321.aria.pro`; product IDs are permanent once created, so set it to `<your bundle id>.pro` and change both files before creating it |
| Price | Tier for $9.99 (matches `Aria.storekit`) |
| Display name (30 max) | `Aria Pro` |
| Description (45 max) | `Parametric EQ, AutoEQ, smart playlists` |
| Review screenshot | the paywall sheet (More → Aria Pro) |

Opt into the **App Store Small Business Program** (Agreements, Tax, and Banking →
Small Business Program) before the first sale — 15% commission instead of 30%.
