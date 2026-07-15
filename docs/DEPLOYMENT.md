# Deploying Aria

Two supported avenues: **personal use on your own devices** (what the project is
built around today) and **App Store distribution** (possible, with real caveats
documented honestly below). Backend operations are covered at the end — both
avenues need a reachable backend for streaming, and the app degrades to a
local-files-only player without one.

---

## Avenue A — Personal use (your own iPhone/iPad)

### A1. Direct install from Xcode (what you do today)

1. Open `Aria.xcodeproj` in Xcode, scheme **"Aria - Music Browser"**.
2. Signing: the project uses **Automatic** signing with team `UMMQB88PD3`.
   - **Free Apple ID**: works, but apps re-sign every **7 days** and you're
     limited to 3 sideloaded apps. Fine for kicking the tires, annoying for a
     daily-driver music app.
   - **Paid Developer Program ($99/yr)**: 1-year provisioning, no re-sign
     dance, and unlocks TestFlight (A2). Worth it if Aria is your daily player.
3. Point the app at your homelab backend (Debug builds):
   - Set your real Tailscale IP in `Aria---Music-Browser-Info.plist` →
     `ARIA_HOMELAB_HOST`, then keep it out of git:
     `git update-index --assume-unchanged Aria---Music-Browser-Info.plist`
   - Or use the build-setting override — see README §"Building for your device".
   - If the backend enforces auth, put the key in `ARIA_API_KEY` (same
     assume-unchanged flow) and set `ARIA_API_KEY` in the backend env.
4. The phone must be on the **Tailscale mesh** (Tailscale app installed and
   connected) to reach the homelab over `http://<tailscale-ip>:8000`.
5. Build & run to your device. Background audio, lock-screen controls, EQ, and
   the local library all work without any server; search/streaming need one.

> The `feat/configurable-backend-url` branch (PR pending) adds an in-app
> **Settings → Backend** server-URL + API-key override, which replaces the
> plist-editing dance entirely for device installs.

### A2. TestFlight internal (paid account, the low-friction option)

Once on the paid program: archive (Product → Archive), upload to App Store
Connect, add yourself (and up to 100 internal testers) in TestFlight. Builds
last 90 days, install/update over the air, no cable.
**Important:** TestFlight builds are **Release** builds — they use the hardened
`Aria---Music-Browser-Info-Release.plist`, which has **no ATS bypass for plain
HTTP**. Your homelab-over-Tailscale URL (`http://100.x.y.z:8000`) will be
blocked by ATS in these builds. Either front the backend with HTTPS (see
Backend ops below) and set `ARIA_BACKEND_URL` in the Release plist, or stick
with Avenue A1 (Debug builds) for pure-homelab use.

### A3. What Release hardening changed (this branch)

| | Debug plist (`Aria---Music-Browser-Info.plist`) | Release plist (`…-Info-Release.plist`) |
|---|---|---|
| `NSAllowsArbitraryLoads` | `true` (dev convenience: HTTP-by-IP homelab) | **removed** |
| Homelab IP ATS exception (TLSv1.0) | present | **removed** |
| `googlevideo.com` HTTP exception | present | present (scoped, justified) |
| `NSAllowsLocalNetworking` | `true` | `true` |
| `ITSAppUsesNonExemptEncryption` | `false` | `false` |
| `ARIA_BACKEND_URL` | empty (override hook) | empty (**set for TestFlight/App Store**) |

`Resources/PrivacyInfo.xcprivacy` (privacy manifest) ships in **both**
configurations.

---

## Avenue B — App Store

### B1. One-time prerequisites

1. **Apple Developer Program** membership ($99/yr).
2. **Change the bundle identifier.** `PRODUCT_BUNDLE_IDENTIFIER` is still the
   `XCDevelopment.Aria-Music-Browser` placeholder. Pick a reverse-DNS ID you
   control (e.g. `com.<yourname>.aria`), set it for the app + tests targets,
   and register the App ID in App Store Connect.
   *Deliberately not changed in this repo*: changing it re-identifies the app,
   so existing device installs (and their imported libraries/settings) are
   abandoned — do it once, when you actually go to the store.
3. **An HTTPS backend.** Release builds have no ATS bypass. Options:
   - Revive the Render deployment (`backend/` deploys as-is; free tier works
     with cold starts), or
   - Put the homelab behind a TLS reverse proxy (Caddy/Traefik with a real
     cert, or Tailscale Funnel for a public HTTPS URL).
   Set the URL in `ARIA_BACKEND_URL` of the **Release** plist — or ship with it
   empty and let users enter their own server in-app (see B3).
4. **Set `ARIA_API_KEY` on any public backend.** Backend auth is opt-in and
   default-off; a public unauthenticated deployment is a wide-open yt-dlp
   proxy that strangers can (and will) use. Set the env var server-side and
   the same key client-side.

### B2. Submission checklist

- [ ] Bundle ID changed + App ID registered (B1.2)
- [ ] `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bumped as needed
- [ ] Archive uses Release config (hardened plist — verify no
      `NSAllowsArbitraryLoads` in the built product's Info.plist)
- [ ] Privacy manifest present in bundle (`PrivacyInfo.xcprivacy`) — App Store
      Connect **App Privacy** answers must match it: *Search History* and
      *Product Interaction*, purpose **App Functionality**, **not** linked to
      identity, **no** tracking
- [ ] Export compliance: pre-answered by `ITSAppUsesNonExemptEncryption=false`
- [ ] App icon set complete (it is), screenshots for 6.9" and 6.5" iPhone (+
      13" iPad since the app supports iPad), description, keywords, age rating
- [ ] Privacy policy URL (required because the app transmits search text to a
      server — a one-pager stating queries go to *your own configured server*
      and nothing is collected by the developer suffices)
- [ ] Review notes: explain the self-hosted-server model (B3), state that the
      app is fully functional as a local-file player without a server, and do
      **not** ship or link a demo YouTube-proxy server

### B3. The honest review-risk assessment

The YouTube-streaming half of Aria works by having a **user-operated backend**
resolve audio via yt-dlp. Apple's **Guideline 5.2.3** (apps that facilitate
downloading/streaming from third-party sources without authorization) is the
real rejection risk, and no plist key makes it go away.

The defensible positioning — and how the app is actually built:

- Aria is a **client for the user's own self-hosted media server** (the same
  model as Plex/Jellyfin/Navidrome clients, which are on the store).
- The App Store build ships with **no bundled server URL** (`ARIA_BACKEND_URL`
  empty): out of the box it is a complete local-file player (import, library,
  playlists, EQ, background audio). Users who run their own server enter its
  URL themselves.
- The developer does not operate, promote, or link a YouTube-proxy service.

This is a good-faith position, not a guarantee: a reviewer who probes what the
companion server does may still reject under 5.2.3, and resubmission/appeal is
part of the game. If store distribution matters more than the streaming
feature, the fallback is to submit the local-player experience alone.

**Middle path:** Apple's **Unlisted App Distribution** (app is on the store but
only reachable via direct link, no search listing) fits "me and a few friends"
distribution without the public-review spotlight; request it via Apple's form
after a normal review pass. TestFlight (A2) remains the zero-drama option.

---

## Backend ops (both avenues)

- Runbook: [`backend/README.md`](../backend/README.md) — deploy is
  `scp backend/app.py` to the host + `systemctl restart aria-backend`.
- **Auth:** set `ARIA_API_KEY` in the backend env; clients send it as
  `X-API-Key` (plist or in-app setting). Without it, all endpoints —
  including `DELETE /api/cache` — are anonymous.
- **HTTPS for Release/TestFlight builds:** Tailscale Funnel is the least-moving-
  parts option (`tailscale funnel 8000` → public `https://<node>.ts.net` URL);
  a Caddy reverse proxy with Let's Encrypt is the self-managed one.
- yt-dlp keeps itself current via `update-yt-dlp.sh` + the systemd timer;
  `/api/health` reports the running version, node status, and error rate —
  point an uptime monitor at it.
