# shellcheck shell=bash
# scripts/home-bg/_lib-cross-build.sh
#
# Shared host-side cross-compile helper for atomos-home-bg.
#
# Both build-atomos-home-bg.sh and hotfix-home-bg.sh used to do
#
#     cargo build --release --target aarch64-unknown-linux-musl ...
#
# directly on Linux hosts. That fails on the gtk-rs / webkit-rs *-sys
# build scripts:
#
#     warning: gio-sys@0.21.5: pkg-config has not been configured to
#     support cross-compilation.
#     error: failed to run custom build command for `gio-sys v0.21.5`
#
# The gtk-rs sys crates use pkg-config to discover glib-2.0 / gio-2.0 /
# gobject-2.0 / cairo / pango / gtk4 / webkitgtk-6.0 / gtk4-layer-shell
# at build time. With --target=aarch64-unknown-linux-musl the build
# scripts call pkg-config for the TARGET arch, and pkg-config refuses to
# answer (because it has no Linux/musl sysroot mapped) unless either
# PKG_CONFIG_ALLOW_CROSS=1 + PKG_CONFIG_SYSROOT_DIR is set or a
# cross-config wrapper is installed.
#
# This helper does the same dance scripts/overview-chat-ui/
# build-overview-chat-ui.sh already does:
#   1. Locate the pmbootstrap-managed rootfs chroot for the active
#      profile (it doubles as the cross-compile sysroot).
#   2. apk add the GTK4/WebKit/glib *-dev packages into that rootfs so
#      the .pc files are present.
#   3. Export PKG_CONFIG_SYSROOT_DIR / PKG_CONFIG_PATH /
#      PKG_CONFIG_LIBDIR / PKG_CONFIG_ALLOW_CROSS so the *-sys build
#      scripts can resolve target-arch gtk4.pc etc. against the rootfs.
#   4. Set CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER and
#      ..._RUSTFLAGS so the eventual link step picks up the rootfs's
#      libgtk-4 / libwebkitgtk-6.0 / libgtk4-layer-shell and the musl
#      dynamic linker.
#
# Source this file, then call:
#
#     home_bg_run_cross_cargo_build "$PROFILE_ENV_SOURCE" "$CRATE_MANIFEST" "$TARGET_TRIPLE"
#
# Returns 0 on success. On failure, prints a diagnostic and returns
# non-zero so callers can fall back to the containerized build.

# Order matches scripts/build-image.sh extra-packages list, plus the
# webkit / graphene additions home-bg pulls beyond overview-chat-ui.
# Keep `pkgconf` first so even a stripped sysroot gets the binary used
# for cross-resolution.
HOME_BG_DEV_APKS="pkgconf glib-dev gdk-pixbuf-dev pango-dev cairo-dev graphene-dev libadwaita-dev gtk4.0-dev gtk4-layer-shell-dev webkit2gtk-6.0-dev"

home_bg_required_pc_files() {
    local sysroot="$1"
    printf '%s\n' \
        "$sysroot/usr/lib/pkgconfig/glib-2.0.pc" \
        "$sysroot/usr/lib/pkgconfig/gio-2.0.pc" \
        "$sysroot/usr/lib/pkgconfig/gobject-2.0.pc" \
        "$sysroot/usr/lib/pkgconfig/gdk-pixbuf-2.0.pc" \
        "$sysroot/usr/lib/pkgconfig/cairo.pc" \
        "$sysroot/usr/lib/pkgconfig/pango.pc" \
        "$sysroot/usr/lib/pkgconfig/gtk4.pc" \
        "$sysroot/usr/lib/pkgconfig/graphene-gobject-1.0.pc" \
        "$sysroot/usr/lib/pkgconfig/gtk4-layer-shell-0.pc" \
        "$sysroot/usr/lib/pkgconfig/webkitgtk-6.0.pc"
}

home_bg_has_required_pc_files() {
    local sysroot="$1" pc
    while IFS= read -r pc; do
        [ -f "$pc" ] || return 1
    done < <(home_bg_required_pc_files "$sysroot")
    return 0
}

home_bg_print_missing_pc_files() {
    local sysroot="$1" pc
    while IFS= read -r pc; do
        [ -f "$pc" ] || echo "  missing: $pc" >&2
    done < <(home_bg_required_pc_files "$sysroot")
}

# Resolve absolute path for a possibly-relative PMB_WORK value, mirroring
# scripts/pmb/pmb.sh's logic.
_home_bg_abs_pmb_work() {
    local work="$1" root="$2"
    if [[ "$work" = /* ]]; then
        printf '%s\n' "$work"
    else
        printf '%s/%s\n' "$root" "$work"
    fi
}

_home_bg_base_home() {
    if [ -n "${SUDO_USER:-}" ] && command -v getent >/dev/null 2>&1; then
        getent passwd "$SUDO_USER" | cut -d: -f6
    else
        printf '%s\n' "$HOME"
    fi
}

# Echos absolute path to the rootfs chroot, or returns 1 if none found.
home_bg_resolve_sysroot() {
    local profile_env="$1" root_dir="$2"
    # shellcheck source=/dev/null
    source "$profile_env"
    local rootfs_chroot_name="${PMOS_DEVICE:-${PROFILE_NAME:-}}"
    [ -n "$rootfs_chroot_name" ] || return 1

    local atomos_home work_base s
    atomos_home="$(_home_bg_base_home)"
    for work_base in \
        ${PMB_WORK_OVERRIDE:+"$(_home_bg_abs_pmb_work "$PMB_WORK_OVERRIDE" "$root_dir")"} \
        ${PMB_WORK:+"$(_home_bg_abs_pmb_work "$PMB_WORK" "$root_dir")"} \
        "${atomos_home}/.atomos-pmbootstrap-work/${PROFILE_NAME}"; do
        [ -n "$work_base" ] || continue
        s="${work_base}/chroot_rootfs_${rootfs_chroot_name}"
        if [ -d "$s" ]; then
            printf '%s\n' "$s"
            return 0
        fi
    done
    return 1
}

# Install the GTK / WebKit *-dev packages into the rootfs chroot.
# Uses the host pmbootstrap if available, then falls back to the
# containerized pmbootstrap (scripts/pmb/pmb-container.sh). Best-effort:
# if both fail but the .pc files are already present, the caller can
# proceed.
home_bg_ensure_dev_packages() {
    local profile_env="$1" root_dir="$2"
    local pmb="$root_dir/scripts/pmb/pmb.sh"
    local pmb_container="$root_dir/scripts/pmb/pmb-container.sh"
    local apk_cmd="set -eu; apk update >/dev/null; apk add --no-interactive $HOME_BG_DEV_APKS"

    if [ -x "$pmb" ]; then
        if bash "$pmb" "$profile_env" chroot -r -- /bin/sh -eu -c "$apk_cmd"; then
            return 0
        fi
        echo "home-bg cross-build: host pmbootstrap apk add failed; trying container fallback..." >&2
    fi
    if [ -x "$pmb_container" ]; then
        if PMB_CONTAINER_AS_ROOT=1 bash "$pmb_container" "$profile_env" chroot -r -- /bin/sh -eu -c "$apk_cmd"; then
            return 0
        fi
        echo "home-bg cross-build: container pmbootstrap apk add also failed." >&2
    fi
    return 1
}

# Export PKG_CONFIG_* + CARGO_TARGET_*_RUSTFLAGS so cargo cross-builds
# resolve gtk4 / webkit2gtk-6.0 against the pmOS rootfs sysroot.
home_bg_export_cross_env() {
    local sysroot="$1" target_triple="$2"
    local pkgconf_triple="aarch64-linux-musl"

    local pc_dirs=()
    [ -d "$sysroot/usr/lib/pkgconfig" ] && pc_dirs+=("$sysroot/usr/lib/pkgconfig")
    [ -d "$sysroot/usr/lib/$pkgconf_triple/pkgconfig" ] && pc_dirs+=("$sysroot/usr/lib/$pkgconf_triple/pkgconfig")
    [ -d "$sysroot/usr/share/pkgconfig" ] && pc_dirs+=("$sysroot/usr/share/pkgconfig")
    [ -d "$sysroot/lib/pkgconfig" ] && pc_dirs+=("$sysroot/lib/pkgconfig")

    if [ "${#pc_dirs[@]}" -eq 0 ]; then
        echo "home-bg cross-build: no pkg-config dirs in sysroot $sysroot" >&2
        return 1
    fi
    local pc_path
    pc_path="$(IFS=:; echo "${pc_dirs[*]}")"

    export PKG_CONFIG_ALLOW_CROSS=1
    export TARGET_PKG_CONFIG_ALLOW_CROSS=1
    export PKG_CONFIG_SYSROOT_DIR="$sysroot"
    export PKG_CONFIG_PATH="$pc_path"
    export PKG_CONFIG_LIBDIR="$pc_path"

    # gcc-cross / lld musl link flags. Match overview-chat-ui's tuning:
    # rust-lld for non-QEMU devices, aarch64-linux-gnu-gcc for QEMU
    # arm64 (rust-lld linked binaries crash early on QEMU virtio GL).
    local musl_dynamic_linker="/lib/ld-musl-aarch64.so.1"
    local linker
    if [ -n "${ATOMOS_HOME_BG_LINKER:-}" ]; then
        linker="$ATOMOS_HOME_BG_LINKER"
    else
        case "${PMOS_DEVICE:-}" in
            qemu-aarch64|qemu_arm64|qemu-aarch64-*)
                linker="aarch64-linux-gnu-gcc"
                ;;
            *)
                linker="rust-lld"
                ;;
        esac
    fi
    local debug_flags=""
    if [ "${ATOMOS_HOME_BG_DEBUG_SYMBOLS:-0}" = "1" ]; then
        debug_flags=" -C debuginfo=2 -C force-frame-pointers=yes -C strip=none"
    fi
    local gcc_native_flags=""
    if [ "$linker" = "rust-lld" ]; then
        for d in /usr/lib/gcc-cross/aarch64-linux-gnu/* /usr/lib/gcc/aarch64-linux-gnu/*; do
            [ -d "$d" ] || continue
            gcc_native_flags="${gcc_native_flags} -L native=${d}"
        done
    fi

    local target_var_suffix
    target_var_suffix="$(printf '%s' "$target_triple" | tr 'a-z-' 'A-Z_')"
    local linker_var="CARGO_TARGET_${target_var_suffix}_LINKER"
    local rustflags_var="CARGO_TARGET_${target_var_suffix}_RUSTFLAGS"

    export "$linker_var=$linker"
    if [ "$linker" = "rust-lld" ]; then
        export "$rustflags_var=-Clink-self-contained=yes -C target-feature=-crt-static -C link-arg=--dynamic-linker=${musl_dynamic_linker} -L native=${sysroot}/usr/lib -L native=${sysroot}/lib -L native=${sysroot}/usr/lib/${pkgconf_triple}${gcc_native_flags}${debug_flags}"
    else
        export "$rustflags_var=-C target-feature=-crt-static -C link-arg=--sysroot=${sysroot} -C link-arg=-Wl,--dynamic-linker,${musl_dynamic_linker} -C link-arg=-Wl,-rpath-link,${sysroot}/usr/lib -C link-arg=-Wl,-rpath-link,${sysroot}/lib -L native=${sysroot}/usr/lib -L native=${sysroot}/lib -L native=${sysroot}/usr/lib/${pkgconf_triple}${gcc_native_flags}${debug_flags}"
    fi
}

# Top-level entry point.
#   $1: profile env file (for sysroot resolution + apk add)
#   $2: crate manifest path (Cargo.toml of app-gtk)
#   $3: target triple (default aarch64-unknown-linux-musl)
#   $4: optional repo root override (defaults to two dirs above this file)
home_bg_run_cross_cargo_build() {
    local profile_env="$1" crate_manifest="$2" target_triple="${3:-aarch64-unknown-linux-musl}"
    local root_dir="${4:-}"
    if [ -z "$root_dir" ]; then
        root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi

    if ! command -v cargo >/dev/null 2>&1; then
        echo "home-bg cross-build: cargo not on PATH" >&2
        return 1
    fi

    local sysroot
    if ! sysroot="$(home_bg_resolve_sysroot "$profile_env" "$root_dir")"; then
        echo "home-bg cross-build: cannot locate pmbootstrap rootfs sysroot for profile $profile_env" >&2
        echo "  Run scripts/build-image.sh once first to materialize the chroot, or" >&2
        echo "  set ATOMOS_HOME_BG_BUILD_MODE=container to bypass host cross-build." >&2
        return 1
    fi
    echo "home-bg cross-build: using sysroot $sysroot"

    if [ "${ATOMOS_HOME_BG_SKIP_PMB_APK_ADD:-0}" != "1" ]; then
        if ! home_bg_ensure_dev_packages "$profile_env" "$root_dir"; then
            if home_bg_has_required_pc_files "$sysroot"; then
                echo "home-bg cross-build: WARN apk add failed but required pkg-config files already present; continuing." >&2
            else
                echo "home-bg cross-build: ERROR required pkg-config files missing in $sysroot:" >&2
                home_bg_print_missing_pc_files "$sysroot"
                return 1
            fi
        fi
    fi

    if ! home_bg_has_required_pc_files "$sysroot"; then
        echo "home-bg cross-build: ERROR required pkg-config files still missing after apk add:" >&2
        home_bg_print_missing_pc_files "$sysroot"
        return 1
    fi

    if ! home_bg_export_cross_env "$sysroot" "$target_triple"; then
        return 1
    fi

    if command -v rustup >/dev/null 2>&1; then
        rustup target add "$target_triple" >/dev/null 2>&1 || true
    fi

    echo "home-bg cross-build: cargo build (target=$target_triple)"
    cargo build \
        --manifest-path "$crate_manifest" \
        --release \
        --target "$target_triple" \
        --bin atomos-home-bg
}
