#!/bin/bash
#
# Installs the HAL plug-in that this app carries, into /Library/Audio/Plug-Ins/HAL.
#
# This runs as root, so it is written defensively.
#
# It takes NO ARGUMENTS. Everything it touches is derived from its own location
# inside the app bundle, or is a hard-coded constant. That is deliberate: a
# privileged script that accepts a path is a privileged script that can be asked
# to install something else, and the caller would then be the only thing
# standing between an attacker and root. With no inputs there is nothing to
# smuggle in.
#
# It also refuses to install a plug-in it cannot vouch for. The signature is
# checked here, as root, immediately before the copy — not by the caller. A
# check performed by the unprivileged side proves nothing about what the
# privileged side then does.

set -euo pipefail

# Pinned rather than inherited. `do shell script … with administrator
# privileges` is documented to reset PATH to exactly this, so nothing changes in
# practice — but a root script should not be depending on a caller's PATH for
# the tools it uses to decide whether something is safe to install.
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

readonly INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
readonly DRIVER_NAME="OpenConnct.driver"
# Pre-rename name. A leftover bundle under the old name has a different bundle
# identifier, so coreaudiod loads it as well and publishes a second, identical
# pair of virtual devices with no way for the user to tell which is which.
readonly LEGACY_DRIVER_NAME="OpenConnect.driver"

readonly INSTALL_PATH="$INSTALL_DIR/$DRIVER_NAME"
# Staging path. The new copy is assembled and checked here first; see the
# install section below for why this is not just tidiness.
readonly STAGE_PATH="$INSTALL_DIR/.$DRIVER_NAME.incoming"

# $0 is <app>/Contents/Resources/install-driver.sh, so the driver sits two
# levels up. Resolved with cd/pwd rather than by string surgery so that a
# symlinked or oddly-cased path still lands somewhere real.
#
# Declaration is kept separate from assignment on purpose. `readonly X="$(cmd)"`
# is a declaration builtin, and its own exit status — always 0 — is what `set -e`
# sees, so a failing command substitution would silently leave X empty and the
# script would carry on with paths that collapse to the wrong place. Assigning
# first means `set -e` sees the substitution's real status and we fail closed.
resources_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
readonly resources_dir

CONTENTS_DIR="$(cd -- "$resources_dir/.." && pwd -P)"
readonly CONTENTS_DIR

APP_PATH="$(cd -- "$CONTENTS_DIR/.." && pwd -P)"
readonly APP_PATH

readonly SOURCE_PATH="$CONTENTS_DIR/Library/Audio/Plug-Ins/HAL/$DRIVER_NAME"

fail() {
  echo "$1" >&2
  exit 1
}

# Never leave a half-copied bundle behind in a system directory. The next run
# would clear it anyway, but "the next run" might be months away, and a partial
# driver sitting in /Library/Audio/Plug-Ins/HAL is exactly the sort of thing
# somebody later has to work out the provenance of. The leading dot keeps it out
# of the way meanwhile; coreaudiod only loads directories ending in .driver.
cleanup() {
  rm -rf "$STAGE_PATH"
}
trap cleanup EXIT

[ -d "$SOURCE_PATH" ] || fail "This copy of the app has no driver to install (expected it at $SOURCE_PATH)."

if [ "$(id -u)" -ne 0 ]; then
  fail "install-driver.sh must run as root."
fi

# --- Vouch for what we are about to install -------------------------------
#
# --strict makes codesign reject a bundle with extra or altered files rather
# than quietly ignoring them, which is the case that matters here.
codesign --verify --strict "$SOURCE_PATH" 2>/dev/null \
  || fail "The bundled driver's signature is not valid; refusing to install it."

team_of() {
  local details
  # `codesign -dv` exits non-zero for a bundle with no signature at all, and
  # with `pipefail` that status propagates out of the command substitution at
  # the call site and kills the script under `set -e` — silently, before the
  # ad-hoc branch below ever gets a chance to run. Absence of a signature is a
  # thing this function is meant to be able to *report*, not a reason to abort,
  # so it is caught here and turned into an empty answer.
  details="$(codesign -dv "$1" 2>&1)" || return 0
  printf '%s' "$details" | sed -n 's/^TeamIdentifier=//p'
}

app_team="$(team_of "$APP_PATH")"
driver_team="$(team_of "$SOURCE_PATH")"

if [ -n "$app_team" ] && [ "$app_team" != "not set" ]; then
  # The driver must come from whoever shipped the app. Comparing the two
  # instead of hard-coding a team identifier means a fork signed by someone
  # else keeps working, while a driver swapped in from a third party does not.
  [ "$driver_team" = "$app_team" ] \
    || fail "The bundled driver is signed by ${driver_team:-nobody} but the app by $app_team; refusing to install it."
else
  # No team means an ad-hoc signature or no signature at all, i.e. a
  # development build. Say so rather than pretending the check above proved
  # anything. Reaching here from the app is not possible — it validates its own
  # signature first — so this is somebody running the script by hand as root.
  echo "note: this build is not Developer ID signed, so the driver's origin cannot be verified." >&2
fi

# --- Install ---------------------------------------------------------------
#
# Staged, then swapped. The obvious version of this — delete the old bundle,
# copy the new one in — has a nasty failure mode: with `set -e` any stumble in
# the copy or the verification afterwards aborts the script *after* the working
# driver has already been deleted. Someone who clicked "Update" would be left
# with no driver at all, which is worse than the state they started in, and on a
# machine where all audio has just been restarted to boot.
#
# So the new copy is assembled beside the old one and checked there. Only once
# it is known good does the old one go, and the replacement is a rename.

mkdir -p "$INSTALL_DIR"

# A leftover stage directory from an interrupted earlier run would make ditto
# merge into it rather than produce a clean copy.
rm -rf "$STAGE_PATH"

# ditto rather than cp: it preserves the bundle's extended attributes and
# resource forks, and cp -R has a history of mangling signed bundles.
ditto "$SOURCE_PATH" "$STAGE_PATH"

chown -R root:wheel "$STAGE_PATH"
find "$STAGE_PATH" -type d -exec chmod 755 {} +
find "$STAGE_PATH" -type f -exec chmod 644 {} +
find "$STAGE_PATH/Contents/MacOS" -type f -exec chmod 755 {} +

# Last chance to refuse while the existing driver is still in place. ditto has
# never been observed to corrupt a bundle, but a full disk or a failing volume
# is exactly the moment this matters.
if ! codesign --verify --strict "$STAGE_PATH" 2>/dev/null; then
  rm -rf "$STAGE_PATH"
  fail "The copied driver does not verify; nothing has been changed."
fi

# From here on the window in which no driver is installed is one rename long.
rm -rf "$INSTALL_PATH"
mv "$STAGE_PATH" "$INSTALL_PATH"

# Only now, with a working driver in place, is it safe to drop the pre-rename
# bundle. Doing it earlier would mean an aborted run could remove the old
# driver without having installed the new one.
rm -rf "${INSTALL_DIR:?}/$LEGACY_DRIVER_NAME"

# launchctl kickstart -k system/com.apple.audio.coreaudiod was deprecated in
# macOS 14.4. Killing coreaudiod is what remains; launchd restarts it at once.
# Audio drops out for about a second, everywhere on the system.
killall -9 coreaudiod 2>/dev/null || true

echo "OC_INSTALL_OK"
