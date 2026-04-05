#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: build-image.sh [profile-env] [--without-overview-chat-ui]

Options:
  --without-overview-chat-ui, --skip-overview-chat-ui
      Skip building/installing atomos-overview-chat-ui during image build.
EOF
}

PROFILE_ENV=""
BUILD_OVERVIEW_CHAT_UI=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --without-overview-chat-ui|--skip-overview-chat-ui)
            BUILD_OVERVIEW_CHAT_UI=0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            if [ -n "$PROFILE_ENV" ]; then
                echo "ERROR: profile env provided more than once: $1" >&2
                usage
                exit 1
            fi
            PROFILE_ENV="$1"
            ;;
    esac
    shift
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ENV="${PROFILE_ENV:-config/fairphone-fp4.env}"
BUILD_DIR="$ROOT_DIR/build"

if [ "$(uname -s)" = "Darwin" ]; then
    echo "ERROR: image build requires Linux host/VM (pmbootstrap loop devices)." >&2
    exit 2
fi

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "ERROR: missing profile env: $PROFILE_ENV" >&2
    exit 2
fi
PROFILE_ENV_SOURCE="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$PROFILE_ENV_SOURCE")"

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

if [ -z "${PROFILE_NAME:-}" ] || [ -z "${PMOS_DEVICE:-}" ] || [ -z "${PMOS_UI:-}" ]; then
    echo "ERROR: profile env is missing required variables (PROFILE_NAME/PMOS_DEVICE/PMOS_UI)." >&2
    exit 2
fi

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"

pmb() {
    bash "$PMB" "$PROFILE_ENV_SOURCE" "$@"
}

warn_if_workdir_on_unreliable_fs() {
    local work="$1"
    if [ ! -d "$work" ] || ! command -v findmnt >/dev/null 2>&1; then
        return 0
    fi
    local fstype
    fstype="$(findmnt -n -o FSTYPE "$work" 2>/dev/null || true)"
    case "$fstype" in
        fuse*|virtiofs|nfs*|9p)
            echo "WARN: pmbootstrap work dir is on filesystem type \"$fstype\" ($work)." >&2
            echo "  mkfs.ext4 on loop-backed install images often fails on FUSE/NFS/virtiofs shares." >&2
            echo "  Put the work directory on local ext4 (e.g. move the VM home off a shared folder)." >&2
            ;;
    esac
}

pmaports_cache_dir() {
    local base_home="$1"
    if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
        local container_home="${PMB_CONTAINER_HOME_DIR:-$base_home/.atomos-pmbootstrap-home}"
        echo "$container_home/.local/var/pmbootstrap/cache_git/pmaports"
    else
        echo "$base_home/.local/var/pmbootstrap/cache_git/pmaports"
    fi
}

pin_pmaports_commit() {
    local commit="${PMOS_PMAPORTS_COMMIT:-}"
    [ -n "$commit" ] || return 0
    if [ ! -d "$PMAPORTS_CACHE/.git" ]; then
        echo "ERROR: PMOS_PMAPORTS_COMMIT is set but pmaports cache is missing: $PMAPORTS_CACHE" >&2
        echo "  Ensure pmbootstrap init/update completed before pinning." >&2
        exit 2
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "ERROR: git is required to pin pmaports commit ($commit)." >&2
        exit 2
    fi
    # Local compatibility edits (e.g. mkinitfs hook tweaks) can dirty the cache
    # worktree and block subsequent pinned checkouts. Reset only this cache repo.
    if ! git -C "$PMAPORTS_CACHE" diff --quiet || ! git -C "$PMAPORTS_CACHE" diff --cached --quiet || [ -n "$(git -C "$PMAPORTS_CACHE" ls-files --others --exclude-standard)" ]; then
        echo "Resetting dirty pmaports cache before pinning commit..."
        git -C "$PMAPORTS_CACHE" reset --hard HEAD
        git -C "$PMAPORTS_CACHE" clean -fd
    fi

    if ! git -C "$PMAPORTS_CACHE" rev-parse --verify "${commit}^{commit}" >/dev/null 2>&1; then
        echo "Fetching pinned pmaports commit: $commit"
        git -C "$PMAPORTS_CACHE" fetch --depth 1 origin "$commit" || git -C "$PMAPORTS_CACHE" fetch origin "$commit"
    fi
    git -C "$PMAPORTS_CACHE" checkout -q "$commit"
    local actual
    actual="$(git -C "$PMAPORTS_CACHE" rev-parse HEAD)"
    if [ "$actual" != "$commit" ]; then
        echo "ERROR: failed to pin pmaports to commit $commit (got $actual)" >&2
        exit 2
    fi
    echo "Pinned pmaports cache to commit: $actual"
}

# pmbootstrap build --src runs abuild as pmos in chroot_native; without keys, abuild fails with
# "No private key found. Use 'abuild-keygen' to generate the keys."
ensure_native_abuild_keys() {
    echo "=== Ensure abuild signing keys in native chroot ==="
    pmb chroot -- /bin/sh -eu -c '
        if ! command -v abuild-keygen >/dev/null 2>&1; then
            apk add --no-interactive abuild
        fi
        mkdir -p /home/pmos/.abuild
        chown pmos:pmos /home/pmos/.abuild
        have_private=0
        for f in /home/pmos/.abuild/*.rsa; do
            if [ -f "$f" ]; then
                have_private=1
                break
            fi
        done
        if [ "$have_private" -eq 0 ]; then
            busybox su pmos -c "HOME=/home/pmos abuild-keygen -a -n"
        fi
        # pmbootstrap build indexes signed APKs immediately after build.
        # Ensure native chroot trusts the abuild key used by /home/pmos/.abuild.
        mkdir -p /etc/apk/keys
        for pub in /home/pmos/.abuild/*.rsa.pub; do
            [ -f "$pub" ] || continue
            install -m 644 "$pub" /etc/apk/keys/
        done
    '
}

purge_local_phosh_overrides() {
    echo "=== Purge local phosh/phoc package overrides (stock phosh mode) ==="
    # pmbootstrap installs prefer local built APKs in /home/pmos/packages when present.
    # Remove previously built phosh/phoc artifacts so install resolves to upstream repos.
    pmb chroot -- /bin/sh -eu -c '
        for base in /home/pmos/packages /mnt/pmbootstrap/packages; do
            [ -d "$base" ] || continue
            rm -f "$base"/*/phosh-*.apk \
                  "$base"/*/phoc-*.apk \
                  "$base"/*/phosh-mobile-settings-*.apk \
                  "$base"/*/*/phosh-*.apk \
                  "$base"/*/*/phoc-*.apk \
                  "$base"/*/*/phosh-mobile-settings-*.apk || true
            rm -f "$base"/*/APKINDEX.tar.gz "$base"/*/*/APKINDEX.tar.gz || true
        done
    '
    # Also clear temporary aport forks that can influence source-based local builds.
    rm -rf "$PMAPORTS_CACHE/temp/phosh" "$PMAPORTS_CACHE/temp/phoc" 2>/dev/null || true
}

resolve_parity_packages() {
    local cache_dir="$1"
    local candidates="${PMOS_PARITY_PACKAGE_CANDIDATES:-phosh-mobile-settings,feedbackd}"
    local pkg category
    local resolved=()
    local IFS=','
    read -r -a list <<< "$candidates"
    [ -d "$cache_dir" ] || return 0
    for pkg in "${list[@]}"; do
        pkg="$(echo "$pkg" | tr -d '[:space:]')"
        [ -n "$pkg" ] || continue
        for category in "$cache_dir"/*; do
            if [ -f "$category/$pkg/APKBUILD" ]; then
                resolved+=("$pkg")
                break
            fi
        done
    done
    if [ "${#resolved[@]}" -gt 0 ]; then
        IFS=','
        printf '%s\n' "${resolved[*]}"
    fi
}

apply_mkinitfs_udev_compat_in_pmaports_cache() {
    if [ "${ATOMOS_MKINITFS_UDEV_COMPAT_PATCH:-1}" != "1" ]; then
        return 0
    fi
    if [ ! -d "$PMAPORTS_CACHE" ]; then
        return 0
    fi

    local matches changed=0 f
    matches="$(rg -l "udev/udev\.conf" "$PMAPORTS_CACHE" || true)"
    if [ -z "$matches" ]; then
        return 0
    fi

    echo "Applying mkinitfs udev compatibility patch in pmaports cache..."
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Newer systemd-based roots may not ship udev.conf at either /usr/lib or /etc.
        # Remove hook references entirely so mkinitfs does not hard-fail on missing file.
        sed -i "/udev\/udev\.conf/d" "$f"
        changed=1
    done <<EOF
$matches
EOF

    if [ "$changed" -eq 1 ]; then
        echo "Patched mkinitfs hook path(s) in pmaports cache."
    fi
}

export PATH="$HOME/.local/bin:$PATH"
bash "$ROOT_DIR/scripts/pmb/ensure-pmbootstrap.sh"

USE_VENDOR_PHOSH=0
if [ "$PMOS_UI" = "phosh" ]; then
    USE_VENDOR_PHOSH=1
    case "${PMOS_DEVICE:-}" in
        qemu-*|qemu_*)
            if [ "${ATOMOS_ENABLE_VENDOR_PHOSH_ON_QEMU:-0}" != "1" ] && [ "${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" != "1" ]; then
                echo "=== QEMU profile detected; defaulting to stock phosh (skip vendor phosh build). ==="
                echo "    Set ATOMOS_ENABLE_VENDOR_PHOSH_ON_QEMU=1 to opt in to patched vendor phosh on QEMU."
                export ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1
            fi
            ;;
    esac
    if [ "${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" = "1" ]; then
        USE_VENDOR_PHOSH=0
    fi
fi

if [ "$USE_VENDOR_PHOSH" = "1" ]; then
    echo "=== Sync vendor Phosh sources ==="
    bash "$ROOT_DIR/scripts/phosh/checkout-phosh.sh"
else
    echo "=== Skip vendor Phosh source sync (stock phosh mode) ==="
fi

if [ -n "${SUDO_USER:-}" ]; then
    BASE_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    BASE_HOME="$HOME"
fi

export PMB_WORK_OVERRIDE="${BASE_HOME}/.atomos-pmbootstrap-work/${PROFILE_NAME}"
CFG="${BASE_HOME}/.config/pmbootstrap_v3.cfg"
PMAPORTS_CACHE="$(pmaports_cache_dir "$BASE_HOME")"
mkdir -p "$BUILD_DIR"
warn_if_workdir_on_unreliable_fs "$PMB_WORK_OVERRIDE"

if [ ! -f "$CFG" ] || [ ! -d "$PMB_WORK_OVERRIDE" ]; then
    echo "=== Initializing pmbootstrap profile ==="
    set +o pipefail
    yes "" | pmb --as-root init || true
    set -o pipefail
    if [ ! -f "$CFG" ]; then
        echo "ERROR: pmbootstrap init did not produce config at $CFG" >&2
        exit 2
    fi
fi

echo "=== Configure pmbootstrap target ==="
pmb config device "$PMOS_DEVICE"
pmb config ui "$PMOS_UI"
pmb config build_pkgs_on_install false
bash "$ROOT_DIR/scripts/pmb/set-pmbootstrap-option.sh" "$CFG" "build_pkgs_on_install" "false" >/dev/null
bash "$ROOT_DIR/scripts/pmb/ensure-pmbootstrap-mirrors.sh" "$PROFILE_ENV_SOURCE"
pin_pmaports_commit
apply_mkinitfs_udev_compat_in_pmaports_cache

if [ "$PMOS_UI" = "phosh" ]; then
    bash "$ROOT_DIR/scripts/pmb/set-container-provider.sh" "$CFG" "postmarketos-base-ui-audio-backend" "pipewire"
    if [ "$USE_VENDOR_PHOSH" = "1" ]; then
        ensure_native_abuild_keys
        bash "$ROOT_DIR/scripts/phosh/build-atomos-phosh-pmbootstrap.sh" "$PROFILE_ENV_SOURCE"
    else
        purge_local_phosh_overrides
    fi
fi

EXTRA_PACKAGES_EFFECTIVE="${PMOS_EXTRA_PACKAGES:-}"
PARITY_PACKAGES="$(resolve_parity_packages "$PMAPORTS_CACHE" || true)"
if [ -n "$PARITY_PACKAGES" ]; then
    if [ -n "$EXTRA_PACKAGES_EFFECTIVE" ]; then
        EXTRA_PACKAGES_EFFECTIVE="${EXTRA_PACKAGES_EFFECTIVE},${PARITY_PACKAGES}"
    else
        EXTRA_PACKAGES_EFFECTIVE="$PARITY_PACKAGES"
    fi
fi
EXTRA_PACKAGES_EFFECTIVE="$(
    python3 -c 'import sys; pkgs=[p.strip() for p in sys.argv[1].split(",") if p.strip()]; out=[]; [out.append(p) for p in pkgs if p not in out]; print(",".join(out))' \
        "$EXTRA_PACKAGES_EFFECTIVE"
)"

echo "Using extra packages: $EXTRA_PACKAGES_EFFECTIVE"
pmb config extra_packages "$EXTRA_PACKAGES_EFFECTIVE"

echo "=== pmbootstrap shutdown (drop stale chroots / loop devices before install) ==="
set +e
pmb shutdown
_shutdown_rc=$?
set -e
if [ "$_shutdown_rc" -ne 0 ]; then
    echo "Note: pmbootstrap shutdown exited $_shutdown_rc (ok if nothing was running)."
fi

# Optional freshness guard for non-deterministic rebuild issues:
# when ATOMOS_FRESH_ROOTFS_IMAGES=1, remove existing native install images so
# the next `pmbootstrap install` must regenerate /home/pmos/rootfs/*.img.
bash "$ROOT_DIR/scripts/rootfs/delete-native-rootfs-images.sh" "$PROFILE_ENV_SOURCE"

mkinitfs_udev_compat_patch() {
    echo "Applying mkinitfs udev compatibility patch in rootfs..."
    pmb chroot -r -- /bin/sh -eu -c '
        mkdir -p /usr/lib/udev
        for f in /usr/share/mkinitfs/files-extra/*.files; do
            [ -f "$f" ] || continue
            sed -i "/udev\/udev\.conf/d" "$f"
        done
    '
}

verify_overview_chat_ui_install() {
    echo "=== Verify atomos-overview-chat-ui install in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c \
        'test -x /usr/local/bin/atomos-overview-chat-ui && test -x /usr/bin/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-submit'
}

verify_overview_chat_ui_launcher_contract() {
    echo "=== Verify atomos-overview-chat-ui launcher contract in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c '
        test -x /usr/libexec/atomos-overview-chat-ui
        grep -q "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME" /usr/libexec/atomos-overview-chat-ui
        grep -q "atomos-overview-chat-ui.disabled" /usr/libexec/atomos-overview-chat-ui
    '
}

verify_stock_phosh_origin() {
    if [ "$PMOS_UI" != "phosh" ] || [ "$USE_VENDOR_PHOSH" = "1" ]; then
        return 0
    fi
    echo "=== Verify stock phosh package origin in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c '
        test -x /usr/libexec/phosh
        policy="$(apk policy phosh phoc phosh-mobile-settings 2>/dev/null || true)"
        printf "%s\n" "$policy"
        if printf "%s\n" "$policy" | grep -Eq "/(mnt/pmbootstrap|home/pmos)/packages/"; then
            echo "ERROR: stock phosh mode still references local pmbootstrap package repo." >&2
            echo "  This indicates stale local package overrides are still active." >&2
            exit 3
        fi
    '
}

if ! pmb install --password "$PMOS_INSTALL_PASSWORD" --add "$EXTRA_PACKAGES_EFFECTIVE"; then
    echo "WARN: pmbootstrap install failed; attempting mkinitfs udev compatibility recovery..." >&2
    mkinitfs_udev_compat_patch || true
    echo "Retrying pmbootstrap install..." >&2
    pmb install --password "$PMOS_INSTALL_PASSWORD" --add "$EXTRA_PACKAGES_EFFECTIVE"
fi
verify_stock_phosh_origin

echo "=== Apply AtomOS rootfs customizations ==="
bash "$ROOT_DIR/scripts/rootfs/wire-custom-apk-repos.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/install-atomos-agents.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/install-btlescan.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/install-bt-tools.sh" "$PROFILE_ENV_SOURCE"
if [ "$BUILD_OVERVIEW_CHAT_UI" -eq 1 ]; then
    bash "$ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"
    bash "$ROOT_DIR/scripts/overview-chat-ui/install-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"
    verify_overview_chat_ui_install
else
    echo "=== Skip atomos-overview-chat-ui (flag enabled) ==="
fi

WALLPAPER_SRC="$ROOT_DIR/data/wallpapers/gargantua-black.jpg"

if [ -n "$WALLPAPER_SRC" ] && [ -f "$WALLPAPER_SRC" ]; then
    COPY_WP='mkdir -p /usr/share/backgrounds/gnome /usr/share/backgrounds/atomos /usr/share/backgrounds && cat > /usr/share/backgrounds/gnome/gargantua-black.jpg && cat /usr/share/backgrounds/gnome/gargantua-black.jpg > /usr/share/backgrounds/gargantua-black.jpg && cat /usr/share/backgrounds/gnome/gargantua-black.jpg > /usr/share/backgrounds/atomos/gargantua-black.jpg'
    pmb chroot -r -- /bin/sh -eu -c "$COPY_WP" < "$WALLPAPER_SRC"
    bash "$ROOT_DIR/scripts/rootfs/apply-atomos-wallpaper-dconf.sh" "$PROFILE_ENV_SOURCE"
fi

bash "$ROOT_DIR/scripts/phosh/apply-atomos-phosh-dconf.sh" "$PROFILE_ENV_SOURCE"
ATOMOS_LOCK_PARITY=1 bash "$ROOT_DIR/scripts/rootfs/apply-overlay.sh" "$PROFILE_ENV_SOURCE"
verify_overview_chat_ui_launcher_contract

echo "=== Resync rootfs and export image ==="
bash "$ROOT_DIR/scripts/rootfs/resync-rootfs-to-disk-image.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/rootfs-diagnostic.sh" "$PROFILE_ENV_SOURCE" || true
bash "$ROOT_DIR/scripts/export/export.sh" "$PROFILE_ENV_SOURCE" "$BUILD_DIR"

echo "Build complete:"
if [ -f "$BUILD_DIR/host-export-${PROFILE_NAME}/boot.img" ]; then
    echo "  $BUILD_DIR/host-export-${PROFILE_NAME}/boot.img"
elif [[ "${PMOS_DEVICE:-}" == qemu-* ]] || [[ "${PMOS_DEVICE:-}" == qemu_* ]]; then
    echo "  $BUILD_DIR/host-export-${PROFILE_NAME}/boot.img (optional; not generated for this QEMU profile)"
fi
echo "  $BUILD_DIR/host-export-${PROFILE_NAME}/${PROFILE_NAME}.img"
