#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/.." && pwd)"
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

export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

CRATE_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"
TARGET_TRIPLE="aarch64-unknown-linux-musl"
PKGCONF_TRIPLE="aarch64-linux-musl"
BIN_PATH="$CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-overview-chat-ui"
PMB="$ROOT_DIR/scripts/pmb/pmb.sh"

pmb() {
    bash "$PMB" "$PROFILE_ENV" "$@"
}

# Same layout as scripts/pmb/pmb.sh: relative PMB_WORK is under iso-postmarketos.
abs_pmb_work() {
    local work="$1"
    if [[ "$work" = /* ]]; then
        printf '%s\n' "$work"
    else
        printf '%s/%s\n' "$ROOT_DIR" "$work"
    fi
}

# build-image.sh uses PMB_WORK_OVERRIDE=$HOME/.atomos-pmbootstrap-work/$PROFILE_NAME, while
# config/*.env often set PMB_WORK=.pmbootstrap/<profile>. Standalone builds must try both.
base_home_effective() {
    if [ -n "${SUDO_USER:-}" ] && command -v getent >/dev/null 2>&1; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        printf '%s\n' "$HOME"
    fi
}

resolve_sysroot() {
    local atomos_home work_base s
    atomos_home="$(base_home_effective)"
    for work_base in \
        ${PMB_WORK_OVERRIDE:+"$(abs_pmb_work "$PMB_WORK_OVERRIDE")"} \
        ${PMB_WORK:+"$(abs_pmb_work "$PMB_WORK")"} \
        "${atomos_home}/.atomos-pmbootstrap-work/${PROFILE_NAME}"; do
        [ -n "$work_base" ] || continue
        s="${work_base}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
        if [ -d "$s" ]; then
            printf '%s\n' "$s"
            return 0
        fi
    done
    return 1
}

SYSROOT="$(resolve_sysroot || true)"
if [ -z "$SYSROOT" ] || [ ! -d "$SYSROOT" ]; then
    atomos_home="$(base_home_effective)"
    echo "ERROR: unable to locate rootfs sysroot for cross-build." >&2
    echo "  Need: <pmb-work>/chroot_rootfs_${ROOTFS_CHROOT_NAME} (run pmbootstrap install or make build first)." >&2
    echo "  Tried work directories (in order):" >&2
    [ -n "${PMB_WORK_OVERRIDE:-}" ] && echo "    $(abs_pmb_work "$PMB_WORK_OVERRIDE")  (PMB_WORK_OVERRIDE)" >&2
    [ -n "${PMB_WORK:-}" ] && echo "    $(abs_pmb_work "$PMB_WORK")  (PMB_WORK from profile)" >&2
    echo "    ${atomos_home}/.atomos-pmbootstrap-work/${PROFILE_NAME}  (same default as scripts/build-image.sh)" >&2
    exit 1
fi

# pmb.sh must use the same work dir as this sysroot (profile env alone may point elsewhere).
export PMB_WORK_OVERRIDE="$(dirname "$SYSROOT")"

echo "Ensuring GTK/libadwaita dev metadata in target rootfs..."
pmb chroot -r -- /bin/sh -eu -c \
    'apk add --no-interactive pkgconf glib-dev gdk-pixbuf-dev pango-dev cairo-dev gtk4.0-dev libadwaita-dev gtk4-layer-shell-dev'

PC_DIRS=()
[ -d "$SYSROOT/usr/lib/pkgconfig" ] && PC_DIRS+=("$SYSROOT/usr/lib/pkgconfig")
[ -d "$SYSROOT/usr/lib/$PKGCONF_TRIPLE/pkgconfig" ] && PC_DIRS+=("$SYSROOT/usr/lib/$PKGCONF_TRIPLE/pkgconfig")
[ -d "$SYSROOT/usr/share/pkgconfig" ] && PC_DIRS+=("$SYSROOT/usr/share/pkgconfig")
[ -d "$SYSROOT/lib/pkgconfig" ] && PC_DIRS+=("$SYSROOT/lib/pkgconfig")

if [ "${#PC_DIRS[@]}" -eq 0 ]; then
    echo "ERROR: no pkg-config dirs found in sysroot: $SYSROOT" >&2
    exit 1
fi

PC_PATH="$(IFS=:; echo "${PC_DIRS[*]}")"
export PKG_CONFIG_ALLOW_CROSS=1
export TARGET_PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_PATH="$PC_PATH"
export PKG_CONFIG_LIBDIR="$PC_PATH"
export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static -C link-arg=-Wl,-rpath-link,${SYSROOT}/usr/lib -C link-arg=-Wl,-rpath-link,${SYSROOT}/lib"
export LIBRARY_PATH="${LIBRARY_PATH:-}${LIBRARY_PATH:+:}${SYSROOT}/usr/lib:${SYSROOT}/lib"

find_container_engine() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
    else
        echo ""
    fi
}

build_host() {
    if ! command -v cargo >/dev/null 2>&1; then
        return 1
    fi
    if command -v rustup >/dev/null 2>&1; then
        rustup target add "$TARGET_TRIPLE" >/dev/null 2>&1 || true
    fi
    echo "Building overview chat UI via host cargo (target: $TARGET_TRIPLE)..."
    cargo build \
        --manifest-path "$CRATE_DIR/Cargo.toml" \
        -p atomos-overview-chat-ui-app \
        --release \
        --target "$TARGET_TRIPLE" \
        --bin atomos-overview-chat-ui
}

build_container() {
    local engine
    engine="$(find_container_engine)"
    if [ -z "$engine" ]; then
        echo "ERROR: cargo not on PATH and no working docker/podman (same requirement as scripts/rootfs/install-btlescan.sh)." >&2
        echo "  Install Rust: https://rustup.rs  or  install docker/podman for the container build." >&2
        exit 1
    fi

    local image_tag="${ATOMOS_RUST_BUILDER_IMAGE:-${ATOMOS_BUILDER_IMAGE:-${PMB_CONTAINER_IMAGE:-atomos-pmbootstrap:latest}}}"
    local dockerfile="${ATOMOS_RUST_BUILDER_DOCKERFILE:-${ATOMOS_BUILDER_DOCKERFILE:-$ROOT_DIR/docker/pmbootstrap.Dockerfile}}"
    echo "Building Rust builder image for overview chat UI..."
    "$engine" build -t "$image_tag" -f "$dockerfile" "$ROOT_DIR/docker"

    echo "Building overview chat UI in container (target: $TARGET_TRIPLE)..."
    local -a run_args=()
    if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [[ "$PMB_WORK_OVERRIDE" = /* ]] && [ -d "$PMB_WORK_OVERRIDE" ]; then
        run_args+=(-v "$PMB_WORK_OVERRIDE:$PMB_WORK_OVERRIDE:ro")
    fi

    "$engine" run --rm \
        -e PMB_WORK_OVERRIDE="${PMB_WORK_OVERRIDE:-}" \
        -e PROFILE_NAME="${PROFILE_NAME:-}" \
        -e ROOTFS_CHROOT_NAME="${ROOTFS_CHROOT_NAME:-}" \
        -e PKG_CONFIG_ALLOW_CROSS=1 \
        -e TARGET_PKG_CONFIG_ALLOW_CROSS=1 \
        -v "$REPO_ROOT":/work \
        "${run_args[@]}" \
        -w /work \
        "$image_tag" \
        bash -lc '
set -euo pipefail
if command -v rustup >/dev/null 2>&1; then
    rustup target add "'"$TARGET_TRIPLE"'" >/dev/null 2>&1 || true
fi
if [ -n "${PMB_WORK_OVERRIDE:-}" ] && [ -n "${PROFILE_NAME:-}" ]; then
    ROOTFS_CHROOT_NAME="${ROOTFS_CHROOT_NAME:-$PROFILE_NAME}"
    if [[ "$PMB_WORK_OVERRIDE" = /* ]]; then
        SYSROOT="${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
    else
        SYSROOT="/work/${PMB_WORK_OVERRIDE}/chroot_rootfs_${ROOTFS_CHROOT_NAME}"
    fi
    if [ -d "$SYSROOT/usr/lib/pkgconfig" ] || [ -d "$SYSROOT/usr/lib/'"$PKGCONF_TRIPLE"'/pkgconfig" ] || [ -d "$SYSROOT/lib/pkgconfig" ]; then
        PC_DIRS=()
        [ -d "$SYSROOT/usr/lib/pkgconfig" ] && PC_DIRS+=("$SYSROOT/usr/lib/pkgconfig")
        [ -d "$SYSROOT/usr/lib/'"$PKGCONF_TRIPLE"'/pkgconfig" ] && PC_DIRS+=("$SYSROOT/usr/lib/'"$PKGCONF_TRIPLE"'/pkgconfig")
        [ -d "$SYSROOT/usr/share/pkgconfig" ] && PC_DIRS+=("$SYSROOT/usr/share/pkgconfig")
        [ -d "$SYSROOT/lib/pkgconfig" ] && PC_DIRS+=("$SYSROOT/lib/pkgconfig")
        PC_PATH="$(IFS=:; echo "${PC_DIRS[*]}")"
        export PKG_CONFIG_ALLOW_CROSS=1
        export TARGET_PKG_CONFIG_ALLOW_CROSS=1
        export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
        export PKG_CONFIG_PATH="$PC_PATH"
        export PKG_CONFIG_LIBDIR="$PC_PATH"
        export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static"
        if command -v ld.lld >/dev/null 2>&1 || command -v ld64.lld >/dev/null 2>&1; then
            export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-fuse-ld=lld"
        fi
        export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${SYSROOT}/usr/lib"
        export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${SYSROOT}/lib"
        export LIBRARY_PATH="${LIBRARY_PATH:-}${LIBRARY_PATH:+:}${SYSROOT}/usr/lib:${SYSROOT}/lib"
    fi
fi
cargo build \
    --manifest-path "/work/iso-postmarketos/rust/atomos-overview-chat-ui/Cargo.toml" \
    -p atomos-overview-chat-ui-app \
    --release \
    --target "'"$TARGET_TRIPLE"'" \
    --bin atomos-overview-chat-ui
'
}

if build_host; then
    :
else
    build_container
fi

if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: overview chat UI binary not found after build: $BIN_PATH" >&2
    exit 1
fi

echo "Built overview chat UI: $BIN_PATH"
