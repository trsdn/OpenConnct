#!/usr/bin/env bash
#
# The README's platform badge is a fixed value, so it must agree with the
# deployment target the app is built for. Fails when they differ.
set -euo pipefail
cd "$(dirname "$0")/.."

target="$(sed -n 's/^DEPLOY_TARGET *= *\([0-9]*\).*/\1/p' Makefile)"
badge="$(grep -o 'badge/macOS-[0-9]*%2B' README.md | head -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
[[ -n "$target" && -n "$badge" ]] || { echo "could not read the deployment target or the README badge" >&2; exit 1; }
if [[ "$target" != "$badge" ]]; then
  echo "README platform badge says macOS $badge+, the Makefile builds for macOS $target" >&2
  exit 1
fi
echo "platform badge agrees with the deployment target (macOS $target+)"
