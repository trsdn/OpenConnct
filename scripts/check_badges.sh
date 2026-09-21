#!/usr/bin/env bash
#
# Two badges are not computed when the README is read, so each is checked:
# the platform badge against the deployment target the app is built for, and the
# committed conformance badge against the conformance record.
set -euo pipefail
cd "$(dirname "$0")/.."

target="$(sed -n 's/^DEPLOY_TARGET *= *\([0-9]*\).*/\1/p' Makefile)"
badge="$(grep -o 'badge/macOS-[0-9]*%2B' README.md | head -1 | sed 's/[^0-9]*\([0-9]*\).*/\1/')"
[[ -n "$target" && -n "$badge" ]] || { echo "could not read the deployment target or the README badge" >&2; exit 1; }
if [[ "$target" != "$badge" ]]; then
  echo "README platform badge says macOS $badge+, the Makefile builds for macOS $target" >&2
  exit 1
fi
# The conformance badge is committed and generated from the record; it must say
# what the record says.
state="$(sed -n 's/^state: *"\(.*\)".*/\1/p' .github/conformance.yml)"
[[ -n "$state" ]] || { echo "could not read the state from .github/conformance.yml" >&2; exit 1; }
grep -qF "$state" .github/badges/conformance.svg \
  || { echo "the conformance badge does not say \"$state\", which the record does" >&2; exit 1; }
echo "conformance badge says \"$state\", as the record does"

echo "platform badge agrees with the deployment target (macOS $target+)"
