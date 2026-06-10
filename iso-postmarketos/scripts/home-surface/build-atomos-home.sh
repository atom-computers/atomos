#!/bin/bash
# Build atomos-home for an aarch64 musl rootfs.
#
# atomos-home is a GTK4 layer-shell binary (replaces PhoshHome).
# It depends on gtk4, gtk4-layer-shell, wayland-client, and zbus,
# so it uses the same cross-build infrastructure as atomos-app-handler.
#
# Modes:
#   host      — Linux host with cargo + musl target + cross pkg-config via pmbootstrap
#   container — Alpine arm64 container with full GTK4 sysroot
#
# Force one path: ATOMOS_HOME_BUILD_MODE=host|container
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

TARGET_TRIPLE="${ATOMOS_HOME_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
CRATE_DIR="$ROOT_DIR/rust/atomos-home"
CRATE_MANIFEST="$CRATE_DIR/app-gtk/Cargo.toml"
HOST_BIN_PATH="$CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-home"
CONTAINER_BIN_PATH="$CRATE_DIR/target/release/atomos-home"

if [ ! -f "$CRATE_MANIFEST" ]; then
    echo "ERROR: missing atomos-home manifest: $CRATE_MANIFEST" >&2
    exit 1
fi

BUILD_MODE="${ATOMOS_HOME_BUILD_MODE:-}"
if [ -z "$BUILD_MODE" ]; then
    if [ "$(uname -s)" = "Linux" ]; then
        BUILD_MODE="host"
    else
        BUILD_MODE="container"
    fi
fi

run_host_cross_build() {
    local helper="$ROOT_DIR/scripts/home-bg/_lib-cross-build.sh"
    if [ ! -f "$helper" ]; then
        echo "ERROR: host cross-build helper not found: $helper" >&2
        return 2
    fi
    # shellcheck source=/dev/null
    source "$helper"
    if ! type home_bg_run_cross_cargo_build >/dev/null 2>&1; then
        echo "ERROR: home_bg_run_cross_cargo_build helper not exported from $helper" >&2
        return 2
    fi
    home_bg_run_cross_cargo_build "$PROFILE_ENV_SOURCE" "$CRATE_MANIFEST" "$TARGET_TRIPLE" "$ROOT_DIR"
}

run_container_build() {
    local container_script="$ROOT_DIR/scripts/home-surface/build-atomos-home-in-container.sh"
    if [ ! -f "$container_script" ]; then
        echo "ERROR: container build script not found: $container_script" >&2
        return 1
    fi
    bash "$container_script"
}

case "$BUILD_MODE" in
    container)
        echo "Building atomos-home via Alpine arm64 container (host=$(uname -s))..."
        run_container_build
        if [ ! -x "$CONTAINER_BIN_PATH" ]; then
            echo "ERROR: containerized build did not produce binary at: $CONTAINER_BIN_PATH" >&2
            exit 1
        fi
        echo "Built atomos-home: $CONTAINER_BIN_PATH"
        ;;
    host)
        if run_host_cross_build; then
            if [ ! -x "$HOST_BIN_PATH" ]; then
                echo "ERROR: build reported success but binary missing at: $HOST_BIN_PATH" >&2
                exit 1
            fi
            echo "Built atomos-home: $HOST_BIN_PATH"
        else
            host_rc=$?
            if [ "${ATOMOS_HOME_HOST_FALLBACK_TO_CONTAINER:-1}" = "1" ]; then
                echo "WARN: host cross-build for atomos-home failed (rc=$host_rc); falling back to Alpine arm64 container build." >&2
                run_container_build
                if [ ! -x "$CONTAINER_BIN_PATH" ]; then
                    echo "ERROR: container fallback build did not produce binary at: $CONTAINER_BIN_PATH" >&2
                    exit 1
                fi
                echo "Built atomos-home (via container fallback): $CONTAINER_BIN_PATH"
            else
                exit "$host_rc"
            fi
        fi
        ;;
    *)
        echo "ERROR: ATOMOS_HOME_BUILD_MODE must be 'host' or 'container' (got '$BUILD_MODE')" >&2
        exit 2
        ;;
esac