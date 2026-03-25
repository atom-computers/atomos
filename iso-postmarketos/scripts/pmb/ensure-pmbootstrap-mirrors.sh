#!/bin/bash
# Force official Alpine + postmarketOS mirror URLs into pmbootstrap config.
# If mirrors.* are empty or wrong, apk invocations only list local work-dir repos
# (packages/edge with no APKINDEX) and cannot resolve packages from Alpine main
# (e.g. simdutf for vte3-gtk4 -> so:libsimdutf.so.31).
#
# Usage: ensure-pmbootstrap-mirrors.sh <profile-env> [container]
# When the second arg is "container", runs via pmb-container.sh (PMB_CONTAINER_AS_ROOT=1).
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <profile-env> [container]" >&2
    exit 1
fi

PROFILE_ENV="$1"
MODE="${2:-native}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

PMB="$PMB_HOST"
if [ "$MODE" = "container" ]; then
    PMB="$PMB_CONTAINER"
fi

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# Defaults match pmbootstrap docs; override with env when needed.
ALPINE_MIRROR="${ATOMOS_MIRROR_ALPINE:-http://dl-cdn.alpinelinux.org/alpine/}"
PMAPORTS_MIRROR="${ATOMOS_MIRROR_PMAPORTS:-http://mirror.postmarketos.org/postmarketos/}"
SYSTEMD_MIRROR="${ATOMOS_MIRROR_SYSTEMD:-http://mirror.postmarketos.org/postmarketos/extra-repos/systemd/}"

if [ -z "${PMB_WORK_OVERRIDE:-}" ]; then
    echo "ensure-pmbootstrap-mirrors: WARNING: PMB_WORK_OVERRIDE is unset — pmbootstrap may use PMB_WORK from profile (e.g. .pmbootstrap under the repo) instead of ~/.atomos-pmbootstrap-work/… . Export PMB_WORK_OVERRIDE or run via make build." >&2
fi

run() {
    if [ "$MODE" = "container" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV" "$@"
    else
        bash "$PMB" "$PROFILE_ENV" "$@"
    fi
}

echo "ensure-pmbootstrap-mirrors: setting mirrors.alpine / mirrors.pmaports / mirrors.systemd"
run config mirrors.alpine "$ALPINE_MIRROR"
run config mirrors.pmaports "$PMAPORTS_MIRROR"
run config mirrors.systemd "$SYSTEMD_MIRROR"

# After init, apk invocations can still use only local packages/{edge,systemd-edge} with no
# APKINDEX unless chroots pick up mirror config and missing local indexes are generated.
# `pmbootstrap update --non-existing` refreshes existing indexes and creates missing ones.
if [ "${ATOMOS_SKIP_PMB_UPDATE_AFTER_MIRRORS:-0}" = "1" ]; then
    echo "ensure-pmbootstrap-mirrors: skipping pmbootstrap update (ATOMOS_SKIP_PMB_UPDATE_AFTER_MIRRORS=1)"
else
    echo "ensure-pmbootstrap-mirrors: pmbootstrap update --non-existing (refresh/create apk indexes; may take a few minutes)"
    run update --non-existing
fi
