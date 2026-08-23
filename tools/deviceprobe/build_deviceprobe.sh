#!/usr/bin/env bash
#
# Builds the device control-channel probe.
#
# Unlike the audio probe next door this needs no bundle and no signature: the
# control channel sits on a vendor-defined HID usage page, and macOS gates
# neither enumeration nor access to those. That was verified rather than
# assumed — see docs/device-control.md.
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p build
swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework IOKit \
    -o build/OCDeviceProbe OCDeviceProbe.swift

echo "Built $PWD/build/OCDeviceProbe"
echo "Run: $PWD/build/OCDeviceProbe --list"
