# Shared by the release scripts so the app version, the driver .pkg version and
# the DMG's filename can never drift apart from one another — AppUpdater
# matches a release asset named exactly OpenConnct-<version>.dmg against the
# app's own CFBundleShortVersionString, so all three have to agree.
resolve_version() {
  local version="${VERSION:-}"
  if [[ -z "$version" ]]; then
    local version_tag
    if version_tag="$(git describe --tags --abbrev=0 2>/dev/null)"; then
      version="${version_tag#v}"
    else
      version="0.1.0"
    fi
  fi
  printf '%s' "$version"
}
