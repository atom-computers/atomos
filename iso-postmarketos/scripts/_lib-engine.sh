# shellcheck shell=bash
# scripts/_lib-engine.sh -- thin wrappers around `docker run` / `podman run`
# for the AtomOS aarch64 build pipeline.
#
# Why this file exists: build-qemu.sh and build-fairphone4.sh repeat the
# same set of `--platform linux/arm64`, `--ulimit nofile`, `-v` mount
# arguments dozens of times. Centralising them here means the per-step
# call sites in build-fairphone4-v2.sh shrink to one line and the
# argument set is changed in exactly one place when (e.g.) a new ulimit
# tweak is needed.
#
# This file is meant to be SOURCED, not executed. All functions are
# `atomos_*`-prefixed.
#
# Required globals at call time (set by the orchestrator):
#   ENGINE          -- "docker" or "podman" (from atomos_find_container_engine)
#   ALPINE_IMAGE    -- container image name (alpine:edge by default)
#   ROOTFS_VOLUME   -- name of the rootfs volume to bind at /target
#
# All functions accept the body as a final positional arg (a /bin/sh -c
# string). Use single-quoted bodies in callers to avoid premature
# expansion; pass dynamic values via -e env vars.

# atomos_engine_run_arm64 ENVS_OR_VOLS... -- BODY
#   Run a non-privileged aarch64 container with /target bound from
#   ROOTFS_VOLUME. Anything before the literal `--` argument is appended
#   verbatim to the docker/podman argument list (use for additional
#   `-v` / `-e` flags). The final argument is the shell body.
#
# Example:
#   atomos_engine_run_arm64 \
#       -v "$ROOT_DIR:/iso:ro" \
#       -e PROFILE_NAME="$PROFILE_NAME" \
#       -- '
#         echo "hello from $PROFILE_NAME"
#       '
atomos_engine_run_arm64() {
    local body="${!#}"
    local -a extra=()
    local arg
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            shift "$#"
            break
        fi
        extra+=("$arg")
        shift
    done
    # If `--` was not provided, drop the trailing body (already captured
    # in $body) so we don't pass it as a docker flag.
    if [ "${#extra[@]}" -gt 0 ] && [ "${extra[-1]}" = "$body" ]; then
        unset 'extra[-1]'
    fi
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        "${extra[@]}" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$body"
}

# atomos_engine_run_arm64_priv ENVS_OR_VOLS... -- BODY
#   Same as atomos_engine_run_arm64 but with `--privileged` and the
#   nofile ulimit bump. Use this for stages that need loop devices,
#   bind-mounting /proc into a chroot, or that hit the colima EPERM
#   cascade documented in build-qemu.sh (small-file open via macOS bind
#   mount returns EPERM once the container's default nofile=1024 is
#   exceeded).
atomos_engine_run_arm64_priv() {
    local body="${!#}"
    local -a extra=()
    local arg
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            shift "$#"
            break
        fi
        extra+=("$arg")
        shift
    done
    if [ "${#extra[@]}" -gt 0 ] && [ "${extra[-1]}" = "$body" ]; then
        unset 'extra[-1]'
    fi
    "$ENGINE" run --rm --privileged --platform "linux/arm64" \
        --ulimit nofile=65536:65536 \
        -v "$ROOTFS_VOLUME:/target" \
        "${extra[@]}" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$body"
}

# atomos_engine_run_heavy ENVS_OR_VOLS... -- BODY
#   Like atomos_engine_run_arm64 but with the meson cache mount and the
#   nofile ulimit bump. This is the variant used for the long compile
#   stage (gmobile / phosh / phoc / cargo).
atomos_engine_run_heavy() {
    local body="${!#}"
    local -a extra=()
    local arg
    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            shift "$#"
            break
        fi
        extra+=("$arg")
        shift
    done
    if [ "${#extra[@]}" -gt 0 ] && [ "${extra[-1]}" = "$body" ]; then
        unset 'extra[-1]'
    fi
    "$ENGINE" run --rm --platform "linux/arm64" \
        --ulimit nofile=65536:65536 \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$REPO_TOP:/work" \
        -v "$MESON_CACHE_MOUNT:/cache" \
        "${extra[@]}" \
        "$ALPINE_IMAGE" /bin/sh -c "$body"
}
