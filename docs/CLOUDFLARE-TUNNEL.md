# Cloudflare Tunnel — public HTTPS backend on the homelab

This is the recommended way to give Aria a public, TLS-terminated backend URL
(`https://api.<your-domain>`) **without** moving yt-dlp off the homelab.

**Why a tunnel and not cloud hosting.** yt-dlp runs against YouTube, which
aggressively rate-limits/blocks **datacenter IPs** (the "Sign in to confirm
you're not a bot" wall). The homelab's **residential IP is an asset** — moving
the resolver to a cloud/free host tends to make playback worse. A Cloudflare
Tunnel keeps yt-dlp exactly where it is and only adds a public HTTPS front door:

```
Phone ──HTTPS──▶ api.<domain> ──▶ Cloudflare edge ──tunnel(outbound)──▶ cloudflared ──▶ localhost:8000
   (TLS, free cert)        (WAF / rate-limit)      (no open ports)     (on the laptop)   (FastAPI + yt-dlp)
```

Tailscale keeps working for local dev in parallel; the tunnel is additive.
This does **not** speed up playback — audio streams directly from Google's CDN
to the phone; the backend is only in the `/api/resolve` path. It's about
reachability + HTTPS (needed for TestFlight/App Store Release builds).

> Substitute your real domain for `chai-homelab.com` / `api.chai-homelab.com`
> throughout. The laptop user is `eugene`; the backend service is `aria-backend`.

---

## Phase 0 — Prerequisites (2 min)

- `chai-homelab.com` is an **active zone** in your Cloudflare account (it is, if
  you registered it there). The tunnel needs the domain's nameservers on
  Cloudflare — Free plan is fine.
- The backend already listens on `0.0.0.0:8000` via the `aria-backend` systemd
  unit. No change needed; `cloudflared` will reach it at `localhost:8000`.

## Phase 1 — Stand up the tunnel (~15 min, on the laptop + dashboard)

1. **Create the tunnel.** Cloudflare **Zero Trust** dashboard
   (`one.dash.cloudflare.com`) → **Networks → Tunnels → Create a tunnel →
   Cloudflared**. Name it `aria-homelab`.
2. **Install the connector.** Copy the install command it shows (it embeds a
   one-time token) and run it on the laptop as `eugene`. This installs
   `cloudflared` **and** registers it as its own `cloudflared.service`, so it
   auto-starts on reboot alongside `aria-backend`. Confirm:
   ```bash
   systemctl status cloudflared
   ```
3. **Publish the hostname.** In the tunnel's **Public Hostname** tab, add:
   - **Subdomain** `api`, **Domain** `chai-homelab.com`
   - **Service:** `HTTP` → `localhost:8000`   ← must be `localhost` (see note)
   Cloudflare auto-creates the `api.chai-homelab.com` DNS record + TLS cert.
4. **Smoke test** from anywhere (phone off Wi-Fi, laptop, etc.):
   ```bash
   curl https://api.chai-homelab.com/api/health
   ```
   Expect the health JSON with the yt-dlp version.

> **Why `localhost:8000` specifically:** the backend derives the real client IP
> from Cloudflare's `CF-Connecting-IP` header, but only trusts it when the
> request's socket peer is **loopback** — i.e. it came in through the local
> `cloudflared`. Pointing the tunnel at the Tailscale IP or `0.0.0.0` instead
> would break per-client rate limiting (all traffic would look like one IP).

## Phase 2 — Lock down the now-public backend ⚠️

Going from Tailscale-private to the open internet means an unprotected yt-dlp
resolver would get abused — strangers burning your residential IP's reputation.
So, three things:

1. **Require an API key.** Generate one and add it to the `aria-backend` unit:
   ```bash
   openssl rand -hex 32          # copy the output
   sudo systemctl edit aria-backend    # add under [Service]:
   #   Environment=ARIA_API_KEY=<the-key>
   sudo systemctl daemon-reload && sudo systemctl restart aria-backend
   ```
   Every mutating/expensive endpoint (`/api/play`, `/api/resolve`, `/api/search`,
   `/api/radio`) then requires `X-API-Key`. You do **not** need
   `TRUSTED_PROXY_COUNT` — the `CF-Connecting-IP` handling replaces it for the
   tunnel path.
2. **Deploy the updated `app.py`.** This runbook ships with the `CF-Connecting-IP`
   support; deploy it so rate limiting keys on real clients:
   ```bash
   scp Aria_Music_Browser/backend/app.py eugene@100.76.103.1:~/MusicAppIOS/backend/app.py
   ssh eugene@100.76.103.1 "sudo systemctl restart aria-backend"
   ```
3. **Add an edge rate-limit rule** (recommended). Cloudflare dashboard →
   **Security → WAF → Rate limiting rules** on `api.chai-homelab.com`, e.g.
   100 requests / minute per IP → Block. The origin's own per-IP limiter is a
   second layer behind it.

   *Optional stronger tier:* a **Cloudflare Access** service token if you ever
   want an edge credential on top of the API key. Overkill for personal use.

## Phase 3 — Point the app at the tunnel

Thanks to `BackendConfig`, this is config, not code:

- **Release/TestFlight builds:** set `ARIA_BACKEND_URL` =
  `https://api.chai-homelab.com` in `Aria---Music-Browser-Info-Release.plist`
  so store builds ship pointing at the tunnel over real HTTPS (no ATS exception
  needed — the whole point of the hardened Release plist).
- **Debug/daily dev:** leave it on Tailscale (`ARIA_HOMELAB_HOST`) — faster on
  the home network — or override in-app.
- **API key:** enter it in the app at **Settings → Backend → API key** (kept in
  `UserDefaults`, out of the repo). For TestFlight you can instead bake it into
  the Release plist `ARIA_API_KEY`, accepting that a bundled key is extractable.

## Phase 4 — Verify end to end

1. **Settings → Backend** → URL `https://api.chai-homelab.com` + the API key →
   **Test Connection** shows the yt-dlp version.
2. **Turn Tailscale OFF and use cellular**, then search + play — proves the
   public path works independently of your tailnet.
3. Build a **Release/TestFlight** build → confirms HTTPS with no ATS bypass.

## Ops notes

- `cloudflared.service` auto-starts on boot; `sudo systemctl restart cloudflared`
  to bounce it. Update with your package manager (`cloudflared update` or apt).
- Point an uptime monitor at `https://api.chai-homelab.com/api/health`.
- The tunnel is the **only** public ingress — the origin has no public IP — so
  the API key + edge rate limit are the whole attack surface.
