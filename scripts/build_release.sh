#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${RELEASE_ENV_FILE:-.release.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; # shellcheck source=/dev/null
  . "$ENV_FILE"; set +a; fi

APP_NAME="OpenConnct"
DRIVER_NAME="OpenConnct.driver"
DIST_DIR="${DIST_DIR:-dist}"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DRIVER_PATH="$DIST_DIR/$DRIVER_NAME"
EMBEDDED_DRIVER_PATH="$APP_PATH/Contents/Library/Audio/Plug-Ins/HAL/$DRIVER_NAME"
REQUIRE_SIGNING="${REQUIRE_SIGNING:-1}"
ENTITLEMENTS="${ENTITLEMENTS:-App/OpenConnctApp/OpenConnct.entitlements}"

if [[ ! -f Makefile && ! -f makefile && ! -f GNUmakefile ]]; then
  echo "Makefile not found; this script expects the app/driver build Makefile to be present." >&2
  exit 1
fi

resolve_identity() {
  local identity="${CODE_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
  fi
  printf '%s' "$identity"
}

make clean
# embed-driver depends on both build and driver, and is what stages the
# copy of the plug-in that lives inside the app bundle.
make embed-driver UNIVERSAL=1

if [[ ! -d "$APP_PATH" ]]; then echo "App bundle not found at $APP_PATH after build." >&2; exit 1; fi
if [[ ! -d "$DRIVER_PATH" ]]; then echo "Driver bundle not found at $DRIVER_PATH after driver build." >&2; exit 1; fi
if [[ ! -d "$EMBEDDED_DRIVER_PATH" ]]; then echo "Embedded driver not found at $EMBEDDED_DRIVER_PATH." >&2; exit 1; fi
if [[ ! -f "$ENTITLEMENTS" ]]; then echo "Entitlements file not found at $ENTITLEMENTS." >&2; exit 1; fi

identity="$(resolve_identity)"
if [[ "$REQUIRE_SIGNING" == "1" && -z "$identity" ]]; then echo "No Developer ID Application signing identity found." >&2; exit 1; fi
if [[ -n "$identity" ]]; then
  # Nested code must be signed before its containing app bundle.
  codesign --force --options runtime --sign "$identity" --timestamp "$EMBEDDED_DRIVER_PATH"
  codesign --force --options runtime --sign "$identity" --timestamp "$DRIVER_PATH"
  codesign --force --options runtime --sign "$identity" --timestamp \
    --entitlements "$ENTITLEMENTS" "$APP_PATH"
  codesign --verify --strict --deep --verbose=2 "$APP_PATH"
  codesign --verify --strict --verbose=2 "$DRIVER_PATH"
else
  echo "Skipping code signing because REQUIRE_SIGNING=$REQUIRE_SIGNING and no identity was found."
fi

echo "Release artifacts staged in $DIST_DIR:"
echo "  $APP_PATH"
echo "  $DRIVER_PATH"
