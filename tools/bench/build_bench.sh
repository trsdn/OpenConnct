#!/usr/bin/env bash
#
# Builds OCBench as a real, signed application bundle.
#
# Why a bundle and not a bare executable: TCC keys the microphone grant to a code
# signature and a bundle identifier. A command-line binary has neither, so macOS
# attributes its microphone use to whichever terminal launched it and re-asks
# every time. A signed .app with a fixed CFBundleIdentifier is approved once.
#
# The DSP is compiled from source here rather than linked against dist/, so the
# tool has no build-order dependency on the app and always measures the code
# currently in the tree.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"

APP="build/OCBench.app"
BUNDLE_ID="audio.openconnect.bench"
DSP_INCLUDE="$ROOT/Core/Sources/OpenConnectDSP/include"

rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" build/obj

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>OCBench</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>OpenConnect Bench</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenConnect Bench records a short microphone sample so the audio processing can be measured offline.</string>
</dict>
</plist>
PLIST

for src in "$ROOT"/Core/Sources/OpenConnectDSP/*.cpp; do
    clang++ -c -O2 -std=c++17 -fno-exceptions -fno-rtti \
        -target arm64-apple-macosx13.0 \
        -I"$DSP_INCLUDE" -o "build/obj/$(basename "${src%.cpp}").o" "$src"
done

cat > build/bridge.h <<'HEADER'
#include <OpenConnectDSP/oc_channel_strip.h>
#include <OpenConnectDSP/oc_gate.h>
#include <OpenConnectDSP/oc_compressor.h>
#include <OpenConnectDSP/oc_exciter.h>
#include <OpenConnectDSP/oc_bass_enhancer.h>
HEADER

swiftc -O \
    -target arm64-apple-macosx13.0 \
    -import-objc-header build/bridge.h \
    -I"$DSP_INCLUDE" \
    -framework Accelerate -framework AudioToolbox -framework CoreAudio \
    -lc++ build/obj/*.o \
    -o "$APP/Contents/MacOS/OCBench" OCBench.swift

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
echo "Run: $PWD/$APP/Contents/MacOS/OCBench"
