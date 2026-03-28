#!/bin/bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [profile-env]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ENV="${1:-config/fairphone-fp4.env}"
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

export PATH="$HOME/.local/bin:$PATH"
bash "$ROOT_DIR/scripts/pmb/ensure-pmbootstrap.sh"

echo "=== Sync vendor Phosh sources ==="
bash "$ROOT_DIR/scripts/phosh/checkout-phosh.sh"

if [ -n "${SUDO_USER:-}" ]; then
    BASE_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
    BASE_HOME="$HOME"
fi

export PMB_WORK_OVERRIDE="${BASE_HOME}/.atomos-pmbootstrap-work/${PROFILE_NAME}"
CFG="${BASE_HOME}/.config/pmbootstrap_v3.cfg"
PMAPORTS_CACHE="${BASE_HOME}/.local/var/pmbootstrap/cache_git/pmaports"
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

if [ "$PMOS_UI" = "phosh" ]; then
    bash "$ROOT_DIR/scripts/pmb/set-container-provider.sh" "$CFG" "postmarketos-base-ui-audio-backend" "pipewire"
    ensure_native_abuild_keys
    bash "$ROOT_DIR/scripts/phosh/build-atomos-phosh-pmbootstrap.sh" "$PROFILE_ENV_SOURCE"
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

pmb install --password "$PMOS_INSTALL_PASSWORD" --add "$EXTRA_PACKAGES_EFFECTIVE"

echo "=== Apply AtomOS rootfs customizations ==="
bash "$ROOT_DIR/scripts/rootfs/wire-custom-apk-repos.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/install-btlescan.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/install-bt-tools.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/overview-chat-ui/install-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"

WALLPAPER_SRC="$ROOT_DIR/data/wallpapers/gargantua-black.jpg"

if [ -n "$WALLPAPER_SRC" ] && [ -f "$WALLPAPER_SRC" ]; then
    COPY_WP='mkdir -p /usr/share/backgrounds/gnome /usr/share/backgrounds/atomos /usr/share/backgrounds && cat > /usr/share/backgrounds/gnome/gargantua-black.jpg && cat /usr/share/backgrounds/gnome/gargantua-black.jpg > /usr/share/backgrounds/gargantua-black.jpg && cat /usr/share/backgrounds/gnome/gargantua-black.jpg > /usr/share/backgrounds/atomos/gargantua-black.jpg'
    pmb chroot -r -- /bin/sh -eu -c "$COPY_WP" < "$WALLPAPER_SRC"
    bash "$ROOT_DIR/scripts/rootfs/apply-atomos-wallpaper-dconf.sh" "$PROFILE_ENV_SOURCE"
fi

bash "$ROOT_DIR/scripts/phosh/apply-atomos-phosh-dconf.sh" "$PROFILE_ENV_SOURCE"
ATOMOS_LOCK_PARITY=1 bash "$ROOT_DIR/scripts/rootfs/apply-overlay.sh" "$PROFILE_ENV_SOURCE"

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
