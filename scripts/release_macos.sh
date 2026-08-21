#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ENV_FILE="${RELEASE_ENV_FILE:-.release.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; # shellcheck source=/dev/null
  . "$ENV_FILE"; set +a; fi
PKG_PATH="${PKG_PATH:-dist/OpenConnect-driver.pkg}"
DMG_PATH="${DMG_PATH:-dist/OpenConnect-macos.dmg}"

./scripts/build_release.sh
PKG_PATH="$PKG_PATH" ./scripts/make_pkg.sh

if [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ) ]]; then
  PKG_PATH="$PKG_PATH" ./scripts/notarize_pkg.sh
else
  echo "Skipping PKG notarization because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
fi

PKG_PATH="$PKG_PATH" DMG_PATH="$DMG_PATH" ./scripts/make_dmg.sh
if [[ -n "${NOTARY_PROFILE:-}" || ( -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ) ]]; then
  DMG_PATH="$DMG_PATH" ./scripts/notarize_dmg.sh
else
  echo "Skipping DMG notarization because neither NOTARY_PROFILE nor APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_PASSWORD are set."
fi
