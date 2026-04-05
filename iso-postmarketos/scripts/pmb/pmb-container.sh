#!/bin/bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <profile-env> <pmbootstrap args...>" >&2
    exit 1
fi

PROFILE_ENV="$1"
shift

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE_TAG="${PMB_CONTAINER_IMAGE:-atomos-pmbootstrap:latest}"
HOST_HOME_DIR="${PMB_CONTAINER_HOME_DIR:-$ROOT_DIR/.pmbootstrap-container-home}"
CONTAINER_HOME_DIR="/pmbootstrap-home"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ENGINE="docker"
elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    echo "Docker is installed but not accessible (permission denied on docker.sock)." >&2
    echo "Use one of:" >&2
    echo "  - sudo usermod -aG docker \$USER  (then re-login)" >&2
    echo "  - run with sudo" >&2
    echo "  - install/use podman and rerun" >&2
    exit 1
elif command -v podman >/dev/null 2>&1; then
    echo "Podman is installed but not accessible to this user." >&2
    exit 1
else
    echo "Neither docker nor podman is available." >&2
    exit 1
fi

"$ENGINE" build -t "$IMAGE_TAG" -f "$ROOT_DIR/docker/pmbootstrap.Dockerfile" "$ROOT_DIR/docker" >/dev/null
mkdir -p "$HOST_HOME_DIR"
WORK_MOUNT_ARGS=()
if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [[ "$PMB_WORK_OVERRIDE" = /* ]] && [ -d "$PMB_WORK_OVERRIDE" ]; then
    WORK_MOUNT_ARGS+=(-v "$PMB_WORK_OVERRIDE:$PMB_WORK_OVERRIDE")
fi

if [ "${PMB_CONTAINER_AS_ROOT:-0}" = "1" ]; then
    exec "$ENGINE" run --rm -i \
        --privileged \
        -v "$ROOT_DIR":/work \
        -v "$HOST_HOME_DIR":"$CONTAINER_HOME_DIR" \
        "${WORK_MOUNT_ARGS[@]}" \
        -w /work \
        -e HOME="$CONTAINER_HOME_DIR" \
        -e PMB_WORK_OVERRIDE="${PMB_WORK_OVERRIDE:-}" \
        -e GIT_CONFIG_COUNT=1 \
        -e GIT_CONFIG_KEY_0=safe.directory \
        -e GIT_CONFIG_VALUE_0="$CONTAINER_HOME_DIR/.local/var/pmbootstrap/cache_git/pmaports" \
        -e PMB_BIN=pmbootstrap \
        "$IMAGE_TAG" \
        bash scripts/pmb/pmb-container-root-entry.sh "$PROFILE_ENV" --as-root "$@"
else
    if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
        UID_GID="${SUDO_UID}:${SUDO_GID}"
    else
        UID_GID="$(id -u):$(id -g)"
    fi
    exec "$ENGINE" run --rm -i \
        --privileged \
        --user "$UID_GID" \
        -v "$ROOT_DIR":/work \
        -v "$HOST_HOME_DIR":"$CONTAINER_HOME_DIR" \
        "${WORK_MOUNT_ARGS[@]}" \
        -w /work \
        -e HOME="$CONTAINER_HOME_DIR" \
        -e PMB_WORK_OVERRIDE="${PMB_WORK_OVERRIDE:-}" \
        -e GIT_CONFIG_COUNT=1 \
        -e GIT_CONFIG_KEY_0=safe.directory \
        -e GIT_CONFIG_VALUE_0="$CONTAINER_HOME_DIR/.local/var/pmbootstrap/cache_git/pmaports" \
        -e PMB_BIN=pmbootstrap \
        "$IMAGE_TAG" \
        bash scripts/pmb/pmb.sh "$PROFILE_ENV" "$@"
fi
