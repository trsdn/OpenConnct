#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE="${RELEASE_ENV_FILE:-.release.env}"
if [[ -f "$ENV_FILE" ]]; then set -a; # shellcheck source=/dev/null
  . "$ENV_FILE"; set +a; fi

DRIVER_NAME="OpenConnct.driver"
DRIVER_PATH="${DRIVER_PATH:-dist/$DRIVER_NAME}"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALL_PATH="$INSTALL_DIR/$DRIVER_NAME"
DEVICE_NAME="OpenConnct Mic"

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

echo "This development install uses sudo, writes to $INSTALL_DIR, and restarts system audio."
echo "Building $DRIVER_NAME..."
make driver

if [[ ! -d "$DRIVER_PATH" ]]; then
  echo "Driver bundle not found at $DRIVER_PATH after 'make driver'." >&2
  exit 1
fi

identity="$(resolve_identity)"
if [[ -z "$identity" ]]; then
  echo "No Developer ID Application signing identity found. Set CODE_SIGN_IDENTITY in $ENV_FILE." >&2
  exit 1
fi

echo "Signing $DRIVER_PATH with: $identity"
codesign --force --options runtime --sign "$identity" --timestamp "$DRIVER_PATH"
codesign --verify --strict --verbose=2 "$DRIVER_PATH"

echo "Installing $DRIVER_NAME to $INSTALL_PATH..."
sudo mkdir -p "$INSTALL_DIR"
sudo rm -rf "$INSTALL_PATH"
# Same reasoning as the installer's preinstall: the driver was renamed with the
# project, and a leftover bundle under the old name would publish a second,
# identical pair of virtual devices.
sudo rm -rf "$INSTALL_DIR/OpenConnect.driver"
sudo ditto "$DRIVER_PATH" "$INSTALL_PATH"
sudo chown -R root:wheel "$INSTALL_PATH"
sudo find "$INSTALL_PATH" -type d -exec chmod 755 {} +
sudo find "$INSTALL_PATH" -type f -exec chmod 644 {} +
sudo find "$INSTALL_PATH/Contents/MacOS" -type f -exec chmod 755 {} +

# launchctl kickstart -k system/com.apple.audio.coreaudiod was deprecated in macOS 14.4;
# a reboot is the only officially supported CoreAudio plug-in reload.
echo "Restarting CoreAudio with sudo killall -9 coreaudiod..."
sudo killall -9 coreaudiod || true

for _ in {1..10}; do
  if system_profiler SPAudioDataType 2>/dev/null | grep -Fq "$DEVICE_NAME"; then
    echo "Installed successfully: '$DEVICE_NAME' is present."
    exit 0
  fi
  sleep 1
done

cat >&2 <<EOF2
$DRIVER_NAME was installed and CoreAudio was restarted, but '$DEVICE_NAME' was not detected yet.
Next steps:
  1. Check System Settings > Sound > Input.
  2. Reboot macOS to force an officially supported HAL plug-in reload.
  3. Inspect Console.app for OpenConnct/CoreAudio plug-in load errors.
EOF2
exit 1
