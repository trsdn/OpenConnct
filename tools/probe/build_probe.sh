#!/usr/bin/env bash
#
# Builds OCProbe as a real, signed application bundle.
#
# Why a bundle and not a bare executable: TCC keys the microphone grant to a
# code signature and a bundle identifier. A command-line binary has neither a
# stable identifier nor an Info.plist, so macOS attributes its microphone use to
# whichever terminal launched it and re-asks every time. Wrapping the probe in a
# signed .app with a fixed CFBundleIdentifier means the user approves it exactly
# once, permanently.
set -euo pipefail

cd "$(dirname "$0")"

APP="build/OCProbe.app"
BUNDLE_ID="audio.openconnect.probe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>OCProbe</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>OpenConnect Probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenConnect Probe measures the OpenConnect virtual audio device to verify the driver.</string>
</dict>
</plist>
PLIST

swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework AudioToolbox -framework CoreAudio \
    -o "$APP/Contents/MacOS/OCProbe" OCProbe.swift

identity="${CODE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)"/\1/')}"

if [[ -n "$identity" ]]; then
    codesign --force --options runtime --sign "$identity" --timestamp "$APP"
    codesign --verify --strict "$APP"
    echo "Signed $APP with: $identity"
else
    echo "WARNING: no Developer ID identity; macOS will re-ask for microphone access every run." >&2
fi

echo "Built $APP"
echo "Run: $PWD/$APP/Contents/MacOS/OCProbe"
