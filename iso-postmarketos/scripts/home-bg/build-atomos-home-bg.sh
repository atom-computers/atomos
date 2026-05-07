#!/bin/bash
# Build the atomos-home-bg release binary for an aarch64 musl rootfs.
#
# Two paths, picked automatically by host OS:
#
#   Linux host  → cross-compile via host cargo + rustup target + native
#                 pkg-config. Outputs to
#                 target/$TARGET_TRIPLE/release/atomos-home-bg.
#   non-Linux   → delegate to build-atomos-home-bg-in-container.sh, which
#                 runs cargo inside an Alpine arm64 container so
#                 pkg-config is native. Outputs to
#                 target/release/atomos-home-bg (the second candidate
#                 path that install/hotfix `resolve_bin_path()` checks).
#
# Force one path or the other with `ATOMOS_HOME_BG_BUILD_MODE=host|container`.
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

TARGET_TRIPLE="${ATOMOS_HOME_BG_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
CRATE_MANIFEST="$ROOT_DIR/rust/atomos-home-bg/app-gtk/Cargo.toml"
HOST_BIN_PATH="$ROOT_DIR/rust/atomos-home-bg/target/$TARGET_TRIPLE/release/atomos-home-bg"
CONTAINER_BIN_PATH="$ROOT_DIR/rust/atomos-home-bg/target/release/atomos-home-bg"

if [ ! -f "$CRATE_MANIFEST" ]; then
    echo "ERROR: missing home-bg manifest: $CRATE_MANIFEST" >&2
    exit 1
fi

# Auto-pick build mode unless explicitly overridden. Host cross-compile
# only works on Linux because the gtk-rs / webkit-rs sys crates use
# pkg-config to resolve gtk4 / webkit2gtk-6.0 at build time, and macOS
# pkg-config has no usable Linux sysroot. Containerized build sidesteps
# that.
BUILD_MODE="${ATOMOS_HOME_BG_BUILD_MODE:-}"
if [ -z "$BUILD_MODE" ]; then
    if [ "$(uname -s)" = "Linux" ]; then
        BUILD_MODE="host"
    else
        BUILD_MODE="container"
    fi
fi

case "$BUILD_MODE" in
    container)
        echo "Building atomos-home-bg via Alpine arm64 container (host=$(uname -s))..."
        bash "$ROOT_DIR/scripts/home-bg/build-atomos-home-bg-in-container.sh"
        if [ ! -x "$CONTAINER_BIN_PATH" ]; then
            echo "ERROR: containerized build did not produce binary at: $CONTAINER_BIN_PATH" >&2
            exit 1
        fi
        echo "Built atomos-home-bg: $CONTAINER_BIN_PATH"
        ;;
    host)
        if ! command -v cargo >/dev/null 2>&1; then
            echo "ERROR: cargo is required to build atomos-home-bg." >&2
            exit 1
        fi
        if command -v rustup >/dev/null 2>&1; then
            rustup target add "$TARGET_TRIPLE" >/dev/null 2>&1 || true
        fi

        echo "Building atomos-home-bg ($TARGET_TRIPLE)..."
        cargo build \
            --manifest-path "$CRATE_MANIFEST" \
            --release \
            --target "$TARGET_TRIPLE" \
            --bin atomos-home-bg

        if [ ! -x "$HOST_BIN_PATH" ]; then
            echo "ERROR: atomos-home-bg build did not produce binary at: $HOST_BIN_PATH" >&2
            exit 1
        fi
        echo "Built atomos-home-bg: $HOST_BIN_PATH"
        ;;
    *)
        echo "ERROR: ATOMOS_HOME_BG_BUILD_MODE must be 'host' or 'container' (got '$BUILD_MODE')" >&2
        exit 2
        ;;
esac
