# Submission checklist — owner steps

Everything below needs the owner's Apple ID or judgement. Each
step unblocks the ones after it. Agent-side work (PRs, screenshots, copy) is
done and referenced where it plugs in.

1. **Merge the queue.** #65, #66, #67, #68, #69, then this PR. #66 before #68
   (the last two "videos" strings live in #66).
2. **Enroll in the Apple Developer Program** ($99/yr) as an **individual** — no
   D-U-N-S number needed. Approval is usually 24–48 h; identity verification can
   add days. Nothing below works until this is done.
3. **Check the name.** App Store Connect → My Apps → + → the Name field errors
   immediately if `Aria: Hi-Fi Music Player` is taken. Fallback in `listing.md`.
4. **Decide the bundle identifier** — `com.<you>.aria`, lowercase, permanent.
   Then in one change: set `PRODUCT_BUNDLE_IDENTIFIER` for the app and tests
   targets in `Aria.xcodeproj/project.pbxproj`.
   ⚠ Changing the bundle ID re-identifies the app: your existing install and
   its library, playlists and settings are abandoned. Back up first.
5. **Create the App ID** (Certificates, Identifiers & Profiles) with that bundle ID.
6. **Deploy the two web pages** to chai-homelab.com at `/aria/privacy` and
   `/aria/support` (`docs/store/web/`), and create the `aria@chai-homelab.com`
   alias in Cloudflare Email Routing — both pages link to it.
7. **Create the app record** in App Store Connect and paste `listing.md`.
8. **App Privacy** — answer exactly as `app-privacy.md`. Upload fails if it
   disagrees with the manifest.
9. **Age rating** — all "No" → 4+.
10. **Screenshots** — upload `docs/store/screenshots/6.9/*.png` (from the
    screenshots PR) to the iPhone 6.9" slot. With v1 iPhone-only, that is the
    only required set.
11. **Archive.** Xcode → Product → Archive with the Release configuration. Before
    uploading, run `scripts/verify-release.sh` from the same checkout — it must
    exit 0 **without** `ALLOW_DEV_BUNDLE_ID`.
12. **Upload** via Organizer → Distribute App → App Store Connect. Export
    compliance is pre-answered by the plist; no dialog should appear.
13. **Review notes** — paste `review-notes.md` verbatim, then **Submit for Review**.

If rejected under 5.2.3, `docs/DEPLOYMENT.md` §B3 has the appeal position and the
Unlisted-distribution fallback.
