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
MUSL_DYNAMIC_LINKER="/lib/ld-musl-aarch64.so.1"
PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

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

DEV_APK_ADD_CMD='set -eu;
apk update;
if ! apk add --no-interactive pkgconf glib-dev gdk-pixbuf-dev pango-dev cairo-dev graphene-dev libadwaita-dev gtk4-layer-shell-dev gtk4.0-dev; then
  echo "WARN: apk add failed (likely repo/version skew)." >&2;
  if [ "${ATOMOS_OVERVIEW_CHAT_UI_ALLOW_APK_UPGRADE:-0}" = "1" ]; then
    echo "WARN: trying apk upgrade + retry (ATOMOS_OVERVIEW_CHAT_UI_ALLOW_APK_UPGRADE=1)..." >&2;
    apk upgrade --no-interactive || true;
  else
    echo "WARN: skipping apk upgrade by default to avoid mutating runtime package set." >&2;
    echo "WARN: set ATOMOS_OVERVIEW_CHAT_UI_ALLOW_APK_UPGRADE=1 to opt in." >&2;
  fi;
  apk add --no-interactive pkgconf glib-dev gdk-pixbuf-dev pango-dev cairo-dev graphene-dev libadwaita-dev gtk4-layer-shell-dev gtk4.0-dev;
fi'

has_required_pc_files() {
    local pc
    for pc in \
        "$SYSROOT/usr/lib/pkgconfig/gdk-pixbuf-2.0.pc" \
        "$SYSROOT/usr/lib/pkgconfig/cairo.pc" \
        "$SYSROOT/usr/lib/pkgconfig/pango.pc" \
        "$SYSROOT/usr/lib/pkgconfig/gtk4.pc" \
        "$SYSROOT/usr/lib/pkgconfig/graphene-gobject-1.0.pc"; do
        [ -f "$pc" ] || return 1
    done
    return 0
}

print_missing_pc_files() {
    local pc
    for pc in \
        "$SYSROOT/usr/lib/pkgconfig/gdk-pixbuf-2.0.pc" \
        "$SYSROOT/usr/lib/pkgconfig/cairo.pc" \
        "$SYSROOT/usr/lib/pkgconfig/pango.pc" \
        "$SYSROOT/usr/lib/pkgconfig/gtk4.pc" \
        "$SYSROOT/usr/lib/pkgconfig/graphene-gobject-1.0.pc"; do
        [ -f "$pc" ] || echo "  missing: $pc" >&2
    done
}

ensure_dev_packages_via_container() {
    if [ ! -x "$PMB_CONTAINER" ]; then
        return 1
    fi

    local out rc container_work_override
    if [ -n "${PMB_WORK:-}" ]; then
        container_work_override="$PMB_WORK"
    elif [[ "$PMB_WORK_OVERRIDE" = "$ROOT_DIR"* ]]; then
        container_work_override=".${PMB_WORK_OVERRIDE#$ROOT_DIR}"
    else
        container_work_override="$PMB_WORK_OVERRIDE"
    fi

    echo "Configuring containerized pmbootstrap target..."
    PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" \
        bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" config device "$PMOS_DEVICE"
    if [ -n "${PMOS_UI:-}" ]; then
        PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" \
            bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" config ui "$PMOS_UI"
    fi

    echo "Ensuring GTK/libadwaita dev metadata via containerized pmbootstrap..."
    set +e
    out="$(PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$DEV_APK_ADD_CMD" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        [ -n "$out" ] && printf '%s\n' "$out"
        return 0
    fi

    [ -n "$out" ] && printf '%s\n' "$out" >&2
    case "$out" in
        *"Did you run 'pmbootstrap init'?"*|*"pmaports dir not found"*|*"Work path not found"*)
            echo "Container pmbootstrap not initialized yet; running one-time init..." >&2
            set +e
            out="$(yes '' | PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" --as-root init 2>&1)"
            rc=$?
            set -e
            [ -n "$out" ] && printf '%s\n' "$out" >&2
            [ "$rc" -eq 0 ] || return 1
            PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" \
                bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" config device "$PMOS_DEVICE"
            if [ -n "${PMOS_UI:-}" ]; then
                PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" \
                    bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" config ui "$PMOS_UI"
            fi
            PMB_CONTAINER_AS_ROOT=1 PMB_WORK_OVERRIDE="$container_work_override" bash "$PMB_CONTAINER" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$DEV_APK_ADD_CMD"
            ;;
        *)
            return 1
            ;;
    esac
}

if [ "${ATOMOS_OVERVIEW_CHAT_UI_SKIP_PMB_APK_ADD:-0}" = "1" ]; then
    echo "Skipping pmbootstrap apk add (ATOMOS_OVERVIEW_CHAT_UI_SKIP_PMB_APK_ADD=1)."
else
    echo "Ensuring GTK/libadwaita dev metadata in target rootfs..."
    if ! pmb chroot -r -- /bin/sh -eu -c "$DEV_APK_ADD_CMD"; then
        echo "WARN: host pmbootstrap chroot apk step failed." >&2
        if has_required_pc_files; then
            echo "Found required pkg-config files in sysroot; continuing." >&2
        else
            echo "Required pkg-config files are missing; trying containerized pmbootstrap fallback..." >&2
            if ! ensure_dev_packages_via_container; then
                echo "WARN: containerized pmbootstrap fallback failed; continuing with existing sysroot packages." >&2
                echo "  Set ATOMOS_OVERVIEW_CHAT_UI_SKIP_PMB_APK_ADD=1 to suppress pmbootstrap steps." >&2
            fi
        fi
    fi
fi

if ! has_required_pc_files; then
    echo "ERROR: required GTK pkg-config files are still missing in sysroot: $SYSROOT" >&2
    print_missing_pc_files
    echo "Run this manually to diagnose package availability in the target rootfs:" >&2
    echo "  bash \"$PMB\" \"$PROFILE_ENV_SOURCE\" chroot -r -- apk search -x '*gtk*dev' '*graphene*dev' '*libadwaita*dev'" >&2
    exit 1
fi

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
export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static -C link-arg=-Wl,--dynamic-linker,${MUSL_DYNAMIC_LINKER} -C link-arg=-Wl,-rpath-link,${SYSROOT}/usr/lib -C link-arg=-Wl,-rpath-link,${SYSROOT}/lib"
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

default_overview_linker() {
    # QEMU aarch64 images have shown early startup crashes with rust-lld-linked
    # gtk/adwaita binaries. Prefer GCC linker there unless explicitly overridden.
    if [ -n "${ATOMOS_OVERVIEW_CHAT_UI_LINKER:-}" ]; then
        printf '%s\n' "${ATOMOS_OVERVIEW_CHAT_UI_LINKER}"
        return 0
    fi
    case "${PMOS_DEVICE:-}" in
        qemu-aarch64|qemu_arm64|qemu-aarch64-*)
            printf '%s\n' "aarch64-linux-gnu-gcc"
            ;;
        *)
            printf '%s\n' "rust-lld"
            ;;
    esac
}

build_host() {
    if ! command -v cargo >/dev/null 2>&1; then
        return 1
    fi
    if command -v rustup >/dev/null 2>&1; then
        rustup target add "$TARGET_TRIPLE" >/dev/null 2>&1 || true
    fi
    local debug_flags=""
    if [ "${ATOMOS_OVERVIEW_CHAT_UI_DEBUG_SYMBOLS:-0}" = "1" ]; then
        debug_flags=" -C debuginfo=2 -C force-frame-pointers=yes -C strip=none"
    fi
    local overview_linker
    overview_linker="$(default_overview_linker)"
    local gcc_native_flags=""
    if [ "$overview_linker" = "rust-lld" ]; then
        for d in /usr/lib/gcc-cross/aarch64-linux-gnu/* /usr/lib/gcc/aarch64-linux-gnu/*; do
            [ -d "$d" ] || continue
            gcc_native_flags="${gcc_native_flags} -L native=${d}"
        done
    fi
    local -a host_env=(
        "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=$overview_linker"
    )
    if [ "$overview_linker" = "rust-lld" ]; then
        host_env+=("CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS=-Clink-self-contained=yes -C target-feature=-crt-static -C link-arg=--dynamic-linker=${MUSL_DYNAMIC_LINKER} -L native=${SYSROOT}/usr/lib -L native=${SYSROOT}/lib -L native=${SYSROOT}/usr/lib/${PKGCONF_TRIPLE}${gcc_native_flags}${debug_flags}")
    fi
    echo "Building overview chat UI via host cargo (target: $TARGET_TRIPLE)..."
    env "${host_env[@]}" cargo build \
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
        -e ATOMOS_OVERVIEW_CHAT_UI_LINKER="$(default_overview_linker)" \
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
        OVERVIEW_LINKER="${ATOMOS_OVERVIEW_CHAT_UI_LINKER:-}"
        if [ -z "${OVERVIEW_LINKER}" ]; then
            case "${ROOTFS_CHROOT_NAME:-}" in
                qemu-aarch64|qemu_arm64|qemu-aarch64-*)
                    OVERVIEW_LINKER="aarch64-linux-gnu-gcc"
                    ;;
                *)
                    OVERVIEW_LINKER="rust-lld"
                    ;;
            esac
        fi
        OVERVIEW_DEBUG_FLAGS=""
        if [ "${ATOMOS_OVERVIEW_CHAT_UI_DEBUG_SYMBOLS:-0}" = "1" ]; then
            OVERVIEW_DEBUG_FLAGS=" -C debuginfo=2 -C force-frame-pointers=yes -C strip=none"
        fi
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="${OVERVIEW_LINKER}"
        if [ "${OVERVIEW_LINKER}" = "rust-lld" ]; then
            GCC_NATIVE_FLAGS=""
            for d in /usr/lib/gcc-cross/aarch64-linux-gnu/* /usr/lib/gcc/aarch64-linux-gnu/*; do
                [ -d "$d" ] || continue
                GCC_NATIVE_FLAGS="${GCC_NATIVE_FLAGS} -L native=${d}"
            done
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-Clink-self-contained=yes -C target-feature=-crt-static -C link-arg=--dynamic-linker=/lib/ld-musl-aarch64.so.1 -L native=${SYSROOT}/usr/lib -L native=${SYSROOT}/lib -L native=${SYSROOT}/usr/lib/'"$PKGCONF_TRIPLE"'${GCC_NATIVE_FLAGS}${OVERVIEW_DEBUG_FLAGS}"
        else
            export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static"
            if command -v ld.lld >/dev/null 2>&1 || command -v ld64.lld >/dev/null 2>&1; then
                export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-fuse-ld=lld"
            fi
            export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,--dynamic-linker,/lib/ld-musl-aarch64.so.1"
            export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${SYSROOT}/usr/lib"
            export RUSTFLAGS="${RUSTFLAGS} -C link-arg=-Wl,-rpath-link,${SYSROOT}/lib"
            export RUSTFLAGS="${RUSTFLAGS}${OVERVIEW_DEBUG_FLAGS}"
        fi
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

verify_binary_is_musl() {
    if ! command -v file >/dev/null 2>&1; then
        echo "WARN: 'file' not installed; cannot verify final binary interpreter." >&2
        return 0
    fi
    local desc
    desc="$(file -b "$BIN_PATH" 2>/dev/null || true)"
    if echo "$desc" | grep -qE 'interpreter.*/lib/ld-linux|ld-linux-aarch64'; then
        echo "ERROR: built binary is glibc-linked (unexpected for $TARGET_TRIPLE)." >&2
        echo "  file: $BIN_PATH" >&2
        echo "  meta: $desc" >&2
        echo "  Check linker config (cargo target linker/env) and rebuild." >&2
        echo "  Temporary override: ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK=1 (not for pmOS)." >&2
        return 1
    fi
    return 0
}

detect_readelf_tool() {
    if command -v readelf >/dev/null 2>&1; then
        printf '%s\n' "readelf"
        return 0
    fi
    if command -v llvm-readelf >/dev/null 2>&1; then
        printf '%s\n' "llvm-readelf"
        return 0
    fi
    return 1
}

verify_binary_has_musl_interp() {
    local readelf_tool
    readelf_tool="$(detect_readelf_tool || true)"
    if [ -z "$readelf_tool" ]; then
        # Fallback for hosts without binutils/llvm tools (e.g. minimal macOS setups).
        # `file` output on dynamic ELF usually includes the interpreter path.
        if command -v file >/dev/null 2>&1; then
            local desc
            desc="$(file -b "$BIN_PATH" 2>/dev/null || true)"
            if echo "$desc" | grep -q "interpreter ${MUSL_DYNAMIC_LINKER}"; then
                return 0
            fi
            echo "ERROR: cannot verify PT_INTERP with readelf, and file metadata does not show expected musl interpreter." >&2
            echo "  file: $BIN_PATH" >&2
            echo "  meta: $desc" >&2
            echo "  Install binutils (readelf) or llvm-readelf for definitive verification." >&2
            return 1
        fi
        echo "ERROR: neither readelf/llvm-readelf nor file is available; cannot verify PT_INTERP for $BIN_PATH." >&2
        return 1
    fi
    local headers
    headers="$("$readelf_tool" -W -l "$BIN_PATH" 2>/dev/null || true)"
    if ! echo "$headers" | grep -q "INTERP"; then
        echo "ERROR: built binary is missing PT_INTERP program header." >&2
        echo "  This can segfault before main() on target (unresolved startup relocations)." >&2
        echo "  file: $BIN_PATH" >&2
        return 1
    fi
    if ! echo "$headers" | grep -q "Requesting program interpreter: $MUSL_DYNAMIC_LINKER"; then
        echo "ERROR: built binary PT_INTERP is unexpected (wanted $MUSL_DYNAMIC_LINKER)." >&2
        echo "  file: $BIN_PATH" >&2
        echo "  Found:" >&2
        echo "$headers" | grep "Requesting program interpreter" >&2 || true
        return 1
    fi
    return 0
}

PREFER_CONTAINER="${ATOMOS_OVERVIEW_CHAT_UI_PREFER_CONTAINER:-1}"
if [ "$PREFER_CONTAINER" = "1" ]; then
    echo "Skipping host cargo cross-build (ATOMOS_OVERVIEW_CHAT_UI_PREFER_CONTAINER=1); using container build."
    build_container
else
    if build_host; then
        :
    else
        build_container
    fi
fi

if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: overview chat UI binary not found after build: $BIN_PATH" >&2
    exit 1
fi

if [ "${ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK:-0}" != "1" ]; then
    if ! verify_binary_is_musl || ! verify_binary_has_musl_interp; then
        # Debian/Ubuntu-based builders can emit glibc-linked output when GCC
        # linker selection bleeds host libc defaults into a musl target.
        # Retry once with rust-lld + self-contained linker path in container.
        if [ "${ATOMOS_OVERVIEW_CHAT_UI_MUSL_RETRY_WITH_RUST_LLD:-1}" = "1" ] && [ "${ATOMOS_OVERVIEW_CHAT_UI_LINKER:-}" != "rust-lld" ]; then
            echo "Retrying overview chat UI build with rust-lld to enforce musl linkage..."
            ATOMOS_OVERVIEW_CHAT_UI_LINKER=rust-lld build_container
            verify_binary_is_musl
            verify_binary_has_musl_interp
        else
            exit 1
        fi
    fi
fi

echo "Built overview chat UI: $BIN_PATH"
