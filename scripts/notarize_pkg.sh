#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="${RELEASE_ENV_FILE:-.release.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; # shellcheck source=/dev/null
  . "$ENV_FILE"; set +a; fi
PKG_PATH="${PKG_PATH:-dist/OpenConnect-driver.pkg}"
if [[ ! -f "$PKG_PATH" ]]; then echo "PKG not found at $PKG_PATH" >&2; exit 1; fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$PKG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$PKG_PATH" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" --wait
else
  echo "No notarization credentials set. Set NOTARY_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD." >&2
  exit 1
fi
xcrun stapler staple "$PKG_PATH"
xcrun stapler validate "$PKG_PATH"
spctl --assess --type install --verbose "$PKG_PATH"
shasum -a 256 "$PKG_PATH" > "$PKG_PATH.sha256"
