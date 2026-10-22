# App Store Launch Prep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take Aria from "four green PRs waiting on device test" to "everything the owner needs to submit to the App Store, minus the steps only the owner can perform (enrollment, bundle ID, IAP paperwork, pressing Submit)."

**Architecture:** Two PRs plus one gated follow-up. PR A is code: ship iPhone-only, land new users on the Library tab, make the Release build provably clean via a repeatable script. PR B is docs: everything App Store Connect will ask for, written once and versioned in `docs/store/`. The follow-up shoots screenshots after PRs #66/#68 merge, because both change visible copy.

**Tech Stack:** Swift 5 / SwiftUI, iOS 16.6 floor, zero third-party deps, `xcodebuild` + `plutil` + `simctl` for verification. Static HTML for the two web pages (deployed by the owner to chai-homelab.com behind Cloudflare).

## Global Constraints

- iOS 16.6 deployment target, Swift 5, **no** `@Observable`, **no** SPM/CocoaPods — `ObservableObject` / `@Published` only.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` project-wide; don't add `@MainActor` to types that already get it.
- Managers are injected via `.environmentObject`, never `init`.
- The committed `Aria---Music-Browser-Info.plist` carries the placeholder host `192.0.2.1`. The real Tailscale IP lives only in a local worktree under `git update-index --assume-unchanged`. **Never stage the real IP.** The Stop hook blocks it; the leak check in each commit step is belt-and-braces.
- Store SKU is **BYO server**: `ARIA_BACKEND_URL` in the Release plist stays **empty**. Do not point a public build at the owner's homelab or the Cloudflare tunnel.
- CarPlay is **out of scope** for v1 (owner decision 2026-08-16).
- User-facing copy must not name YouTube (PRs #66/#68 already do this for in-app strings; this plan must not reintroduce it in store copy).
- Each PR branches from `origin/main`, gets its own worktree under `.worktrees/`, and is device-tested by the owner before merge. `main` stays clean.
- Green tests are not completion for UI work — every visible change is driven in the simulator before the PR is opened.
- Run all `git` from inside `Aria_Music_Browser/` (the workspace root is not a repo). `gh` only works via `zsh -lc 'gh …'`.

---

## File Structure

**PR A — `feat/store-readiness`**
- Modify: `Aria.xcodeproj/project.pbxproj` — `TARGETED_DEVICE_FAMILY` on 4 lines (257, 283, 439, 475)
- Modify: `Managers/SettingsManager.swift:4-9,33` — add `.library` to `DefaultStartTab`, make it the default
- Modify: `App/AriaApp.swift:91-98` — map `.library`
- Modify: `Views/Root/ContentView.swift:117-124` — map `.library`
- Modify: `Views/Library/LibraryView.swift:278-283` — empty-state copy mentions the server option
- Modify: `Aria---Music-Browser-Info-Release.plist` — remove the `googlevideo.com` ATS exception
- Create: `scripts/verify-release.sh` — builds Release and asserts on the *built product's* Info.plist
- Create: `Tests/DefaultStartTabTests.swift`
- Modify: `docs/DEPLOYMENT.md` — B2 checklist gains the script and the demo-server review note

**PR B — `docs/store-listing`**
- Create: `docs/store/README.md` — what each file is for
- Create: `docs/store/listing.md` — every App Store Connect text field, ready to paste
- Create: `docs/store/review-notes.md` — the "Notes for Review" field, verbatim
- Create: `docs/store/app-privacy.md` — the App Privacy questionnaire answers, derived from `Resources/PrivacyInfo.xcprivacy`
- Create: `docs/store/submission-checklist.md` — owner-only steps, in dependency order
- Create: `docs/store/web/privacy-policy.html`
- Create: `docs/store/web/support.html`

**Follow-up — `docs/store-screenshots`** (after #66 and #68 merge)
- Create: `docs/store/screenshots/6.9/01-library.png` … `05-search.png`

---

## PR A — Store readiness

### Task 1: Worktree + iPhone-only device family

Apple requires a 13" iPad screenshot set for any app that declares iPad support, reviewers test on iPad, and Aria has zero iPad-specific layout (no `horizontalSizeClass` or `userInterfaceIdiom` anywhere in `Views/`). Shipping v1 iPhone-only removes an untested surface and a whole screenshot set.

**Files:**
- Modify: `Aria.xcodeproj/project.pbxproj:257,283,439,475`

**Interfaces:**
- Produces: a built product whose `Info.plist` has `UIDeviceFamily = [1]` — asserted by Task 4's script.

- [ ] **Step 1: Create the worktree off main**

```bash
cd /Users/chait/MusicAppIOS/Aria_Music_Browser
git fetch origin -q
git worktree add .worktrees/store-readiness -b feat/store-readiness origin/main
cd .worktrees/store-readiness
# Local device-test IP (never committed — the Stop hook and step 5's grep both guard it)
sed -i '' 's/192\.0\.2\.1/100.76.103.1/g' Aria---Music-Browser-Info.plist
git update-index --assume-unchanged Aria---Music-Browser-Info.plist
git ls-files -v Aria---Music-Browser-Info.plist   # expect: h Aria---Music-Browser-Info.plist
```

- [ ] **Step 2: Confirm the four lines before touching them**

Run: `grep -n 'TARGETED_DEVICE_FAMILY' Aria.xcodeproj/project.pbxproj`
Expected: exactly four lines, all `TARGETED_DEVICE_FAMILY = "1,2";` (app Debug/Release, tests Debug/Release).

- [ ] **Step 3: Change all four to iPhone-only**

```bash
sed -i '' 's/TARGETED_DEVICE_FAMILY = "1,2";/TARGETED_DEVICE_FAMILY = 1;/' Aria.xcodeproj/project.pbxproj
grep -n 'TARGETED_DEVICE_FAMILY' Aria.xcodeproj/project.pbxproj
```
Expected: four lines, all `TARGETED_DEVICE_FAMILY = 1;`

- [ ] **Step 4: Build for the simulator and check the built plist**

```bash
xcodebuild build -scheme "Aria - Music Browser" -project Aria.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E 'BUILD SUCCEEDED|BUILD FAILED|error:'
plutil -extract UIDeviceFamily json -o - \
  "build/Build/Products/Debug-iphonesimulator/Aria - Music Browser.app/Info.plist"
```
Expected: `** BUILD SUCCEEDED **` then `[1]`

- [ ] **Step 5: Commit**

```bash
git add Aria.xcodeproj/project.pbxproj
git diff --cached | grep -q '100\.76\.103\.1' && { echo 'REAL IP STAGED — abort'; exit 1; }
git commit -m "Ship v1 iPhone-only

The project declared iPad support (TARGETED_DEVICE_FAMILY = 1,2) but has
no iPad layout at all — no size-class or idiom handling anywhere in
Views/ — so on a 13\" iPad it is the phone UI stretched across the
canvas. Declaring it costs a required 13\" screenshot set and puts an
untested surface in front of a reviewer whose 5.2.3 scrutiny is already
the risk. iPad can return as a feature update once it has a layout.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Library is the default start tab

`DefaultStartTab` has no `.library` case and defaults to `.favorites`. A first-run user therefore lands on "No Favorites Yet — tap the heart on any song" with zero songs and no path forward. The Library tab already has an empty state with an **Import** button; new users should land there.

**Files:**
- Modify: `Managers/SettingsManager.swift:4-9` (enum) and `:33` (default)
- Modify: `App/AriaApp.swift:91-98`
- Modify: `Views/Root/ContentView.swift:117-124`
- Test: `Tests/DefaultStartTabTests.swift` (new)

**Interfaces:**
- Produces: `DefaultStartTab.library` with `rawValue == "Library"`; `SettingsManager().defaultStartTab == .library` when nothing is persisted. The More → "Default Start Page" picker iterates `DefaultStartTab.allCases` and will show "Library" with no further change.

- [ ] **Step 1: Write the failing test**

```bash
cat > Tests/DefaultStartTabTests.swift <<'EOF'
import XCTest
@testable import Aria___Music_Browser

/// A brand-new install must land somewhere useful. Favorites is empty on
/// first run by definition; Library has the Import call-to-action.
final class DefaultStartTabTests: XCTestCase {
    private let key = "default_start_tab"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func test_libraryIsAnOption_andPersistsByRawValue() {
        XCTAssertEqual(DefaultStartTab(rawValue: "Library"), .library)
        XCTAssertTrue(DefaultStartTab.allCases.contains(.library),
                      "the More → Default Start Page picker iterates allCases")
    }

    func test_freshInstall_defaultsToLibrary() {
        XCTAssertEqual(SettingsManager().defaultStartTab, .library)
    }

    func test_persistedChoiceStillWins() {
        UserDefaults.standard.set("Favorites", forKey: key)
        XCTAssertEqual(SettingsManager().defaultStartTab, .favorites,
                       "changing the default must not override a user's saved choice")
    }
}
EOF
```

- [ ] **Step 2: Run it and confirm it fails to compile**

```bash
xcodebuild test -scheme AriaTests -project Aria.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  -only-testing:AriaTests/DefaultStartTabTests 2>&1 | grep -E "error:|BUILD FAILED" | head -3
```
Expected: `error: type 'DefaultStartTab' has no member 'library'` (a compile failure is the failing state here — the enum case does not exist yet).

- [ ] **Step 3: Add the case and make it the default**

```bash
python3 - <<'EOF'
import re
p = 'Managers/SettingsManager.swift'
s = open(p).read()
s = s.replace(
    'enum DefaultStartTab: String, CaseIterable {\n    case favorites = "Favorites"',
    'enum DefaultStartTab: String, CaseIterable {\n    case library = "Library"\n    case favorites = "Favorites"')
s = s.replace(
    '@Published var defaultStartTab: DefaultStartTab = .favorites',
    '/// Library, not Favorites: a first-run user has no favorites and needs\n'
    '    /// the Import button in front of them. A saved choice still wins (`load()`).\n'
    '    @Published var defaultStartTab: DefaultStartTab = .library')
open(p, 'w').write(s)
EOF
grep -n 'case library\|defaultStartTab: DefaultStartTab' Managers/SettingsManager.swift
```
Expected: two hits — `case library = "Library"` and `= .library`.

- [ ] **Step 4: Map the new case in the two exhaustive switches**

The compiler enforces both; without them the build fails with "switch must be exhaustive".

```bash
python3 - <<'EOF'
p = 'App/AriaApp.swift'
s = open(p).read()
s = s.replace('        case .favorites: return .favorites\n        }',
              '        case .favorites: return .favorites\n        case .library:   return .library\n        }')
open(p, 'w').write(s)

p = 'Views/Root/ContentView.swift'
s = open(p).read()
s = s.replace('            case .favorites: selectedTab = .favorites\n            }',
              '            case .favorites: selectedTab = .favorites\n            case .library:   selectedTab = .library\n            }')
open(p, 'w').write(s)
EOF
grep -n 'case .library' App/AriaApp.swift Views/Root/ContentView.swift
```
Expected: one hit in each file.

- [ ] **Step 5: Run the new tests and the whole suite**

```bash
xcodebuild test -scheme AriaTests -project Aria.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED|error:" | tail -3
```
Expected: `Executed 434 tests … 0 failures` (431 on main + 3 new) and `** TEST SUCCEEDED **`.

- [ ] **Step 6: Drive it — fresh install must open on Library**

```bash
UDID=$(xcrun simctl list devices available | grep -m1 'iPhone 17 (' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl uninstall "$UDID" XCDevelopment.Aria-Music-Browser 2>/dev/null   # fresh container
xcodebuild build -scheme "Aria - Music Browser" -project Aria.xcodeproj \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'BUILD SUCCEEDED|BUILD FAILED'
xcrun simctl install "$UDID" "build/Build/Products/Debug-iphonesimulator/Aria - Music Browser.app"
xcrun simctl launch "$UDID" XCDevelopment.Aria-Music-Browser
sleep 3; xcrun simctl io "$UDID" screenshot /tmp/first-run.png && echo "screenshot at /tmp/first-run.png"
```
Then view `/tmp/first-run.png` (the `Read` tool renders PNGs). Expected: the **Library** tab is selected and the empty state reads "No files yet" with an **Import** button. Also open More → Default Start Page and confirm "Library" is listed and selected.

- [ ] **Step 7: Commit**

```bash
git add Managers/SettingsManager.swift App/AriaApp.swift Views/Root/ContentView.swift Tests/DefaultStartTabTests.swift
git diff --cached | grep -q '100\.76\.103\.1' && { echo 'REAL IP STAGED — abort'; exit 1; }
git commit -m "Land new users on Library, not an empty Favorites

DefaultStartTab had no Library case and defaulted to Favorites, so a
first-run user saw \"No Favorites Yet — tap the heart on any song\" with
zero songs and nothing to tap. Library already has the Import
call-to-action; it is the only tab that makes sense with nothing loaded.

A saved preference still wins — load() only falls back to the code
default when the key was never written — so nobody who chose Favorites
is moved.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Library empty state names the server option

The empty state says import files from the Files app. Under the BYO positioning, "or connect your own server" is the second half of the pitch and the reviewer's first screen should say it.

**Files:**
- Modify: `Views/Library/LibraryView.swift:280`

- [ ] **Step 1: Change the copy**

```bash
python3 - <<'EOF'
p = 'Views/Library/LibraryView.swift'
s = open(p).read()
old = 'Text("Import FLAC, MP3, or other audio files from the Files app to play them with EQ.")'
new = 'Text("Import FLAC, MP3, or other audio files from the Files app, or connect your own music server under More → Backend.")'
assert old in s, "empty-state copy moved — find it with: grep -n 'Import FLAC' Views/Library/LibraryView.swift"
open(p, 'w').write(s.replace(old, new))
EOF
grep -n 'connect your own music server' Views/Library/LibraryView.swift
```
Expected: one hit at line ~280.

- [ ] **Step 2: Build, install fresh, screenshot**

Repeat Task 2 Step 6's build/uninstall/install/launch/screenshot block. Expected: the empty state shows the new sentence on at most three lines with no truncation on iPhone 17.

- [ ] **Step 3: Commit**

```bash
git add Views/Library/LibraryView.swift
git diff --cached | grep -q '100\.76\.103\.1' && { echo 'REAL IP STAGED — abort'; exit 1; }
git commit -m "Library empty state mentions the server option

The first screen a new user (or a reviewer) sees should carry both
halves of what Aria is: a local-file player, and a client for your own
server. It said only the first.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Clean Release plist + `scripts/verify-release.sh`

Two things. (1) The Release plist carries `NSExceptionDomains → googlevideo.com`. The store SKU ships no YouTube path by default, yt-dlp-resolved stream URLs are HTTPS anyway, and the key is a fingerprint in the built binary a reviewer can read. (2) Nothing today asserts that an archive is actually clean — DEPLOYMENT.md B2 says "verify no `NSAllowsArbitraryLoads` in the built product" as a manual step. Make it a script that fails loudly, and run it before every submission.

**Files:**
- Modify: `Aria---Music-Browser-Info-Release.plist`
- Create: `scripts/verify-release.sh`
- Modify: `docs/DEPLOYMENT.md` (B2 checklist)

**Interfaces:**
- Produces: `scripts/verify-release.sh` — exit 0 when the Release product passes every gate, exit 1 with the failing gate named. Honors `ALLOW_DEV_BUNDLE_ID=1` so it can run before the owner changes the bundle ID.

- [ ] **Step 1: Confirm what the Release ATS block contains today**

Run: `plutil -extract NSAppTransportSecurity json -o - Aria---Music-Browser-Info-Release.plist`
Expected: `{"NSAllowsLocalNetworking":true,"NSExceptionDomains":{"googlevideo.com":{…}}}`

- [ ] **Step 2: Remove the exception**

```bash
plutil -remove NSAppTransportSecurity.NSExceptionDomains Aria---Music-Browser-Info-Release.plist
plutil -extract NSAppTransportSecurity json -o - Aria---Music-Browser-Info-Release.plist
git diff --stat Aria---Music-Browser-Info-Release.plist
```
Expected: `{"NSAllowsLocalNetworking":true}` and a diff touching only that file. `NSAllowsLocalNetworking` stays — it is what lets a self-hoster reach `http://nas.local`.

- [ ] **Step 3: Write the verification script**

```bash
mkdir -p scripts
cat > scripts/verify-release.sh <<'EOF'
#!/usr/bin/env bash
# Builds Aria with the Release configuration and asserts on the BUILT
# product's Info.plist — not the source plists — so what's checked is what
# would be archived. Run before every App Store submission:
#
#     scripts/verify-release.sh
#
# Exit 0 = every gate passed. Exit 1 = the first failing gate is named.
# ALLOW_DEV_BUNDLE_ID=1 lets it run while the bundle ID is still the
# Xcode-personal-team placeholder; a real submission must not set it.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD=build-verify
APP="$BUILD/Build/Products/Release-iphoneos/Aria - Music Browser.app"
PLIST="$APP/Info.plist"

echo "→ Building Release for generic iOS (unsigned; signing is not what's under test)…"
xcodebuild build -project Aria.xcodeproj -scheme "Aria - Music Browser" \
  -configuration Release -destination "generic/platform=iOS" \
  -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO -quiet
[[ -f "$PLIST" ]] || { echo "✗ built product not found at $APP"; exit 1; }

fail() { echo "✗ $1"; exit 1; }
pass() { echo "✓ $1"; }
get()  { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null || true; }

# 1. No blanket ATS bypass.
if [[ "$(plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw -o - "$PLIST" 2>/dev/null)" == "true" ]]; then
  fail "NSAllowsArbitraryLoads is true — the Debug plist leaked into the Release build"
fi
pass "no NSAllowsArbitraryLoads"

# 2. No per-domain exceptions (the googlevideo.com one was a YouTube fingerprint).
if plutil -extract NSAppTransportSecurity.NSExceptionDomains json -o - "$PLIST" >/dev/null 2>&1; then
  fail "NSExceptionDomains present: $(plutil -extract NSAppTransportSecurity.NSExceptionDomains json -o - "$PLIST")"
fi
pass "no NSExceptionDomains"

# 3. BYO: no bundled server, and no real homelab host.
[[ -z "$(get ARIA_BACKEND_URL)" ]] || fail "ARIA_BACKEND_URL is set to '$(get ARIA_BACKEND_URL)' — the store build must ship with no server"
pass "ARIA_BACKEND_URL empty"
[[ "$(get ARIA_HOMELAB_HOST)" == "192.0.2.1" ]] || fail "ARIA_HOMELAB_HOST is '$(get ARIA_HOMELAB_HOST)', not the placeholder — a real IP would ship to every user"
pass "ARIA_HOMELAB_HOST is the placeholder"
[[ -z "$(get ARIA_API_KEY)" ]] || fail "ARIA_API_KEY is baked into the build"
pass "no ARIA_API_KEY"

# 4. Export compliance pre-answered.
[[ "$(get ITSAppUsesNonExemptEncryption)" == "false" ]] || fail "ITSAppUsesNonExemptEncryption must be false"
pass "ITSAppUsesNonExemptEncryption = false"

# 5. iPhone-only (v1 ships no iPad layout).
[[ "$(plutil -extract UIDeviceFamily json -o - "$PLIST")" == "[1]" ]] || fail "UIDeviceFamily is $(plutil -extract UIDeviceFamily json -o - "$PLIST"), expected [1]"
pass "UIDeviceFamily = [1] (iPhone only)"

# 6. Privacy manifest made it into the bundle.
[[ -f "$APP/PrivacyInfo.xcprivacy" ]] || fail "PrivacyInfo.xcprivacy missing from the bundle"
pass "PrivacyInfo.xcprivacy present"

# 7. Real bundle identifier.
BID="$(get CFBundleIdentifier)"
if [[ "$BID" == XCDevelopment.* ]]; then
  if [[ "${ALLOW_DEV_BUNDLE_ID:-}" == "1" ]]; then
    echo "· bundle id is still '$BID' (allowed by ALLOW_DEV_BUNDLE_ID=1 — NOT submittable)"
  else
    fail "bundle id is '$BID' — change PRODUCT_BUNDLE_IDENTIFIER before submitting (or set ALLOW_DEV_BUNDLE_ID=1 to check everything else)"
  fi
else
  pass "bundle id $BID"
fi

# 8. Version fields exist (App Store Connect rejects an upload without them).
[[ -n "$(get CFBundleShortVersionString)" && -n "$(get CFBundleVersion)" ]] || fail "missing CFBundleShortVersionString / CFBundleVersion"
pass "version $(get CFBundleShortVersionString) ($(get CFBundleVersion))"

echo
echo "Release product is clean."
EOF
chmod +x scripts/verify-release.sh
```

- [ ] **Step 4: Run it — expect a pass with the dev-bundle-id allowance**

```bash
ALLOW_DEV_BUNDLE_ID=1 scripts/verify-release.sh
```
Expected: eight `✓` lines, one `·` line about the bundle id, then `Release product is clean.` Exit code 0.

- [ ] **Step 5: Prove it fails when it should**

```bash
scripts/verify-release.sh; echo "exit=$?"
```
Expected: `✗ bundle id is 'XCDevelopment.Aria-Music-Browser' — change PRODUCT_BUNDLE_IDENTIFIER before submitting …` and `exit=1`. (This is the correct state until the owner changes the bundle ID.)

- [ ] **Step 6: Point DEPLOYMENT.md's checklist at the script and the demo server**

```bash
python3 - <<'EOF'
p = 'docs/DEPLOYMENT.md'
s = open(p).read()
old = "- [ ] Archive uses Release config (hardened plist — verify no\n      `NSAllowsArbitraryLoads` in the built product's Info.plist)"
new = ("- [ ] `scripts/verify-release.sh` exits 0 — builds Release and asserts on the\n"
       "      *built* Info.plist: no ATS bypass or exception domains, empty\n"
       "      `ARIA_BACKEND_URL`, placeholder homelab host, no API key, export\n"
       "      compliance answered, iPhone-only, privacy manifest bundled, real\n"
       "      bundle ID, version fields present")
assert old in s, "B2 archive line changed — update this step"
s = s.replace(old, new)
old2 = ("- [ ] Review notes: explain the self-hosted-server model (B3), state that the\n"
        "      app is fully functional as a local-file player without a server, and do\n"
        "      **not** ship or link a demo YouTube-proxy server")
new2 = ("- [ ] Review notes (`docs/store/review-notes.md`): explain the self-hosted-server\n"
        "      model (B3), state that the app is fully functional as a local-file player\n"
        "      without a server, and point the reviewer at the **public Navidrome demo**\n"
        "      (`https://demo.navidrome.org`, user `demo`, password `demo`) so the\n"
        "      Subsonic path can be exercised — it's a third-party demo of an open-source\n"
        "      server, not anything the developer operates. Do **not** ship or link a\n"
        "      YouTube-proxy server")
assert old2 in s, "B2 review-notes line changed — update this step"
s = s.replace(old2, new2)
open(p, 'w').write(s)
EOF
grep -n 'verify-release.sh\|demo.navidrome.org' docs/DEPLOYMENT.md
```
Expected: one hit for each.

- [ ] **Step 7: Full suite still green, then commit**

```bash
xcodebuild test -scheme AriaTests -project Aria.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "Executed [0-9]+ tests, with|TEST SUCCEEDED|TEST FAILED" | tail -2
git add Aria---Music-Browser-Info-Release.plist scripts/verify-release.sh docs/DEPLOYMENT.md
git diff --cached | grep -q '100\.76\.103\.1' && { echo 'REAL IP STAGED — abort'; exit 1; }
git commit -m "Make the Release build provably clean

scripts/verify-release.sh builds Release and asserts on the BUILT
product's Info.plist rather than the source plists, so what's checked is
what would be archived: no ATS bypass, no exception domains, no bundled
server URL, placeholder homelab host, no API key, export compliance
answered, iPhone-only, privacy manifest in the bundle, a real bundle
identifier, and version fields. DEPLOYMENT.md B2 said to check the first
of those by hand; nothing checked the rest.

Drops the googlevideo.com ATS exception from the Release plist. The
store SKU ships no YouTube path by default, yt-dlp-resolved stream URLs
are HTTPS regardless, and an exception domain is a fingerprint a
reviewer can read straight out of the binary.

B2's review-notes line now points at the public Navidrome demo so a
reviewer can exercise the Subsonic path against a server nobody here
operates.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Open PR A

- [ ] **Step 1: Push and open**

```bash
git push -u origin feat/store-readiness
cat > /tmp/prA.md <<'EOF'
Everything in the *app* that has to change before an App Store submission, minus the steps only the owner can do (enrollment, bundle ID, IAP paperwork). Companion to the docs PR that follows.

## What changed

- **iPhone-only.** The project declared iPad support with no iPad layout at all. Declaring it costs a required 13" screenshot set and puts an untested, stretched UI in front of a reviewer. `TARGETED_DEVICE_FAMILY = 1`.
- **New users land on Library.** `DefaultStartTab` had no Library case and defaulted to Favorites, so first run was "No Favorites Yet — tap the heart on any song" with zero songs. Library has the Import button. A saved preference still wins.
- **Library empty state names the server option** — the first screen now carries both halves of the pitch.
- **Release plist drops the `googlevideo.com` ATS exception.** A YouTube fingerprint in the shipped binary; the store SKU has no YouTube path by default and yt-dlp stream URLs are HTTPS anyway.
- **`scripts/verify-release.sh`** builds Release and asserts on the *built* Info.plist — no ATS bypass/exceptions, empty `ARIA_BACKEND_URL`, placeholder homelab host, no API key, export compliance, iPhone-only, privacy manifest bundled, real bundle ID, version fields. It fails today on the bundle ID, which is correct until you change it; `ALLOW_DEV_BUNDLE_ID=1` runs the other eight gates.

## Verified

- 434 tests, 0 failures (3 new, hermetic).
- Fresh install in the simulator opens on **Library** with the new empty-state copy; More → Default Start Page lists Library.
- `ALLOW_DEV_BUNDLE_ID=1 scripts/verify-release.sh` → all gates pass; without the flag it fails on the bundle ID with the right message.

## To test on device

1. Delete Aria, install this build, confirm it opens on Library.
2. More → Default Start Page → pick Favorites, relaunch, confirm it's honored.
3. If you use the Aria backend over Tailscale from a **Release** build, confirm playback still works with the googlevideo exception gone (Debug is unaffected — it has `NSAllowsArbitraryLoads`).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
zsh -lc 'gh pr create --title "Store readiness: iPhone-only, Library first-run, clean Release build" --body-file /tmp/prA.md'
```

---

## PR B — Store listing kit

### Task 6: Worktree + `docs/store/` listing, review notes, privacy answers

Everything App Store Connect will ask for, written once. The owner pastes; nothing here needs a build.

**Files:**
- Create: `docs/store/README.md`, `docs/store/listing.md`, `docs/store/review-notes.md`, `docs/store/app-privacy.md`

- [ ] **Step 1: Worktree**

```bash
cd /Users/chait/MusicAppIOS/Aria_Music_Browser
git worktree add .worktrees/store-listing -b docs/store-listing origin/main
cd .worktrees/store-listing && mkdir -p docs/store/web
```

- [ ] **Step 2: README**

```bash
cat > docs/store/README.md <<'EOF'
# App Store submission kit

Everything App Store Connect asks for, versioned here so the answers are
reviewable and don't live only in a web form.

| File | Pasted where |
|---|---|
| `listing.md` | App Store Connect → App Information / Version Information |
| `review-notes.md` | App Store Connect → App Review Information → Notes |
| `app-privacy.md` | App Store Connect → App Privacy (must match `Resources/PrivacyInfo.xcprivacy`) |
| `submission-checklist.md` | The owner-only steps, in the order they unblock each other |
| `web/privacy-policy.html`, `web/support.html` | Deployed to chai-homelab.com; the URLs go in App Information |
| `screenshots/6.9/` | Version Information → iPhone 6.9" display (added by a follow-up PR) |

Run `scripts/verify-release.sh` before archiving. See `docs/DEPLOYMENT.md` §B for the
review-risk assessment that shaped the copy below.
EOF
```

- [ ] **Step 3: Listing copy**

```bash
cat > docs/store/listing.md <<'EOF'
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

**Subtitle** (30 max, 27 used)
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

**Keywords** (100 max, comma-separated, no spaces — 96 used)
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
EOF
```

- [ ] **Step 4: Review notes**

```bash
cat > docs/store/review-notes.md <<'EOF'
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
EOF
```

- [ ] **Step 5: App Privacy answers**

```bash
cat > docs/store/app-privacy.md <<'EOF'
# App Privacy questionnaire

These answers must match `Resources/PrivacyInfo.xcprivacy` exactly — App Store
Connect cross-checks the manifest at upload. The manifest declares two collected
data types and two accessed-API categories; nothing else is collected.

## Does this app collect data?  **Yes**

Apple's definition of "collect" is "transmitted off the device". Aria transmits
search text and library metadata to the server the user configured. That server
is the user's own; the developer never receives it. The questionnaire has no way
to say that, so it is stated in the privacy policy and the review notes instead.

## Data types

### Search History
- **Collected:** Yes
- **Used for:** App Functionality
- **Linked to the user's identity:** No
- **Used for tracking:** No

### Product Interaction
- **Collected:** Yes
- **Used for:** App Functionality
- **Linked to the user's identity:** No
- **Used for tracking:** No

(Product Interaction covers library metadata — titles, artists, play history —
synced to the user's own server for "Ask Your Library".)

## Every other category: **Not collected**

Contact info, health, financial, location, sensitive info, contacts, user
content beyond the above, browsing history, identifiers, purchases (Apple
handles the IAP; the app sees only an entitlement), usage data, diagnostics,
other data — all **No**.

## Tracking

**Does this app use data for tracking?  No.** There is no advertising SDK, no
analytics SDK, no third-party SDK of any kind (the project has zero
dependencies), and no `NSUserTrackingUsageDescription`.

## Required-reason APIs (already in the manifest)

| API | Reason code | Why |
|---|---|---|
| UserDefaults | CA92.1 | app's own settings |
| File timestamp | C617.1 | detecting changed/missing library files |
EOF
```

- [ ] **Step 6: Commit**

```bash
git add docs/store/README.md docs/store/listing.md docs/store/review-notes.md docs/store/app-privacy.md
git commit -m "Store kit: listing copy, review notes, App Privacy answers

Every text field App Store Connect will ask for, written once and
versioned. The copy is server-neutral by construction — it describes the
store build as what it is, a local-file player that can connect to a
server the user runs — and never names YouTube.

The review notes point the reviewer at the public Navidrome demo
(demo/demo) so the Subsonic path can be exercised against a server
nobody here operates. That is the strongest available answer to 5.2.3:
everything reachable is on-device or a third party's public demo.

App Privacy answers mirror Resources/PrivacyInfo.xcprivacy exactly;
App Store Connect cross-checks the manifest at upload.

Flags that the IAP product ID is still com.chaitea321.aria.pro — product
IDs are permanent once created, so it must be decided with the bundle ID.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Privacy policy + support pages, submission checklist

**Files:**
- Create: `docs/store/web/privacy-policy.html`, `docs/store/web/support.html`, `docs/store/submission-checklist.md`

- [ ] **Step 1: Privacy policy page**

```bash
cat > docs/store/web/privacy-policy.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aria — Privacy Policy</title>
<style>
  :root { color-scheme: light dark; }
  body { max-width: 42rem; margin: 3rem auto; padding: 0 1.25rem; font: 17px/1.55 -apple-system, system-ui, sans-serif; }
  h1 { font-size: 1.75rem; margin-bottom: .25rem; }
  h2 { font-size: 1.15rem; margin-top: 2rem; }
  .meta { opacity: .65; font-size: .9rem; }
  code { font-size: .95em; }
</style>
</head>
<body>
<h1>Aria — Privacy Policy</h1>
<p class="meta">Effective 2026-08-16 · applies to Aria for iOS</p>

<p>Aria is a music player for your own files and your own music server. It has no accounts, no analytics, no advertising, and no third-party SDKs. <strong>The developer does not receive any data from the app.</strong></p>

<h2>What stays on your device</h2>
<p>Your imported music, playlists, favorites, listening history, EQ profiles and settings are stored only on your device, in the app's own storage. They are included in your device backups according to your iOS backup settings, and nowhere else.</p>

<h2>What is sent to a server you configure</h2>
<p>Aria can optionally connect to a music server that <em>you</em> run or choose — for example Navidrome, Airsonic, Gonic, or Aria's open-source companion backend. Nothing is sent anywhere until you enter a server address yourself. Once you do, the app sends to <strong>that server only</strong>:</p>
<ul>
  <li>your search text, so the server can search your library;</li>
  <li>for "Ask Your Library", metadata about your local library (titles, artists, albums, play counts) so the server can index it;</li>
  <li>your username and a salted authentication token for Subsonic servers. <strong>Your password itself is never transmitted.</strong> It is stored in the iOS Keychain.</li>
</ul>
<p>What that server does with the data is governed by whoever operates it — usually you.</p>

<h2>Purchases</h2>
<p>Aria Pro is a one-time purchase handled entirely by Apple. The app learns only whether the purchase is active. The developer never sees your payment details or Apple ID.</p>

<h2>Tracking</h2>
<p>Aria does not track you, does not use identifiers for advertising, and does not share data with anyone. There is nothing to opt out of.</p>

<h2>Children</h2>
<p>Aria collects no personal information from anyone, including children.</p>

<h2>Changes</h2>
<p>If this policy changes, the new version will be published at this address with a new effective date. Aria is open source; the code that governs what the app sends is public at <a href="https://github.com/evince55/Aria">github.com/evince55/Aria</a>.</p>

<h2>Contact</h2>
<p><a href="mailto:aria@chai-homelab.com">aria@chai-homelab.com</a></p>
</body>
</html>
EOF
```

- [ ] **Step 2: Support page**

```bash
cat > docs/store/web/support.html <<'EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Aria — Support</title>
<style>
  :root { color-scheme: light dark; }
  body { max-width: 42rem; margin: 3rem auto; padding: 0 1.25rem; font: 17px/1.55 -apple-system, system-ui, sans-serif; }
  h1 { font-size: 1.75rem; margin-bottom: .25rem; }
  h2 { font-size: 1.15rem; margin-top: 2rem; }
  details { margin: .6rem 0; }
  summary { cursor: pointer; font-weight: 600; }
  code { font-size: .95em; }
</style>
</head>
<body>
<h1>Aria — Support</h1>
<p>Aria is a music player for your own files and your own music server.</p>

<h2>Getting started</h2>
<details open>
<summary>How do I add music?</summary>
<p>Library tab → <strong>Import</strong>. Pick files from the Files app — FLAC, ALAC, AIFF, WAV, MP3 and AAC all work. Aria Pro also imports whole folders and M3U playlists.</p>
</details>
<details>
<summary>How do I connect my server?</summary>
<p>More → Backend. Choose <strong>Subsonic</strong> for Navidrome, Airsonic, Gonic, Astiga or any Subsonic-compatible server, enter its address (the server root, not <code>/rest</code>), your username and password, then tap <strong>Test Connection</strong>. The Search tab appears once a server is configured.</p>
</details>
<details>
<summary>Test Connection fails with "Wrong username or password"</summary>
<p>The server rejected the login. Check the username and password in your server's own web interface first. Some servers require a Subsonic-specific password — Navidrome uses your normal one.</p>
</details>
<details>
<summary>Test Connection says the response wasn't valid Subsonic JSON</summary>
<p>The URL is probably pointing at a web page rather than the server root. Use just the scheme and host, e.g. <code>https://music.example.com</code>, without <code>/rest</code> or <code>/app</code>.</p>
</details>
<details>
<summary>My server is plain http:// and Aria can't reach it</summary>
<p>iOS blocks unencrypted connections except to local-network addresses. Servers on <code>.local</code> names or local hostnames work; a server reached over the internet needs HTTPS. Putting it behind a reverse proxy with a certificate, or a tunnel, is the usual fix.</p>
</details>

<h2>Sound</h2>
<details>
<summary>How do I use AutoEQ?</summary>
<p>Player → EQ → <strong>AutoEQ Profile</strong>. Search for your headphones and apply the measured correction. Save it as a profile to switch between headphones later. Requires Aria Pro.</p>
</details>
<details>
<summary>Does Aria do bit-perfect output to a USB DAC?</summary>
<p>No. iOS mixes all audio through a fixed-rate system mixer; Aria matches the mixer to 44.1 or 48 kHz families but cannot bypass it. This is a platform limit, not an Aria setting.</p>
</details>

<h2>Purchases</h2>
<details>
<summary>I bought Aria Pro on another device</summary>
<p>More → Aria Pro → <strong>Restore Purchases</strong>. Purchases are tied to your Apple ID.</p>
</details>

<h2>Contact</h2>
<p><a href="mailto:aria@chai-homelab.com">aria@chai-homelab.com</a>. Bug reports and feature requests are also welcome at <a href="https://github.com/evince55/Aria/issues">github.com/evince55/Aria/issues</a>.</p>

<p><a href="/aria/privacy">Privacy policy</a></p>
</body>
</html>
EOF
```

- [ ] **Step 3: Submission checklist (owner-only steps, dependency order)**

```bash
cat > docs/store/submission-checklist.md <<'EOF'
# Submission checklist — owner steps

Everything below needs the owner's Apple ID, bank account, or judgement. Each
step unblocks the ones after it. Agent-side work (PRs, screenshots, copy) is
done and referenced where it plugs in.

1. **Merge the queue.** #65, #66, #67, #68, then the store-readiness and
   store-listing PRs. #66 before #68 (the last two "videos" strings live in #66).
2. **Enroll in the Apple Developer Program** ($99/yr) as an **individual** — no
   D-U-N-S number needed. Approval is usually 24–48 h; identity verification can
   add days. Nothing below works until this is done.
3. **Check the name.** App Store Connect → My Apps → + → the Name field errors
   immediately if `Aria: Hi-Fi Music Player` is taken. Fallback in `listing.md`.
4. **Decide the bundle identifier** — `com.<you>.aria`, lowercase, permanent.
   Then in one change: set `PRODUCT_BUNDLE_IDENTIFIER` for the app and tests
   targets in `Aria.xcodeproj/project.pbxproj`, and set the Pro product ID to
   `<bundle id>.pro` in both `Aria.storekit` and `Managers/ProStore.swift:25`.
   ⚠ Changing the bundle ID re-identifies the app: your existing install and
   its library, playlists and settings are abandoned. Back up first.
5. **Create the App ID** (Certificates, Identifiers & Profiles) with that bundle ID.
6. **Deploy the two web pages** to chai-homelab.com at `/aria/privacy` and
   `/aria/support` (`docs/store/web/`), and create the `aria@chai-homelab.com`
   alias in Cloudflare Email Routing — both pages link to it.
7. **Create the app record** in App Store Connect and paste `listing.md`.
8. **Agreements, Tax, and Banking** — accept the Paid Apps agreement, add the
   bank account, complete the W-9. Opt into the **Small Business Program**
   (15% instead of 30%). The IAP cannot go live without this.
9. **Create the Aria Pro IAP** with the product ID from step 4 and the fields in
   `listing.md`. Attach the paywall screenshot.
10. **App Privacy** — answer exactly as `app-privacy.md`. Upload fails if it
    disagrees with the manifest.
11. **Age rating** — all "No" → 4+.
12. **Screenshots** — upload `docs/store/screenshots/6.9/*.png` (from the
    screenshots PR) to the iPhone 6.9" slot. With v1 iPhone-only, that is the
    only required set.
13. **Archive.** Xcode → Product → Archive with the Release configuration. Before
    uploading, run `scripts/verify-release.sh` from the same checkout — it must
    exit 0 **without** `ALLOW_DEV_BUNDLE_ID`.
14. **Upload** via Organizer → Distribute App → App Store Connect. Export
    compliance is pre-answered by the plist; no dialog should appear.
15. **Review notes** — paste `review-notes.md` verbatim, then **Submit for Review**.

If rejected under 5.2.3, `docs/DEPLOYMENT.md` §B3 has the appeal position and the
Unlisted-distribution fallback.
EOF
```

- [ ] **Step 4: Open the two HTML files in a browser and read them once**

```bash
open docs/store/web/privacy-policy.html docs/store/web/support.html
```
Expected: both render in light and dark, no unstyled text, every `<details>` opens, the two `mailto:` links and the GitHub links are correct.

- [ ] **Step 5: Commit, push, open PR B**

```bash
git add docs/store/web/privacy-policy.html docs/store/web/support.html docs/store/submission-checklist.md
git commit -m "Store kit: privacy policy, support page, owner checklist

The two pages App Store Connect requires URLs for, as static HTML the
owner deploys to chai-homelab.com. The privacy policy says the one thing
the App Privacy questionnaire cannot: data goes only to a server the
user configured, never to the developer.

The checklist is every step only the owner can perform, in the order
each unblocks the next — enrollment before name check before bundle ID
before IAP — with the two irreversible decisions (bundle ID, product ID)
called out before they become permanent.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin docs/store-listing
cat > /tmp/prB.md <<'EOF'
Everything App Store Connect will ask for, written once and versioned in `docs/store/`. No code.

| File | Goes in |
|---|---|
| `listing.md` | name, subtitle, description, keywords, category, age rating, IAP fields |
| `review-notes.md` | Notes for Review — points the reviewer at the **public Navidrome demo** so the Subsonic path can be tested against a server nobody here operates |
| `app-privacy.md` | App Privacy answers, mirroring `PrivacyInfo.xcprivacy` exactly |
| `web/privacy-policy.html`, `web/support.html` | the two required URLs, for chai-homelab.com |
| `submission-checklist.md` | your steps, in dependency order |

Two decisions flagged before they become permanent: the **bundle ID** (re-identifies the app, abandons the current install) and the **IAP product ID** (still `com.chaitea321.aria.pro`; permanent once created in App Store Connect — set it with the bundle ID).

Copy never names YouTube. Nothing to device-test; read `listing.md` and `review-notes.md` as the reviewer would.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
zsh -lc 'gh pr create --title "App Store submission kit" --body-file /tmp/prB.md'
```

---

## Follow-up — Screenshots (run after #66 and #68 merge)

### Task 8: Five 6.9" screenshots

Both #66 (Subsonic, search copy) and #68 (Catalog label, Share) change what's on screen; shooting before they merge produces stale images. Required size for the 6.9" slot is **1320 × 2868** — exactly what `simctl io screenshot` produces on iPhone 17 Pro Max.

**Prerequisite (owner-supplied, not in the repo):** 5–10 tagged audio files with artwork. `~/Downloads` has suitable FLAC/MP3s. Titles and artwork in public screenshots are the owner's call — App Store screenshots showing real album art are normal for music players, but it's their decision.

**Files:**
- Create: `docs/store/screenshots/6.9/01-library.png`, `02-player-eq.png`, `03-autoeq.png`, `04-search-subsonic.png`, `05-playlists.png`

- [ ] **Step 1: Worktree off the merged main, boot the 6.9" device**

```bash
cd /Users/chait/MusicAppIOS/Aria_Music_Browser
git fetch origin -q && git worktree add .worktrees/store-screens -b docs/store-screenshots origin/main
cd .worktrees/store-screens
UDID=$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro Max' | grep -oE '[0-9A-F-]{36}')
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcodebuild build -scheme "Aria - Music Browser" -project Aria.xcodeproj \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E 'BUILD SUCCEEDED|BUILD FAILED'
xcrun simctl uninstall "$UDID" XCDevelopment.Aria-Music-Browser 2>/dev/null
xcrun simctl install "$UDID" "build/Build/Products/Debug-iphonesimulator/Aria - Music Browser.app"
```

- [ ] **Step 2: Put the sample files where the Files app can see them**

```bash
FP=$(find ~/Library/Developer/CoreSimulator/Devices/$UDID/data -type d -name 'File Provider Storage' 2>/dev/null | head -1)
[[ -n "$FP" ]] || { echo "open the Files app once in the simulator, then re-run"; exit 1; }
mkdir -p "$FP/Aria Samples"
cp ~/Downloads/*.flac ~/Downloads/*.mp3 "$FP/Aria Samples/" 2>/dev/null; ls "$FP/Aria Samples/"
```
Expected: the files listed. In the simulator: Aria → Library → Import → browse to On My iPhone → Aria Samples → select all → Open. Then favorite two tracks, create a playlist with three, and play one.

- [ ] **Step 3: Shoot each screen at the exact state below**

```bash
mkdir -p docs/store/screenshots/6.9
shot() { xcrun simctl io "$UDID" screenshot "docs/store/screenshots/6.9/$1.png" && sips -g pixelWidth -g pixelHeight "docs/store/screenshots/6.9/$1.png" | tail -2; }
```
Drive to each state, then call `shot`:
1. `shot 01-library` — Library tab, all imported tracks visible, at least one FLAC badge showing.
2. `shot 02-player-eq` — full-screen player with the EQ sheet open and a non-flat curve.
3. `shot 03-autoeq` — the AutoEQ picker with a headphone search result list.
4. `shot 04-search-subsonic` — More → Backend set to Subsonic with the Navidrome demo (demo/demo), then Search → a query with results. The status bar must show a **clean time** (9:41) — `xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3` before shooting.
5. `shot 05-playlists` — Playlists tab with the created playlist and a smart playlist.

Expected after each: `pixelWidth: 1320` / `pixelHeight: 2868`.

- [ ] **Step 4: Look at all five**

Open each PNG with the `Read` tool. Reject any with a keyboard up, a loading spinner, the Keychain warning line (unsigned-build artefact — never on device), or truncated text.

- [ ] **Step 5: Commit and open the PR**

```bash
git add docs/store/screenshots/6.9/*.png
git commit -m "Store kit: five 6.9\" screenshots

Shot on iPhone 17 Pro Max at 1320×2868 after #66 and #68 merged, so the
Catalog label, Subsonic search, and Share behaviour match what ships.
Library, player + EQ, AutoEQ picker, Subsonic search against the public
Navidrome demo, playlists.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
git push -u origin docs/store-screenshots
zsh -lc 'gh pr create --title "Store kit: 6.9\" screenshots" --body "Five 1320×2868 screenshots for the iPhone 6.9\" slot, shot after #66/#68 merged. Titles/artwork are from the sample files you supplied — swap any you would rather not publish.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"'
```

---

## Not in this plan (deliberately)

- **CarPlay** — owner decision 2026-08-16, deferred.
- **Bundle ID and IAP product ID changes** — both permanent, both the owner's decision; the checklist puts them at the right point in the sequence and names the exact files.
- **README lede** still says "YouTube streaming" — positioning prose the owner wrote on purpose in `76924b1`; theirs to change.
- **Subsonic Phase 2**, the `/api/cover` timeout — real work, not launch-blocking.
