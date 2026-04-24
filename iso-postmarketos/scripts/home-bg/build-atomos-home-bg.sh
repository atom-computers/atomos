#!/bin/bash
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
BIN_PATH="$ROOT_DIR/rust/atomos-home-bg/target/$TARGET_TRIPLE/release/atomos-home-bg"

if [ ! -f "$CRATE_MANIFEST" ]; then
    echo "ERROR: missing home-bg manifest: $CRATE_MANIFEST" >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is required to build atomos-home-bg." >&2
    exit 1
fi

if command -v rustp >/dev/null 2>&1; then
    rustup target add "$TARGET_TRIPLE" >/dev/null 2>&1 || true
fi
u
echo "Building atomos-home-bg ($TARGET_TRIPLE)..."
cargo build \
    --manifest-path "$CRATE_MANIFEST" \
    --release \
    --target "$TARGET_TRIPLE" \
    --bin atomos-home-bg

if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: atomos-home-bg build did not produce binary at: $BIN_PATH" >&2
    exit 1
fi

echo "Built atomos-home-bg: $BIN_PATH"
