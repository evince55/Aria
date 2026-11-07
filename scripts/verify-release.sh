#!/usr/bin/env bash
# Builds Aria with the Release configuration and asserts on the BUILT
# product's Info.plist and bundled files — not the source plists — so what's
# checked is what would be archived. Run before every App Store submission:
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
FAM="$(plutil -extract UIDeviceFamily json -o - "$PLIST" | tr -d '[:space:]')"
[[ "$FAM" == "[1]" ]] || fail "UIDeviceFamily is $FAM, expected [1]"
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

# 9. The dev TLS cert stays out of the bundle. Its CN/SAN name the backend's
# tailnet address, and Release never loads it (TLSPinningDelegate is #if DEBUG).
CERTS="$(find "$APP" -iname 'cert.der')"
[[ -z "$CERTS" ]] || fail "dev certificate bundled: ${CERTS#"$APP"/} — check EXCLUDED_SOURCE_FILE_NAMES on the Release config"
pass "no cert.der in the bundle"

# 10. No tailnet address in ANY bundled file, whatever it's called. Matches the
# whole Tailscale CGNAT range (100.64.0.0/10) so this script never has to name a
# real host; for the same reason a failure prints the file, never the match.
# Each file is scanned as raw bytes and again with NULs dropped, which catches
# UTF-16 strings in binary plists. Compressed payloads (Assets.car, PNGs) are opaque.
LEAKS="$(find "$APP" -type f -exec perl -0777 -ne '
  print "$ARGV\n" if ($_ . "\n" . (s/\0//gr)) =~
    /(?<![0-9.])100\.(?:6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}(?!\.?[0-9])/;
' {} +)"
[[ -z "$LEAKS" ]] || fail "tailnet address (100.64.0.0/10) found in: ${LEAKS//"$APP"\//}"
pass "no tailnet address in any bundled file"

echo
echo "Release product is clean."
