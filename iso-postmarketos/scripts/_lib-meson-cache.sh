# shellcheck shell=bash
# scripts/_lib-meson-cache.sh -- meson/ccache incremental cache backend.
#
# Two backends are supported (chosen by MESON_CACHE_HOST_DIR):
#
#   - DEFAULT: a NAMED docker volume (atomos-fp4v2-meson-cache-<profile>).
#     The cache lives inside the engine VM, which sidesteps the macOS
#     bind-mount EPERM cascade documented in build-qemu.sh (colima#911:
#     small-file open via macOS bind mount returns EPERM at random under
#     heavy load like phosh's ar -> 90 .o pass).
#   - OPT-IN HOST DIR: set MESON_CACHE_HOST_DIR=<path> (orchestrator
#     reads ATOMOS_FP4V2_MESON_CACHE_HOST_DIR / ATOMOS_FP4_MESON_CACHE_HOST_DIR).
#
# Required globals at call time:
#   ENGINE                   -- "docker" or "podman"
#   PROFILE_NAME             -- used in the volume name
#   ALPINE_IMAGE             -- container image (for the wipe step)
#   MESON_CACHE_HOST_DIR     -- (optional) host bind-mount path
#
# Exports:
#   MESON_CACHE_VOLUME       -- named volume name
#   MESON_CACHE_MOUNT        -- value to pass to `-v X:/cache`
#   MESON_CACHE_KIND         -- human label ("docker volume: ..." | "host directory: ...")

atomos_meson_cache_select_backend() {
    MESON_CACHE_VOLUME="atomos-fp4v2-meson-cache-${PROFILE_NAME}"
    if [ -n "${MESON_CACHE_HOST_DIR:-}" ]; then
        MESON_CACHE_MOUNT="$MESON_CACHE_HOST_DIR"
        MESON_CACHE_KIND="host directory: $MESON_CACHE_HOST_DIR"
        mkdir -p "$MESON_CACHE_HOST_DIR"
    else
        MESON_CACHE_MOUNT="$MESON_CACHE_VOLUME"
        MESON_CACHE_KIND="docker volume: $MESON_CACHE_VOLUME"
        "$ENGINE" volume create "$MESON_CACHE_VOLUME" >/dev/null
    fi
    export MESON_CACHE_VOLUME MESON_CACHE_MOUNT MESON_CACHE_KIND
}

# Wipe the cache. Use after Alpine image upgrades or when seeing
# stale-link errors. Honors both backends.
atomos_meson_cache_wipe() {
    echo "build-fairphone4-v2: wiping meson cache ($MESON_CACHE_KIND)"
    if [ -n "${MESON_CACHE_HOST_DIR:-}" ] && [ -d "$MESON_CACHE_HOST_DIR" ]; then
        "$ENGINE" run --rm -v "$MESON_CACHE_HOST_DIR:/cache" \
            "$ALPINE_IMAGE" /bin/sh -c 'rm -rf /cache/* /cache/.[!.]* 2>/dev/null || true' \
            >/dev/null 2>&1 || rm -rf "$MESON_CACHE_HOST_DIR"
        mkdir -p "$MESON_CACHE_HOST_DIR"
    elif [ -z "${MESON_CACHE_HOST_DIR:-}" ]; then
        "$ENGINE" volume rm -f "$MESON_CACHE_VOLUME" >/dev/null 2>&1 || true
        "$ENGINE" volume create "$MESON_CACHE_VOLUME" >/dev/null
    fi
}

# One-shot: select + (optionally) wipe + report.
atomos_meson_cache_setup() {
    atomos_meson_cache_select_backend
    if [ "${MESON_CACHE_CLEAN:-0}" = "1" ]; then
        atomos_meson_cache_wipe
    fi
    echo "build-fairphone4-v2: meson cache backend: $MESON_CACHE_KIND"
}
