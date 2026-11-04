# Free, no gates

Owner decision, 2026-11-03: Aria is entirely free. Every feature is available to everyone, there
is nothing to buy, a server stays optional and bring-your-own, and the app must work with no server
for offline high-fidelity playback.

## Change

Delete the purchase layer rather than hide it behind an always-unlocked switch. Nobody has bought
Pro, because the app was never on the store, so no customers are affected. Git history keeps the
code if purchases ever return.

- **Removed:** `ProStore`, `AriaProView`, `ProStoreTests`, `Aria.storekit` and its scheme reference,
  and the More tab's Aria Pro row.
- **Now free:** parametric EQ and AutoEQ, smart playlists, folder import, M3U import and export.
- **Docs:** README and `docs/store/` drop the purchase wording. The submission checklist loses the
  paid-apps agreement, banking and in-app purchase steps.

## Unchanged

- Both plists keep an empty `ARIA_BACKEND_URL`, so a new install is a local player with no Search tab.
- Subsonic and the yt-dlp backend stay optional under More → Backend.
- No music is bundled. A new install opens on an empty library with Import.
- A leftover `aria_pro_unlocked` default on an existing install is harmless and is ignored.

## Verification

- The full `AriaTests` suite passes.
- No reference to `ProStore`, StoreKit or a paywall remains outside historical docs.
- On a fresh simulator install with no server: import a lossless file, play it, then use each freed
  feature.
