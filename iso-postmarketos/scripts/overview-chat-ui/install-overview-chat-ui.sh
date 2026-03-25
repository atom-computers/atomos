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

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
BIN_PATH="$ROOT_DIR/rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui"

if [ ! -x "$BIN_PATH" ]; then
    echo "install-overview-chat-ui: no prebuilt binary found; skip install"
    echo "  expected: $BIN_PATH"
    exit 0
fi

echo "Installing overview chat UI binary from: $BIN_PATH"
INSTALL_CMD='cat > /usr/local/bin/atomos-overview-chat-ui && chmod +x /usr/local/bin/atomos-overview-chat-ui && ln -sf /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui'
bash "$PMB" "$PROFILE_ENV" chroot -r -- /bin/sh -eu -c "$INSTALL_CMD" < "$BIN_PATH"

VERIFY_CMD='test -x /usr/local/bin/atomos-overview-chat-ui && test -x /usr/bin/atomos-overview-chat-ui'
bash "$PMB" "$PROFILE_ENV" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed overview chat UI binary."
