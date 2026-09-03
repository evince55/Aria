# DECISION NEEDED: ATS vs http:// BYO backends

**Date:** 2026-07-31 · **Status:** open — QA finding from the Ask Your Library pass
(deliberately NOT fixed in the QA-fixes PR; the plist is untouched)

## The constraint

The committed Debug plist (`Aria---Music-Browser-Info.plist`) sets **both**
`NSAllowsArbitraryLoads = true` **and** narrower ATS keys
(`NSAllowsLocalNetworking = true`, `NSExceptionDomains` for `192.0.2.1` and
`googlevideo.com`). Since iOS 10, **when any narrower key is present, iOS ignores
`NSAllowsArbitraryLoads` entirely** — the "allow everything" switch is dead code the
moment a more specific key sits beside it. The Release plist has no
`NSAllowsArbitraryLoads` at all (local networking + the `googlevideo.com` exception
only), so it has the same effective posture.

Net effect: any BYO user who types an `http://` URL into the in-app backend override
(More → Backend) gets **every request blocked** with `NSURLError -1022`
(`AppTransportSecurityRequiresSecureConnection`) unless the host happens to be
local-network or an exception domain.

## QA evidence

- In-app override set to an `http://` public-hostname URL → health probe, sync, and
  query all fail with -1022.
- The failure is **silent**: `probeHealth()` swallows errors by design (background
  probe), so the Library scope simply never appears and the user gets no signal that
  the URL scheme is the reason. Silent is the worst outcome here.
- The owner's own Debug topology (Tailscale `100.x` address over plain http) only
  works because that literal IP is an exception domain after the local plist swap.

## Options for the BYO SKU

### A — `NSAllowsArbitraryLoads = true` and nothing narrower
Remove the narrower keys so the global switch actually applies. Any `http://` URL
works. **Costs:** App Store review requires a written justification for arbitrary
loads and increasingly pushes back; it also disables ATS for *every* connection
(including YouTube/streaming traffic), not just the user's own server. A blunt
instrument to fix a config-entry edge.

### B — Require HTTPS for BYO servers (recommended)
Keep the Release ATS posture as-is. Enforce/communicate "BYO servers must be
`https://`" with first-class error copy at the URL field and at the health-probe
failure path ("`http://` addresses are blocked by iOS — use https, see setup docs"),
plus docs pointing at the standard self-hosting answers: reverse proxy with a real
cert (Caddy/nginx + Let's Encrypt), Cloudflare Tunnel, or Tailscale's built-in certs
(`tailscale cert` / `tailscale serve`). This matches the reality of the Jellyfin /
Symfonium ecosystem the SKU is positioned against — self-hosters already run HTTPS
frontends, and every competing client pushes them there. **Tradeoff:** the owner's
own Tailscale-plain-http Debug case stops being representative; the owner already
runs an HTTPS tunnel endpoint for Release, and Debug device builds keep working via
the local plist swap (exception domain). `tailscale serve` closes the gap for any
user in the same topology.

### C — Rely on properly scoped `NSAllowsLocalNetworking`
Keep https-only for public hosts but let plain http work for genuinely local
servers. On modern iOS, ATS treats **`.local` hostnames, unresolvable single-label
hosts, and RFC 1918 private addresses** as local networking (behavior for literal
private IPs was inconsistent before iOS 10/11 — verify on a current device before
promising it in copy). **Hard limit:** Tailscale addresses are CGNAT
(`100.64.0.0/10`), *not* RFC 1918 — `NSAllowsLocalNetworking` does **not** cover
them, so this option does not help the owner's own topology nor any Tailscale-using
customer. C is really a footnote to B ("http works only for LAN addresses"), not a
standalone answer.

## Recommendation

**B**, with C's local-network allowance kept as the already-present
`NSAllowsLocalNetworking = true` (nice for `http://nas.local:8096`-style LAN setups,
accurately documented). Non-negotiable regardless of choice: **the app must say why
an `http://` URL fails.** Today it fails silently — copy at the URL field / Test
Connection / Library gate must name the ATS block and link the HTTPS setup docs.

**Follow-up (out of scope for the QA-fixes PR, tracked here):** the health-probe
failure path shows nothing in the UI today; error copy for probe failures (including
the -1022 case) needs its own owner-reviewed copy pass — gate/paywall copy has
shipped broken with green tests before.

**Decision: owner**
