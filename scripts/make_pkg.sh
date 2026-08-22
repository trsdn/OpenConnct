#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${RELEASE_ENV_FILE:-.release.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; # shellcheck source=/dev/null
  . "$ENV_FILE"; set +a; fi

DRIVER_NAME="OpenConnct.driver"
DIST_DIR="${DIST_DIR:-dist}"
DRIVER_PATH="${DRIVER_PATH:-$DIST_DIR/$DRIVER_NAME}"
if [[ -z "${VERSION:-}" ]]; then
  if version_tag="$(git describe --tags --abbrev=0 2>/dev/null)"; then
    VERSION="${version_tag#v}"
  else
    VERSION="0.1.0"
  fi
fi
PKG_ROOT="$DIST_DIR/pkg-root"
PKG_SCRIPTS="$DIST_DIR/pkg-scripts"
COMPONENT_PKG="$DIST_DIR/OpenConnct-driver-component.pkg"
PKG_PATH="${PKG_PATH:-$DIST_DIR/OpenConnct-driver.pkg}"
IDENTIFIER="audio.openconnct.driver"

resolve_installer_identity() {
  local identity="${INSTALLER_SIGN_IDENTITY:-}"
  if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v 2>/dev/null | grep 'Developer ID Installer' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
  fi
  printf '%s' "$identity"
}

if [[ ! -d "$DRIVER_PATH" ]]; then
  echo "Driver bundle not found at $DRIVER_PATH. Run scripts/build_release.sh first." >&2
  exit 1
fi

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS" "$COMPONENT_PKG" "$PKG_PATH" "$PKG_PATH.sha256"
mkdir -p "$PKG_ROOT" "$PKG_SCRIPTS"
ditto "$DRIVER_PATH" "$PKG_ROOT/$DRIVER_NAME"

cat > "$PKG_SCRIPTS/preinstall" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p /Library/Audio/Plug-Ins/HAL
# The project was renamed, and the driver's name went with it. Leaving the old
# bundle behind would publish a second, identical pair of virtual devices under
# the old name, with nothing to tell the user which one their conferencing app
# had picked. An upgrade has to remove its own predecessor.
rm -rf "/Library/Audio/Plug-Ins/HAL/OpenConnect.driver"
SCRIPT

cat > "$PKG_SCRIPTS/postinstall" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
DRIVER_PATH="/Library/Audio/Plug-Ins/HAL/OpenConnct.driver"
chown -R root:wheel "$DRIVER_PATH"
find "$DRIVER_PATH" -type d -exec chmod 755 {} +
find "$DRIVER_PATH" -type f -exec chmod 644 {} +
find "$DRIVER_PATH/Contents/MacOS" -type f -exec chmod 755 {} +
# Do not kill coreaudiod from the installer; BlackHole avoids this for install stability.
SCRIPT
chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"

pkgbuild \
  --root "$PKG_ROOT" \
  --install-location "/Library/Audio/Plug-Ins/HAL" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --scripts "$PKG_SCRIPTS" \
  "$COMPONENT_PKG"

installer_identity="$(resolve_installer_identity)"
if [[ -n "$installer_identity" ]]; then
  productbuild --package "$COMPONENT_PKG" --sign "$installer_identity" "$PKG_PATH"
else
  echo "Warning: no Developer ID Installer identity found; creating unsigned pkg." >&2
  productbuild --package "$COMPONENT_PKG" "$PKG_PATH"
fi

pkgutil --check-signature "$PKG_PATH" || true
shasum -a 256 "$PKG_PATH" > "$PKG_PATH.sha256"
echo "PKG created: $PKG_PATH"
