# Notes for App Review

Paste verbatim into App Store Connect → App Review Information → Notes.

```
Aria is a music player for the user's own files and their own self-hosted music server — the same model as Plex, Jellyfin, and Navidrome clients.

WITHOUT A SERVER
The app is complete on its own. Import any audio file from the Files app (Library tab → Import), and everything except the Search tab works: playback, EQ, playlists, downloads, lock-screen controls. The Search tab appears only once a server is configured.

TESTING THE SERVER FEATURES
We do not operate any server. To exercise the server path, use the public demo of Navidrome, an open-source music server maintained by the Navidrome project:

  More → Backend → Server Type: Subsonic
  Server URL: https://demo.navidrome.org
  Username: demo
  Password: demo
  Tap "Test Connection", then use the Search tab.

This is a third-party public demo populated with Creative Commons music. Aria connects to it over the standard Subsonic API, the same way it would connect to a server the user runs at home.

IN-APP PURCHASE
"Aria Pro" is a single non-consumable unlock (parametric EQ + AutoEQ, smart playlists, folder/M3U import). It can be tested with a sandbox tester account from More → Aria Pro. Restore Purchases is on the same sheet.

PRIVACY
There are no accounts, no analytics, and no data sent to the developer. Search text and library metadata are sent only to the server the user themselves configured. The Subsonic password is stored in the iOS Keychain and is never transmitted (salted-token authentication).

OPEN SOURCE
Source: https://github.com/evince55/Aria
```

## Why it says what it says

- **"We do not operate any server"** is the load-bearing sentence for Guideline
  5.2.3 (see `docs/DEPLOYMENT.md` §B3). Everything the reviewer can reach is either
  on-device or a third party's public demo.
- **The Navidrome demo** exists precisely so Subsonic clients can be tested. It is
  not ours, it is not a YouTube proxy, and its music is CC-licensed. Do not
  substitute the owner's homelab or the Cloudflare tunnel — that would put a
  residential IP in front of Apple and contradict the BYO story.
- **Nothing here mentions the `backend/` directory** or yt-dlp. The store build
  ships no URL for it; a user who deploys it is operating their own server.
