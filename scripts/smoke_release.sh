#!/usr/bin/env bash
#
# Checks the DMG a user actually downloads, not the one built locally.
#
# Takes an optional tag (default: the latest release), downloads the release's
# DMG and checksum with `gh`, and checks, in order: the checksum, that the two
# DMG names are byte-identical (the updater only looks at the plain name), the
# notarization ticket, the app's signature and Gatekeeper verdict, that the
# app's version is the tag's, and that the embedded driver is signed by the same
# team as the app. It exits 0 and prints "SMOKE PASS" only if all of them hold.
#
# It does not start the app: launching it needs a person to grant microphone
# access and to authorise the driver install. Everything short of that is checked.
#
# Needs macOS (hdiutil, codesign, spctl, stapler) and an authenticated `gh`.

set -euo pipefail

repo="${REPO:-trsdn/OpenConnct}"
tag="${1:-$(gh release view -R "$repo" --json tagName -q .tagName)}"
version="${tag#v}"
work="$(mktemp -d)"
mount=""
cleanup() {
  [[ -n "$mount" ]] && hdiutil detach "$mount" -quiet 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

fail() { echo "SMOKE FAIL ($tag): $*" >&2; exit 1; }
step() { echo "  ok  $*"; }

echo "Smoke test of $repo $tag"
gh release download "$tag" -R "$repo" -D "$work" \
  -p "OpenConnct-$version.dmg" -p "OpenConnct-$version.dmg.sha256" \
  -p "OpenConnct-$tag-macOS-universal.dmg" \
  || fail "could not download the release assets"

dmg="$work/OpenConnct-$version.dmg"
(cd "$work" && shasum -a 256 -c "OpenConnct-$version.dmg.sha256" >/dev/null) \
  || fail "checksum does not match"
step "checksum matches"

cmp -s "$dmg" "$work/OpenConnct-$tag-macOS-universal.dmg" \
  || fail "the updater's DMG differs from the universal DMG"
step "updater DMG is byte-identical to the universal DMG"

xcrun stapler validate "$dmg" >/dev/null 2>&1 || fail "no valid notarization ticket on the DMG"
step "notarization ticket is stapled"

mount="$(hdiutil attach "$dmg" -nobrowse -readonly | tail -1 | awk -F'\t' '{print $NF}')"
app="$mount/OpenConnct.app"
[[ -d "$app" ]] || fail "OpenConnct.app is not in the DMG"

codesign --verify --deep --strict "$app" 2>/dev/null || fail "app signature is invalid"
step "app signature is valid"

spctl -a -t exec "$app" 2>/dev/null || fail "Gatekeeper rejects the app"
spctl -a -t exec -vv "$app" 2>&1 | grep -q "Notarized Developer ID" \
  || fail "Gatekeeper does not report Notarized Developer ID"
step "Gatekeeper accepts it as Notarized Developer ID"

actual="$(defaults read "$app/Contents/Info" CFBundleShortVersionString)"
[[ "$actual" == "$version" ]] || fail "app version is $actual, tag is $version"
step "app version is $actual"

driver="$app/Contents/Library/Audio/Plug-Ins/HAL/OpenConnct.driver"
[[ -d "$driver" ]] || fail "the app carries no driver"
codesign --verify --strict "$driver" 2>/dev/null || fail "driver signature is invalid"
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
[[ -n "$(team "$app")" && "$(team "$app")" == "$(team "$driver")" ]] \
  || fail "app and driver are not signed by the same team"
step "embedded driver is signed by the same team as the app"

echo "SMOKE PASS ($tag)"
