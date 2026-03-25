#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
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

PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"
PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_IS_CONTAINER=0
export PATH="$HOME/.local/bin:$PATH"
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB_IS_CONTAINER=1
    PMB="$PMB_CONTAINER"
    if [[ "$PROFILE_ENV_SOURCE" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV_SOURCE#"$ROOT_DIR"/}"
    else
        PROFILE_ENV_ARG="$PROFILE_ENV_SOURCE"
    fi
fi

if [ "${ATOMOS_INSTALL_DUMP_ONLY:-0}" = "1" ]; then
    echo "would-install:btlescan"
    exit 0
fi

RUST_TARGET="aarch64-unknown-linux-musl"
BTLESCAN_ROOT="$REPO_ROOT/.btlescan-install"
BIN_PATH="$BTLESCAN_ROOT/bin/btlescan"

# apk: never block on confirmation prompts (CI / scripts). Only probe when apk exists
# (this script often runs on Debian hosts that use Docker for cargo).
APK_ADD_BASE=(add --no-interactive)
if command -v apk >/dev/null 2>&1 && apk add --help 2>&1 | grep -q -- '--no-cache'; then
    APK_ADD_BASE+=(--no-cache)
fi

export_btlescan_cross_link_env() {
    local sysroot="$1"
    # Dynamic libdbus from Alpine is musl-linked; GNU ld + aarch64-linux-gnu-gcc
    # must not mix glibc resolution with musl DSOs — lld + rpath-link + libm fixes
    # "libc.musl not found", undefined pow, and bad libc for libdbus.
    export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static"
    if command -v ld.lld >/dev/null 2>&1 || command -v ld64.lld >/dev/null 2>&1; then
        export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-fuse-ld=lld"
    fi
    export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${sysroot}/usr/lib"
    export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${sysroot}/lib"
    export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-lm"
    export LIBRARY_PATH="${LIBRARY_PATH:-}${LIBRARY_PATH:+:}${sysroot}/usr/lib:${sysroot}/lib"
}

find_container_engine() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
    else
        echo ""
    fi
}

ensure_alpine_build_deps() {
    if ! command -v apk >/dev/null 2>&1; then
        return 0
    fi
    local deps missing dep
    deps=(curl git build-base linux-headers cmake dbus-dev pkgconf openssl-dev)
    missing=()
    for dep in "${deps[@]}"; do
        if ! apk info -e "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        return 0
    fi
    echo "Installing missing Alpine build deps: ${missing[*]}"
    if [ "$(id -u)" -eq 0 ]; then
        apk "${APK_ADD_BASE[@]}" "${missing[@]}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo apk "${APK_ADD_BASE[@]}" "${missing[@]}"
    else
        echo "ERROR: missing Alpine deps and no sudo available: ${missing[*]}" >&2
        exit 1
    fi
}

setup_cross_pkg_config_env() {
    local sysroot=""
    export PKG_CONFIG_ALLOW_CROSS=1
    export TARGET_PKG_CONFIG_ALLOW_CROSS=1
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${PROFILE_NAME:-}" ]; then
        if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
            sysroot="${PMB_WORK_OVERRIDE}/chroot_rootfs_${PROFILE_NAME}"
        else
            sysroot="$ROOT_DIR/${PMB_WORK_OVERRIDE}/chroot_rootfs_${PROFILE_NAME}"
        fi
    fi

    if [ -n "$sysroot" ] && [ -d "$sysroot/usr/lib/pkgconfig" ]; then
        export PKG_CONFIG_SYSROOT_DIR="$sysroot"
        export PKG_CONFIG_PATH="$sysroot/usr/lib/pkgconfig:$sysroot/usr/share/pkgconfig"
        export PKG_CONFIG_LIBDIR="$sysroot/usr/lib/pkgconfig:$sysroot/usr/share/pkgconfig"
        echo "Using cross pkg-config sysroot: $sysroot"
    else
        echo "WARNING: cross pkg-config sysroot not found at expected path." >&2
        echo "  Expected: $sysroot/usr/lib/pkgconfig" >&2
        echo "  Cross builds may fail resolving dbus-1 for btlescan." >&2
    fi
}

ensure_target_dbus_pkgconfig() {
    local sysroot=""
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${PROFILE_NAME:-}" ]; then
        if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
            sysroot="${PMB_WORK_OVERRIDE}/chroot_rootfs_${PROFILE_NAME}"
        else
            sysroot="$ROOT_DIR/${PMB_WORK_OVERRIDE}/chroot_rootfs_${PROFILE_NAME}"
        fi
    fi
    # Need both: dbus (libdbus-1.so) and dbus-dev (dbus-1.pc). Early exit only
    # when .pc exists AND a linkable libdbus is present.
    if [ -n "$sysroot" ] && [ -f "$sysroot/usr/lib/pkgconfig/dbus-1.pc" ]; then
        if compgen -G "$sysroot/usr/lib/libdbus-1.so"* >/dev/null 2>&1; then
            return 0
        fi
    fi

    echo "Ensuring target rootfs has dbus + dbus-dev (pkg-config + libdbus-1)..."
    # Runs inside Alpine chroot; --no-interactive avoids "Proceed? [y/N]" prompts.
    local install_cmd='apk add --no-interactive --quiet dbus dbus-dev pkgconf 2>/dev/null || apk add --no-interactive dbus dbus-dev pkgconf'
    if [ "$PMB_IS_CONTAINER" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$install_cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$install_cmd"
    fi
}

build_btlescan() {
    mkdir -p "$BTLESCAN_ROOT"
    ensure_target_dbus_pkgconfig
    if command -v cargo >/dev/null 2>&1; then
        ensure_alpine_build_deps
        if command -v rustup >/dev/null 2>&1; then
            rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
        fi
        setup_cross_pkg_config_env
        if [ -n "${PKG_CONFIG_SYSROOT_DIR:-}" ]; then
            export_btlescan_cross_link_env "$PKG_CONFIG_SYSROOT_DIR"
        else
            export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static"
        fi
        echo "Installing btlescan via cargo (target: $RUST_TARGET)..."
        cargo install --locked --force --target "$RUST_TARGET" --root "$BTLESCAN_ROOT" btlescan
        return 0
    fi

    ENGINE="$(find_container_engine)"
    if [ -z "$ENGINE" ]; then
        echo "ERROR: cargo not found and no accessible docker/podman engine for btlescan build." >&2
        exit 1
    fi

    IMAGE_TAG="${ATOMOS_RUST_BUILDER_IMAGE:-${ATOMOS_BUILDER_IMAGE:-${PMB_CONTAINER_IMAGE:-atomos-pmbootstrap:latest}}}"
    BUILDER_DOCKERFILE="${ATOMOS_RUST_BUILDER_DOCKERFILE:-${ATOMOS_BUILDER_DOCKERFILE:-$ROOT_DIR/docker/pmbootstrap.Dockerfile}}"
    echo "Building Rust container image for btlescan..."
    "$ENGINE" build -t "$IMAGE_TAG" -f "$BUILDER_DOCKERFILE" "$ROOT_DIR/docker"

    echo "Installing btlescan in container (target: $RUST_TARGET)..."
    CONTAINER_RUN_ARGS=()
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [[ "$PMB_WORK_OVERRIDE" = /* ]] && [ -d "$PMB_WORK_OVERRIDE" ]; then
        CONTAINER_RUN_ARGS+=(-v "$PMB_WORK_OVERRIDE:$PMB_WORK_OVERRIDE:ro")
    fi
    "$ENGINE" run --rm \
        -e PMB_WORK_OVERRIDE="${PMB_WORK_OVERRIDE:-}" \
        -e PROFILE_NAME="${PROFILE_NAME:-}" \
        -e PKG_CONFIG_ALLOW_CROSS=1 \
        -e TARGET_PKG_CONFIG_ALLOW_CROSS=1 \
        -v "$REPO_ROOT":/work \
        "${CONTAINER_RUN_ARGS[@]}" \
        -w /work \
        "$IMAGE_TAG" \
        bash -lc '
set -euo pipefail
if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${PROFILE_NAME:-}" ]; then
    if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
        SYSROOT="${PMB_WORK_OVERRIDE}/chroot_rootfs_${PROFILE_NAME}"
    else
        SYSROOT="/work/${PMB_WORK_OVERRIDE}/chroot_rootfs_${PROFILE_NAME}"
    fi
    if [ -d "$SYSROOT/usr/lib/pkgconfig" ]; then
        export PKG_CONFIG_ALLOW_CROSS=1
        export TARGET_PKG_CONFIG_ALLOW_CROSS=1
        export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
        export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
        export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
        export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static"
        if command -v ld.lld >/dev/null 2>&1 || command -v ld64.lld >/dev/null 2>&1; then
            export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-fuse-ld=lld"
        fi
        export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${SYSROOT}/usr/lib"
        export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${SYSROOT}/lib"
        export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-lm"
        export LIBRARY_PATH="${LIBRARY_PATH:-}${LIBRARY_PATH:+:}${SYSROOT}/usr/lib:${SYSROOT}/lib"
        echo "Using cross pkg-config sysroot: $SYSROOT"
    else
        echo "ERROR: cross sysroot for btlescan not found in container: $SYSROOT" >&2
        exit 1
    fi
fi
cargo install --locked --force --target "'"$RUST_TARGET"'" --root "/work/.btlescan-install" btlescan
'
}

build_btlescan

if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: btlescan binary not found after build: $BIN_PATH" >&2
    exit 1
fi

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    echo "Installing btlescan into direct rootfs dir..."
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin"
    install -m 0755 "$BIN_PATH" "$DIRECT_ROOTFS_DIR/usr/local/bin/btlescan"
    ln -sf /usr/local/bin/btlescan "$DIRECT_ROOTFS_DIR/usr/bin/btlescan"
    exit 0
fi

INSTALL_CMD='cat > /usr/local/bin/btlescan && chmod +x /usr/local/bin/btlescan && ln -sf /usr/local/bin/btlescan /usr/bin/btlescan'
echo "Installing btlescan into pmbootstrap rootfs..."
if [ "$PMB_IS_CONTAINER" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INSTALL_CMD" < "$BIN_PATH"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INSTALL_CMD" < "$BIN_PATH"
fi

VERIFY_CMD='test -x /usr/local/bin/btlescan'
if [ "$PMB_IS_CONTAINER" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"
fi

echo "Installed btlescan at /usr/local/bin/btlescan."
