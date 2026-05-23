#!/bin/bash
# Build atomos-app-handler for an aarch64 musl rootfs.
#
# Auto-picks Linux host cross-build vs. Alpine arm64 container build the
# same way scripts/home-bg/build-atomos-home-bg.sh does:
#
#   Linux host (PMOS rootfs available)
#     -> use host cargo + the pmbootstrap chroot as the cross sysroot
#        (gtk4-dev / wayland-dev / gtk4-layer-shell-dev resolved by
#        cross pkg-config). Binary lands at
#        target/aarch64-unknown-linux-musl/release/atomos-app-handler.
#
#   non-Linux host (macOS dev box, no sysroot)
#     -> delegate to scripts/app-handler/build-app-handler-in-container.sh
#        which runs cargo inside an Alpine arm64 container. Binary lands at
#        target/release/atomos-app-handler (second candidate that the
#        install helper resolve_bin_path() picks up automatically).
#
# Force one path or the other with `ATOMOS_APP_HANDLER_BUILD_MODE=host|container`.
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

TARGET_TRIPLE="${ATOMOS_APP_HANDLER_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"
CRATE_MANIFEST="$CRATE_DIR/app-gtk/Cargo.toml"
HOST_BIN_PATH="$CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-app-handler"
CONTAINER_BIN_PATH="$CRATE_DIR/target/release/atomos-app-handler"

if [ ! -f "$CRATE_MANIFEST" ]; then
    echo "ERROR: missing app-switcher manifest: $CRATE_MANIFEST" >&2
    exit 1
fi

BUILD_MODE="${ATOMOS_APP_HANDLER_BUILD_MODE:-}"
if [ -z "$BUILD_MODE" ]; then
    if [ "$(uname -s)" = "Linux" ]; then
        BUILD_MODE="host"
    else
        BUILD_MODE="container"
    fi
fi

run_host_cross_build() {
    # Cross pkg-config relies on a sysroot directory that supplies
    # gtk4 / wayland / gtk4-layer-shell *-dev pkg-config files. We reuse
    # the home-bg cross-build helper because it already knows how to
    # find a pmbootstrap chroot and export the necessary env. Falls
    # through here whether or not the helper is callable as a function.
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

case "$BUILD_MODE" in
    container)
        echo "Building atomos-app-handler via Alpine arm64 container (host=$(uname -s))..."
        bash "$ROOT_DIR/scripts/app-handler/build-app-handler-in-container.sh"
        if [ ! -x "$CONTAINER_BIN_PATH" ]; then
            echo "ERROR: containerized build did not produce binary at: $CONTAINER_BIN_PATH" >&2
            exit 1
        fi
        echo "Built atomos-app-handler: $CONTAINER_BIN_PATH"
        ;;
    host)
        if run_host_cross_build; then
            if [ ! -x "$HOST_BIN_PATH" ]; then
                echo "ERROR: build reported success but binary missing at: $HOST_BIN_PATH" >&2
                exit 1
            fi
            echo "Built atomos-app-handler: $HOST_BIN_PATH"
        else
            host_rc=$?
            if [ "${ATOMOS_APP_HANDLER_HOST_FALLBACK_TO_CONTAINER:-1}" = "1" ]; then
                echo "WARN: host cross-build for atomos-app-handler failed (rc=$host_rc); falling back to Alpine arm64 container build." >&2
                echo "      Set ATOMOS_APP_HANDLER_HOST_FALLBACK_TO_CONTAINER=0 to disable this fallback." >&2
                bash "$ROOT_DIR/scripts/app-handler/build-app-handler-in-container.sh"
                if [ ! -x "$CONTAINER_BIN_PATH" ]; then
                    echo "ERROR: container fallback build did not produce binary at: $CONTAINER_BIN_PATH" >&2
                    exit 1
                fi
                echo "Built atomos-app-handler (via container fallback): $CONTAINER_BIN_PATH"
            else
                exit "$host_rc"
            fi
        fi
        ;;
    *)
        echo "ERROR: ATOMOS_APP_HANDLER_BUILD_MODE must be 'host' or 'container' (got '$BUILD_MODE')" >&2
        exit 2
        ;;
esac
