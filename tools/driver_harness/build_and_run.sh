#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="$ROOT_DIR/tools/driver_harness"
BUILD_DIR="$HARNESS_DIR/build"
DRIVER_BUNDLE="$BUILD_DIR/OpenConnect.driver"
DRIVER_BIN="$DRIVER_BUNDLE/Contents/MacOS/OpenConnect"
HARNESS_BIN="$BUILD_DIR/driver_harness"

rm -rf "$BUILD_DIR"
mkdir -p "$DRIVER_BUNDLE/Contents/MacOS" "$DRIVER_BUNDLE/Contents/Resources"

clang -x c -std=c11 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -O2 -fno-common -Wall -Wextra -Werror \
  -bundle \
  -framework CoreFoundation -framework CoreAudio \
  -o "$DRIVER_BIN" "$ROOT_DIR/App/OpenConnectDriver/OpenConnectDriver.c"
cp "$ROOT_DIR/App/OpenConnectDriver/Info.plist" "$DRIVER_BUNDLE/Contents/Info.plist"

clang++ -std=c++17 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
  -framework CoreFoundation -framework CoreAudio \
  -o "$HARNESS_BIN" "$HARNESS_DIR/driver_harness.cpp"

"$HARNESS_BIN" "$DRIVER_BUNDLE"
