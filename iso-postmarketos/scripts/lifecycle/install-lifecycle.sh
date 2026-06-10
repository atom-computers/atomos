#!/bin/bash
# Install atomos-lifecycle into a rootfs.
#
# Two modes, auto-selected by the presence of `ROOTFS_DIR`:
#
#   pmbootstrap mode   (no ROOTFS_DIR set)
#     Uses scripts/pmb/pmb.sh to chroot into the pmbootstrap-managed rootfs.
#
#   direct mode        (ROOTFS_DIR=/path/to/rootfs)
#     Writes files straight into the given rootfs tree. Used by build-qemu.sh
#     which builds a rootfs in a podman/docker volume.
#
# Both modes install the SAME files:
#   /usr/local/bin/atomos-lifecycle         (binary)
#   /usr/bin/atomos-lifecycle               (symlink)
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: ROOTFS_DIR=/target $0 <profile-env>            # direct mode" >&2
    echo "       $0 <profile-env>                               # pmbootstrap mode" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIRECT_ROOTFS_DIR="${ROOTFS_DIR:-}"

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
SKIP_BINARY_INSTALL="${ATOMOS_LIFECYCLE_SKIP_BINARY_INSTALL:-0}"
REQUIRE_BINARY="${ATOMOS_LIFECYCLE_REQUIRE_BINARY:-1}"

candidate_bin_paths() {
    if [ -n "${ATOMOS_LIFECYCLE_BIN:-}" ]; then
        printf '%s\n' "$ATOMOS_LIFECYCLE_BIN"
    fi
    printf '%s\n' "/cache/cargo-target/aarch64-unknown-linux-musl/release/atomos-lifecycle"
    printf '%s\n' "/cache/cargo-target/release/atomos-lifecycle"
    printf '%s\n' "$ROOT_DIR/rust/atomos-lifecycle/target/aarch64-unknown-linux-musl/release/atomos-lifecycle"
    printf '%s\n' "$ROOT_DIR/rust/atomos-lifecycle/target/release/atomos-lifecycle"
}

resolve_bin_path() {
    local p
    while IFS= read -r p; do
        if [ -x "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done < <(candidate_bin_paths)
    return 1
}

BIN_PATH="$(resolve_bin_path || true)"
if [ -z "$BIN_PATH" ]; then
    if [ "$REQUIRE_BINARY" = "1" ]; then
        echo "ERROR: install-lifecycle: no prebuilt binary found." >&2
        candidate_bin_paths | sed 's/^/  expected: /' >&2
        exit 1
    fi
    echo "install-lifecycle: no prebuilt binary; skipping."
    exit 0
fi

echo "Installing lifecycle binary from: $BIN_PATH"


# ---------- direct rootfs mode ----------
if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    if [ ! -d "$DIRECT_ROOTFS_DIR" ]; then
        echo "ERROR: ROOTFS_DIR not a directory: $DIRECT_ROOTFS_DIR" >&2
        exit 1
    fi
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin" "$DIRECT_ROOTFS_DIR/usr/bin"
    install -m 0755 "$BIN_PATH" "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-lifecycle"
    ln -sf ../local/bin/atomos-lifecycle "$DIRECT_ROOTFS_DIR/usr/bin/atomos-lifecycle"

    test -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-lifecycle"
    test -x "$DIRECT_ROOTFS_DIR/usr/bin/atomos-lifecycle"
    echo "Installed lifecycle into direct rootfs: $DIRECT_ROOTFS_DIR"
    exit 0
fi


# ---------- pmbootstrap chroot mode ----------
PMB="$ROOT_DIR/scripts/pmb/pmb.sh"

INSTALL_DIRS='install -d /usr/local/bin /usr/bin'
INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-lifecycle && chmod 755 /usr/local/bin/atomos-lifecycle && ln -sf ../local/bin/atomos-lifecycle /usr/bin/atomos-lifecycle'

bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"

VERIFY_CMD='test -x /usr/local/bin/atomos-lifecycle && test -x /usr/bin/atomos-lifecycle'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed lifecycle into pmbootstrap rootfs."