# shellcheck shell=bash
# scripts/_lib-build-common.sh -- shared bash helpers for the top-level
# image-build orchestrators (build-qemu.sh, build-fairphone4.sh, and any
# future per-device build script that follows the same pattern).
#
# This file is meant to be SOURCED, not executed. It contains pure
# function definitions only -- no side effects on source. Each function
# is prefixed `atomos_` to avoid clashing with any caller-local helpers
# of the same short name (e.g. `cleanup_volume` is wrapped by callers
# that need profile-specific keep-volume gates around the shared core).
#
# Why a leaf .sh file under scripts/ instead of scripts/_lib/<name>.sh:
# the existing convention in this repo (see scripts/home-bg/_lib-cross-build.sh)
# is to prefix shared bash libs with `_lib-` and keep them next to the
# scripts that use them; matching that lets shellcheck source-resolution
# and the existing PATH walks Just Work without a config change.

# Probe for an available container engine. Echoes "docker", "podman", or
# "" (empty) on stdout. Both engines must respond to `info` to count as
# usable -- this catches the common Linux/macOS gotcha where the binary
# is on PATH but the daemon isn't running (so a later `docker run` would
# hang or error opaquely; we want to report it up-front in require_tools
# checks).
atomos_find_container_engine() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
    else
        echo ""
    fi
}

# Hard-fail (exit 2) if any required host tool is missing. Both build
# scripts need dd (for empty image creation), rsync (rootfs sync), and
# python3 (used by the small inline scripts for path/json/manifest work).
# Caller can extend the required set by appending args:
#   atomos_require_tools          # default set
#   atomos_require_tools fastboot # default set + fastboot
atomos_require_tools() {
    local missing=0 t
    local -a tools=(dd rsync python3 "$@")
    for t in "${tools[@]}"; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "ERROR: required command missing: $t" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 2
}

# Remove a docker/podman volume. Idempotent: succeeds when the volume
# doesn't exist. Caller is responsible for any keep-volume opt-out gate
# (build-fairphone4.sh has ATOMOS_FP4_KEEP_ROOTFS_VOLUME=1; build-qemu.sh
# has no opt-out and always cleans). Args:
#   $1: container engine ("docker" or "podman")
#   $2: volume name (e.g. "atomos-fp4-rootfs-fairphone-fp4")
atomos_cleanup_volume() {
    local engine="$1" vol="$2"
    if [ -z "$engine" ] || [ -z "$vol" ]; then
        echo "atomos_cleanup_volume: ERROR engine and volume name are required" >&2
        return 2
    fi
    "$engine" volume rm -f "$vol" >/dev/null 2>&1 || true
}

# Shell fragment for docker/podman overlay containers (build-qemu, build-fairphone4).
# The rootfs at /target already has bash/python3 from the manifest apk pass; use
# that musl binary via the target dynamic linker instead of `apk add` in the
# ephemeral alpine:edge helper (which hits dl-cdn and can 404 when the image
# index is stale). vendor/aports and rust/ are unrelated to this step.
atomos_overlay_container_bash_setup() {
    cat <<'ATOMOS_OVERLAY_BASH_SETUP'
# Prefer /target bash (already installed into the image rootfs). The loader
# must see /target/usr/lib (libreadline, etc.); invoking ld-musl without
# --library-path only searches the helper container's libs.
_atomos_target_libpath="/target/usr/lib:/target/lib"
if [ -x /target/bin/bash ] && [ -x /target/lib/ld-musl-aarch64.so.1 ]; then
    atomos_bash() {
        PATH=/usr/bin:/bin:/usr/sbin:/sbin:/target/usr/bin:/target/bin \
            /target/lib/ld-musl-aarch64.so.1 \
            --library-path "$_atomos_target_libpath" \
            /target/bin/bash "$@"
    }
else
    echo "WARN: /target bash missing; apk-installing helper tools (network)" >&2
    apk update >/dev/null 2>&1 || true
    apk add --no-interactive bash python3 grep sed tar >/dev/null
    atomos_bash() { bash "$@"; }
fi
ATOMOS_OVERLAY_BASH_SETUP
}
