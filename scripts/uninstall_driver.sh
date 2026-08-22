#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DRIVER_NAME="OpenConnct.driver"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
INSTALL_PATH="$INSTALL_DIR/$DRIVER_NAME"
DEVICE_NAME="OpenConnct Mic"

if [[ -z "$INSTALL_PATH" || "$INSTALL_PATH" != "/Library/Audio/Plug-Ins/HAL/OpenConnct.driver" ]]; then
  echo "Refusing to remove driver because INSTALL_PATH is empty or unexpected: '$INSTALL_PATH'" >&2
  exit 1
fi

if [[ ! -e "$INSTALL_PATH" ]]; then
  echo "$DRIVER_NAME is not installed at $INSTALL_PATH."
else
  echo "Removing $INSTALL_PATH with sudo..."
  sudo rm -rf "$INSTALL_PATH"
fi

# The project was renamed and the driver's name went with it. Someone who
# installed the older build and is now uninstalling would otherwise be left with
# a virtual device and nothing on disk that looks like it belongs to us.
LEGACY_PATH="$INSTALL_DIR/OpenConnect.driver"
if [[ -e "$LEGACY_PATH" ]]; then
  echo "Also removing the pre-rename driver at $LEGACY_PATH..."
  sudo rm -rf "$LEGACY_PATH"
fi

# launchctl kickstart -k system/com.apple.audio.coreaudiod was deprecated in macOS 14.4;
# a reboot is the only officially supported CoreAudio plug-in reload.
echo "Restarting CoreAudio with sudo killall -9 coreaudiod..."
sudo killall -9 coreaudiod || true

for _ in {1..10}; do
  if ! system_profiler SPAudioDataType 2>/dev/null | grep -Fq "$DEVICE_NAME"; then
    echo "Uninstalled successfully: '$DEVICE_NAME' is no longer present."
    exit 0
  fi
  sleep 1
done

echo "$DRIVER_NAME was removed, but '$DEVICE_NAME' is still visible. Reboot macOS to force a HAL reload." >&2
exit 1
