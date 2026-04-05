#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
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
ROOTFS_CHROOT_NAME="${PMOS_DEVICE:-$PROFILE_NAME}"

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
# Keep the cross-install tree inside iso-postmarketos (matches docker -v "$ROOT_DIR":/work).
BTLESCAN_ROOT="$ROOT_DIR/.btlescan-install"
BIN_PATH="$BTLESCAN_ROOT/bin/btlescan"

# apk: never block on confirmation prompts (CI / scripts). Only probe when apk exists
# (this script often runs on Debian hosts that use Docker for cargo).
APK_ADD_BASE=(add --no-interactive)
if command -v apk >/dev/null 2>&1 && apk add --help 2>&1 | grep -q -- '--no-cache'; then
    APK_ADD_BASE+=(--no-cache)
fi

export_btlescan_cross_link_env() {
    local sysroot="$1"
    # Apply flags to the MUSL target only. Global LIBRARY_PATH/RUSTFLAGS can leak
    # into host build scripts (proc-macro/build.rs) and break host linking.
    local target_rustflags="-C target-feature=-crt-static"
    if command -v ld.lld >/dev/null 2>&1 || command -v ld64.lld >/dev/null 2>&1; then
        target_rustflags="${target_rustflags} -C link-arg=-fuse-ld=lld"
    fi
    target_rustflags="${target_rustflags} -C link-arg=--sysroot=${sysroot}"
    target_rustflags="${target_rustflags} -C link-arg=-Wl,-rpath-link,${sysroot}/usr/lib"
    target_rustflags="${target_rustflags} -C link-arg=-Wl,-rpath-link,${sysroot}/lib"
    target_rustflags="${target_rustflags} -C link-arg=-lm"
    export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="$target_rustflags"
    unset LIBRARY_PATH || true
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
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${ROOTFS_CHROOT_NAME:-}" ]; then
        if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
            sysroot="${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
        else
            sysroot="$ROOT_DIR/${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
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
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${ROOTFS_CHROOT_NAME:-}" ]; then
        if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
            sysroot="${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
        else
            sysroot="$ROOT_DIR/${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
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
    local use_host_cargo=1
    # In containerized pmbootstrap flows, host cargo can be too old for upstream
    # lockfile formats (e.g. lock v4). Prefer reproducible container builds.
    if [ "${PMB_USE_CONTAINER:-0}" = "1" ] && [ "${ATOMOS_BTLESCAN_ALLOW_HOST_CARGO_IN_CONTAINER_MODE:-0}" != "1" ]; then
        use_host_cargo=0
    fi
    # On Debian/Ubuntu hosts, host-side cross links can pick glibc aarch64 libs
    # (e.g. /lib/aarch64-linux-gnu) instead of the pmOS musl sysroot.
    # Prefer the dedicated container path there.
    if ! command -v apk >/dev/null 2>&1; then
        use_host_cargo=0
    fi
    if [ "$use_host_cargo" = "1" ] && command -v cargo >/dev/null 2>&1; then
        ensure_alpine_build_deps
        if command -v rustup >/dev/null 2>&1; then
            rustup target add "$RUST_TARGET" >/dev/null 2>&1 || true
        fi
        setup_cross_pkg_config_env
        if [ -n "${PKG_CONFIG_SYSROOT_DIR:-}" ]; then
            export_btlescan_cross_link_env "$PKG_CONFIG_SYSROOT_DIR"
        else
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=-crt-static"
            unset LIBRARY_PATH || true
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
        -e ROOTFS_CHROOT_NAME="${ROOTFS_CHROOT_NAME:-}" \
        -e PROFILE_NAME="${PROFILE_NAME:-}" \
        -e PKG_CONFIG_ALLOW_CROSS=1 \
        -e TARGET_PKG_CONFIG_ALLOW_CROSS=1 \
        -e CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS:-}" \
        -v "$ROOT_DIR":/work \
        "${CONTAINER_RUN_ARGS[@]}" \
        -w /work \
        "$IMAGE_TAG" \
        bash -lc '
set -euo pipefail
if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${ROOTFS_CHROOT_NAME:-}" ]; then
    if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
        SYSROOT="${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
    else
        SYSROOT="/work/${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
    fi
    if [ -d "$SYSROOT/usr/lib/pkgconfig" ]; then
        export PKG_CONFIG_ALLOW_CROSS=1
        export TARGET_PKG_CONFIG_ALLOW_CROSS=1
        export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
        export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
        export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
        target_rustflags="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS:- -C target-feature=-crt-static}"
        if command -v ld.lld >/dev/null 2>&1 || command -v ld64.lld >/dev/null 2>&1; then
            target_rustflags="${target_rustflags} -C link-arg=-fuse-ld=lld"
        fi
        target_rustflags="${target_rustflags} -C link-arg=--sysroot=${SYSROOT}"
        target_rustflags="${target_rustflags} -C link-arg=-Wl,-rpath-link,${SYSROOT}/usr/lib"
        target_rustflags="${target_rustflags} -C link-arg=-Wl,-rpath-link,${SYSROOT}/lib"
        target_rustflags="${target_rustflags} -C link-arg=-lm"
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="${target_rustflags}"
        unset LIBRARY_PATH || true
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

# Fallback: if host-side cross toolchain emitted a glibc-linked binary, retry
# using a dedicated musl cross container image.
rebuild_btlescan_with_musl_container() {
    local engine image
    engine="$(find_container_engine)"
    if [ -z "$engine" ]; then
        echo "ERROR: cannot attempt musl fallback rebuild (no docker/podman)." >&2
        return 1
    fi

    image="${ATOMOS_MUSL_CROSS_IMAGE:-messense/rust-musl-cross:aarch64-musl}"
    echo "Rebuilding btlescan with musl cross image: $image"
    "$engine" run --rm \
        -v "$ROOT_DIR":/work \
        -w /work \
        "$image" \
        sh -lc '
set -eu
if ! command -v pkg-config >/dev/null 2>&1; then
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache pkgconf dbus-dev >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pkg-config libdbus-1-dev >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y pkgconf-pkg-config dbus-devel >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y pkgconfig dbus-devel >/dev/null
    fi
fi

# Some distros ship pkgconf without the pkg-config symlink.
if ! command -v pkg-config >/dev/null 2>&1 && command -v pkgconf >/dev/null 2>&1; then
    ln -sf "$(command -v pkgconf)" /usr/local/bin/pkg-config || true
fi

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "ERROR: pkg-config is unavailable inside musl fallback container." >&2
    exit 1
fi

export PKG_CONFIG_ALLOW_CROSS=1
export TARGET_PKG_CONFIG_ALLOW_CROSS=1
# rust-musl-cross images usually expect target pkg-config files in /usr/local/musl.
# If dbus-1.pc is absent there, libdbus-sys cannot build for aarch64-musl.
pc_dirs=""
for d in \
    /usr/local/musl/aarch64-unknown-linux-musl/lib/pkgconfig \
    /usr/local/musl/lib/pkgconfig \
    /usr/aarch64-linux-musl/lib/pkgconfig \
    /usr/lib/aarch64-linux-musl/pkgconfig
do
    if [ -d "$d" ]; then
        if [ -n "$pc_dirs" ]; then
            pc_dirs="${pc_dirs}:$d"
        else
            pc_dirs="$d"
        fi
    fi
done
if [ -n "$pc_dirs" ]; then
    export PKG_CONFIG_PATH="$pc_dirs"
    export PKG_CONFIG_LIBDIR="$pc_dirs"
fi

if ! pkg-config --exists "dbus-1 >= 1.6"; then
    echo "WARN: musl fallback skipped (dbus-1.pc not found in musl sysroot pkg-config paths)." >&2
    echo "WARN: keeping glibc-linked btlescan and relying on gcompat runtime in target rootfs." >&2
    exit 2
fi

cargo install --locked --force --target aarch64-unknown-linux-musl --root /work/.btlescan-install btlescan
'
}

ensure_glibc_compat_runtime() {
    local cmd='apk add --no-interactive --quiet gcompat libstdc++ 2>/dev/null || apk add --no-interactive gcompat libstdc++'
    echo "Installing glibc compatibility runtime in target rootfs (gcompat + libstdc++)..."
    if [ "$PMB_IS_CONTAINER" = "1" ]; then
        PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$cmd"
    else
        bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$cmd"
    fi
}

# Guard against accidentally installing a glibc-linked aarch64 binary.
# On postmarketOS (musl), this usually surfaces as "/usr/bin/btlescan: not found"
# even when the file exists.
if command -v file >/dev/null 2>&1; then
    NEED_GCOMPAT=0
    BIN_META="$(file "$BIN_PATH" || true)"
    echo "btlescan build artifact: $BIN_META"
    if [[ "$BIN_META" != *"ARM aarch64"* ]]; then
        echo "ERROR: btlescan binary is not an aarch64 artifact: $BIN_PATH" >&2
        exit 1
    fi
    if [[ "$BIN_META" == *"/lib/ld-linux-aarch64.so.1"* ]]; then
        echo "WARN: btlescan is glibc-linked; attempting musl fallback rebuild..." >&2
        if rebuild_btlescan_with_musl_container; then
            BIN_META="$(file "$BIN_PATH" || true)"
            echo "btlescan fallback artifact: $BIN_META"
            if [[ "$BIN_META" == *"/lib/ld-linux-aarch64.so.1"* ]]; then
                echo "WARN: btlescan remains glibc-linked after fallback rebuild; will install glibc compatibility runtime." >&2
                NEED_GCOMPAT=1
            fi
        else
            echo "WARN: musl fallback rebuild failed; will use glibc-linked artifact with compatibility runtime." >&2
            NEED_GCOMPAT=1
        fi
    fi
fi

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    if [ "${NEED_GCOMPAT:-0}" = "1" ]; then
        echo "WARN: btlescan is glibc-linked. Install gcompat + libstdc++ in target image for runtime compatibility." >&2
    fi
    echo "Installing btlescan into direct rootfs dir..."
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin"
    install -m 0755 "$BIN_PATH" "$DIRECT_ROOTFS_DIR/usr/local/bin/btlescan"
    ln -sf /usr/local/bin/btlescan "$DIRECT_ROOTFS_DIR/usr/bin/btlescan"
    exit 0
fi

# Ensure parents exist (some minimal rootfs trees omit /usr/local/bin until created).
INSTALL_CMD='install -d /usr/local/bin && cat > /usr/local/bin/btlescan && chmod 755 /usr/local/bin/btlescan && ln -sf /usr/local/bin/btlescan /usr/bin/btlescan'
echo "Installing btlescan into pmbootstrap rootfs..."
if [ "$PMB_IS_CONTAINER" = "1" ]; then
    if [ "${NEED_GCOMPAT:-0}" = "1" ]; then
        ensure_glibc_compat_runtime
    fi
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INSTALL_CMD" < "$BIN_PATH"
else
    if [ "${NEED_GCOMPAT:-0}" = "1" ]; then
        ensure_glibc_compat_runtime
    fi
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INSTALL_CMD" < "$BIN_PATH"
fi

# -s catches empty/corrupt payloads (e.g. stdin not forwarded); -x alone is insufficient.
VERIFY_CMD='test -s /usr/local/bin/btlescan && test -x /usr/local/bin/btlescan && test -x /usr/bin/btlescan'
if [ "$PMB_IS_CONTAINER" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"
fi

echo "Installed btlescan at /usr/local/bin/btlescan."
