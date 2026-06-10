#!/bin/bash
# Build atomos-lifecycle for an aarch64 musl rootfs.
#
# The lifecycle daemon has no GTK dependencies but uses wayland-client for
# the optional persistent daemon mode (toplevel tracking via
# zwlr_foreign_toplevel_manager_v1).
# Supports both a cross-compilation host toolchain and a container build.
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

TARGET_TRIPLE="${ATOMOS_LIFECYCLE_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
CRATE_DIR="$ROOT_DIR/rust/atomos-lifecycle"
CRATE_MANIFEST="$CRATE_DIR/Cargo.toml"

if [ ! -f "$CRATE_MANIFEST" ]; then
    echo "ERROR: missing lifecycle manifest: $CRATE_MANIFEST" >&2
    exit 1
fi

echo "=== Building atomos-lifecycle ($TARGET_TRIPLE) ==="

if [ -f "$ROOT_DIR/scripts/pmb/pmb.sh" ] && [ "$(uname -s)" = "Linux" ]; then
    echo "Lifecycle: trying host cross-build with musl target"
    if command -v cargo >/dev/null 2>&1 && \
       rustup target list --installed 2>/dev/null | grep -q "$TARGET_TRIPLE"; then
        echo "Lifecycle: cargo + musl target available, building on host"
        (cd "$CRATE_DIR" && cargo build --release --target "$TARGET_TRIPLE" --features daemon --bin atomos-lifecycle)
        echo "Lifecycle: binary at $CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-lifecycle"
    else
        echo "Lifecycle: no musl target on host, trying container build"
        if [ -f "$ROOT_DIR/scripts/lifecycle/build-lifecycle-in-container.sh" ]; then
            bash "$ROOT_DIR/scripts/lifecycle/build-lifecycle-in-container.sh" "$PROFILE_ENV_SOURCE"
        else
            echo "ERROR: no container build script found" >&2
            exit 1
        fi
    fi
else
    echo "Lifecycle: non-Linux host, building natively (no cross-compilation)"
    (cd "$CRATE_DIR" && cargo build --release --features daemon --bin atomos-lifecycle)
    echo "Lifecycle: binary at $CRATE_DIR/target/release/atomos-lifecycle"
fi