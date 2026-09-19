#!/usr/bin/env bash
# Builds the GitHub Pages site into _site/ (or the directory given as $1).
#
# The one thing filled in is the build date, so the page can say when it was
# generated. There is deliberately no version number: the download button points
# at the latest release, so the page never has to change when one is published.
# SITE_DATE overrides the date (used for local previews).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/_site}"

date="${SITE_DATE:-$(date -u +%F)}"
if [[ ! "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "build_site: '$date' is not an ISO date" >&2
  exit 1
fi

rm -rf "$out"
mkdir -p "$out"
cp -R "$root/site/." "$out/"
sed -e "s/{{DATE}}/$date/g" "$root/site/index.html" > "$out/index.html"

if grep -rqI '{{' "$out"; then
  echo "build_site: an unfilled placeholder is left in the output:" >&2
  grep -rnI '{{' "$out" >&2
  exit 1
fi
echo "Built site ($date) in $out"
