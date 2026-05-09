#!/bin/bash
# Overlay the locally-vendored Fairphone 4 device package
# (iso-postmarketos/pmaports/device/community/device-fairphone-fp4) into
# pmbootstrap's pmaports cache so any local edits to deviceinfo, UCM,
# udev, wireplumber or modules-initfs ship in the rootfs that pmbootstrap
# builds.
#
# Usage: sync-fairphone-fp4-overlay.sh <profile-env>
#
# - Reads PROFILE_NAME / PMOS_DEVICE from the profile env so we only
#   touch the cache when the active build target is fairphone-fp4.
# - Resolves the cache path with the same rules as
#   scripts/build-image.sh::pmaports_cache_dir (host vs container home).
# - Refuses to clobber an unrelated cache directory: the destination
#   must already contain an APKBUILD for device-fairphone-fp4 (i.e. the
#   pmbootstrap pmaports clone is initialised), otherwise we exit 0
#   without modifying anything.
# - Idempotent: copies are mode-preserving and overwrite in place.
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 2
fi

PROFILE_ENV="$1"
if [ ! -f "$PROFILE_ENV" ]; then
    echo "ERROR: profile env not found: $PROFILE_ENV" >&2
    exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$PROFILE_ENV"

PMOS_DEVICE="${PMOS_DEVICE:-}"
if [ "$PMOS_DEVICE" != "fairphone-fp4" ]; then
    echo "sync-fairphone-fp4-overlay: PMOS_DEVICE=${PMOS_DEVICE:-<unset>} (skipping; not fairphone-fp4)."
    exit 0
fi

LOCAL_OVERLAY="$ROOT_DIR/pmaports/device/community/device-fairphone-fp4"
if [ ! -d "$LOCAL_OVERLAY" ]; then
    echo "sync-fairphone-fp4-overlay: local overlay not present at $LOCAL_OVERLAY (skipping)."
    exit 0
fi

if [ -n "${SUDO_USER:-}" ]; then
    BASE_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    BASE_HOME="$HOME"
fi

if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    CONTAINER_HOME="${PMB_CONTAINER_HOME_DIR:-$BASE_HOME/.atomos-pmbootstrap-home}"
    PMAPORTS_CACHE="$CONTAINER_HOME/.local/var/pmbootstrap/cache_git/pmaports"
else
    PMAPORTS_CACHE="$BASE_HOME/.local/var/pmbootstrap/cache_git/pmaports"
fi

DEST="$PMAPORTS_CACHE/device/community/device-fairphone-fp4"

if [ ! -d "$PMAPORTS_CACHE/.git" ]; then
    echo "sync-fairphone-fp4-overlay: pmaports cache missing or not a git checkout at $PMAPORTS_CACHE (skipping)."
    echo "  Re-run after pmbootstrap init has populated the cache."
    exit 0
fi

if [ ! -f "$DEST/APKBUILD" ]; then
    echo "sync-fairphone-fp4-overlay: destination $DEST does not look like the upstream FP4 device package (no APKBUILD); refusing to overwrite."
    exit 0
fi

echo "sync-fairphone-fp4-overlay: overlay $LOCAL_OVERLAY -> $DEST"

mkdir -p "$DEST"

copied_any=0
while IFS= read -r -d '' src; do
    rel="${src#$LOCAL_OVERLAY/}"
    dst="$DEST/$rel"
    mkdir -p "$(dirname "$dst")"
    if cp -f -p "$src" "$dst" 2>/dev/null; then
        copied_any=1
    elif command -v sudo >/dev/null 2>&1; then
        sudo install -D -m 0644 "$src" "$dst"
        copied_any=1
    else
        echo "sync-fairphone-fp4-overlay: WARN unable to copy $src -> $dst (no write permission, sudo unavailable)" >&2
    fi
done < <(find "$LOCAL_OVERLAY" -type f -print0)

if [ "$copied_any" -eq 1 ]; then
    echo "sync-fairphone-fp4-overlay: applied local FP4 device package overlay."
else
    echo "sync-fairphone-fp4-overlay: WARN no files were copied from $LOCAL_OVERLAY." >&2
fi
