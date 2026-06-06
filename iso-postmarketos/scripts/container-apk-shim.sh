#!/bin/sh
# scripts/container-apk-shim.sh -- container-side `apk` wrapper for the
# AtomOS local-first package store.
#
# This file is NOT sourced. The build bodies install it onto PATH as
# /usr/local/bin/apk (same trick the heavy build body already uses for
# its `ar` shim) and prepend /usr/local/bin to PATH. After that, EVERY
# `apk ...` invocation in the surrounding script -- including overlay
# sub-scripts that run as their own processes -- transparently:
#
#   * uses the persistent cache dir  $ATOMOS_APK_CACHE_DIR  (downloaded
#     .apk files + APKINDEX snapshots survive across builds on the host),
#     so packages already stored locally are reused, and
#   * runs in the network mode chosen by the HOST via $ATOMOS_APK_NET:
#       --no-network    -> offline: no web request is made; the locally
#                          stored index + packages are used. The build is
#                          immune to dl-cdn / pmOS mirror / DNS outages.
#       --update-cache  -> online: refresh the index from the mirrors and
#                          download anything missing, repopulating the
#                          local store with the newest versions.
#
# The offline->online *fallback* (when the local store cannot satisfy a
# request) is handled by the host orchestrator at the PHASE level (re-run
# the phase with $ATOMOS_APK_NET=--update-cache), NOT here: a per-call
# retry would have to capture apk's stderr, which would hide the
# pre/post-install WARNING lines that _lib-rootfs-bootstrap.sh greps its
# logs for. Keeping this wrapper a thin, stateless exec keeps those
# audits intact.
#
# Honored environment (exported by the host via `docker run -e`):
#   ATOMOS_APK_CACHE_DIR   absolute cache dir inside the container
#                          (default /pkgcache/apk)
#   ATOMOS_APK_NET         "--no-network" (offline) | "--update-cache"
#                          (online). Default: --no-network.

# Resolve the real apk binary (never this shim, to avoid recursion).
_real_apk=""
for _cand in /sbin/apk /usr/bin/apk /usr/sbin/apk /bin/apk; do
    if [ -x "$_cand" ]; then
        _real_apk="$_cand"
        break
    fi
done
if [ -z "$_real_apk" ]; then
    echo "container-apk-shim: cannot locate the real apk binary" >&2
    exit 127
fi

_cache_dir="${ATOMOS_APK_CACHE_DIR:-/pkgcache/apk}"
_net="${ATOMOS_APK_NET:---no-network}"
mkdir -p "$_cache_dir" 2>/dev/null || true

# Drop any caller-supplied network flags so the HOST fully controls the
# network mode (callers historically pass --update-cache / -U). Package
# names and the build's file paths never contain whitespace, so simple
# word re-splitting of $_args below is safe.
_args=""
for _a in "$@"; do
    case "$_a" in
        --update-cache|-U|--no-network) continue ;;
    esac
    _args="$_args $_a"
done

# --cache-dir is given as an ABSOLUTE path. apk passes it to openat();
# an absolute path ignores the --root dirfd, so the cache lands at
# $_cache_dir on the mounted volume, NOT under /target. (Verified.)
# shellcheck disable=SC2086
exec "$_real_apk" --cache-dir "$_cache_dir" $_net $_args
