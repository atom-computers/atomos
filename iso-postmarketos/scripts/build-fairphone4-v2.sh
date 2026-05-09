#!/bin/bash
# build-fairphone4-v2.sh -- modular Fairphone 4 image builder.
#
# Same target as build-fairphone4.sh: bootstrap an aarch64 Alpine + pmOS
# rootfs into a docker volume, install AtomOS rust components + vendor
# phosh, and emit fastboot-flashable artifacts (boot.img + sparse
# fairphone-fp4.img) under build/host-export-fairphone-fp4/.
#
# What changed from build-fairphone4.sh:
#   - This script is the orchestrator. Every step is a one-liner that
#     calls a function from a focused library file under scripts/.
#     Total length ~200 lines vs ~1700 in v1.
#   - Vendor phosh is ON BY DEFAULT (matches build-qemu.sh behaviour).
#     Use --without-vendor-phosh to fall back to stock pmOS phosh.
#   - The greetd `ERROR: user.greetd failed to start` boot loop is
#     addressed at the root cause:
#       1. _lib-rootfs-bootstrap.sh now AUDITS the apk install log for
#          `WARNING: failed to execute pre-install` lines and FAILS
#          the build with a named warning, so the silent qemu-user
#          lockfile race that drops greetd's user-creation script
#          stops being silent.
#       2. _lib-rootfs-users.sh creates the greetd system user (and
#          the unprivileged login user) by writing directly to
#          /target/etc/{passwd,group,shadow} from the host shell --
#          no busybox adduser, no qemu binfmt, no lockfile -- and
#          then verifies with `getent` from inside chroot. Hard-fails
#          if the user still misses.
#   - _lib-build-container-body.sh is a real shell file (mounted into
#     the build container) instead of a single-quoted heredoc.
#
# Usage:
#   bash scripts/build-fairphone4-v2.sh [profile-env] \
#       [--without-vendor-phosh] [--without-overview-chat-ui] [--without-home-bg]
#
# Output:
#   build/host-export-fairphone-fp4/boot.img
#   build/host-export-fairphone-fp4/fairphone-fp4.img
#
# Environment overrides:
#   ATOMOS_FP4V2_ALPINE_CONTAINER_IMAGE   base image (default alpine:edge)
#   ATOMOS_FP4V2_PMOS_CHANNEL             pmOS channel/branch (default master)
#   ATOMOS_FP4V2_PMOS_MIRROR              pmOS mirror URL
#   ATOMOS_FP4V2_MESON_CACHE_HOST_DIR     host bind mount for /cache
#   ATOMOS_FP4V2_MESON_CACHE_CLEAN=1      wipe meson/ccache cache
#   ATOMOS_FP4V2_BUILD_ENGINE             docker | podman (auto-detected)
#   ATOMOS_FP4V2_ROOTFS_SIZE_MB           sparse image size override
#   ATOMOS_FP4V2_KEEP_ROOTFS_VOLUME=1     reuse the bootstrapped volume
#   ATOMOS_FP4V2_FRESH_EXPORT=0           do NOT delete prior export images
#                                         (default: delete to avoid flashing
#                                          a stale image after a failed build)
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: build-fairphone4-v2.sh [profile-env] \
    [--without-vendor-phosh] [--without-overview-chat-ui] [--without-home-bg]

Modular Fairphone 4 builder. Defaults: vendor phosh ON, overview-chat-ui ON,
home-bg ON. Outputs build/host-export-fairphone-fp4/{boot.img,fairphone-fp4.img}.
EOF
}

# ---- arg parse --------------------------------------------------------
PROFILE_ENV=""
USE_VENDOR_PHOSH=1
BUILD_OVERVIEW_CHAT_UI=1
BUILD_HOME_BG=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --without-vendor-phosh|--skip-vendor-phosh) USE_VENDOR_PHOSH=0 ;;
        --without-overview-chat-ui|--skip-overview-chat-ui) BUILD_OVERVIEW_CHAT_UI=0 ;;
        --without-home-bg|--skip-home-bg) BUILD_HOME_BG=0 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "ERROR: unknown option: $1" >&2; usage; exit 1 ;;
        *)
            if [ -n "$PROFILE_ENV" ]; then
                echo "ERROR: profile env provided more than once: $1" >&2
                usage; exit 1
            fi
            PROFILE_ENV="$1"
            ;;
    esac
    shift
done
PROFILE_ENV="${PROFILE_ENV:-config/fairphone-fp4.env}"

# ---- paths + libs -----------------------------------------------------
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$ROOT_DIR/scripts"
REPO_TOP="$(cd "$ROOT_DIR/.." && pwd)"

# shellcheck source=scripts/_lib-build-common.sh
source "$LIB_DIR/_lib-build-common.sh"
# shellcheck source=scripts/_lib-engine.sh
source "$LIB_DIR/_lib-engine.sh"
# shellcheck source=scripts/_lib-pmos-repo.sh
source "$LIB_DIR/_lib-pmos-repo.sh"
# shellcheck source=scripts/_lib-deviceinfo.sh
source "$LIB_DIR/_lib-deviceinfo.sh"
# shellcheck source=scripts/_lib-meson-cache.sh
source "$LIB_DIR/_lib-meson-cache.sh"
# shellcheck source=scripts/_lib-rootfs-bootstrap.sh
source "$LIB_DIR/_lib-rootfs-bootstrap.sh"
# shellcheck source=scripts/_lib-rootfs-users.sh
source "$LIB_DIR/_lib-rootfs-users.sh"
# shellcheck source=scripts/_lib-rootfs-init.sh
source "$LIB_DIR/_lib-rootfs-init.sh"
# shellcheck source=scripts/_lib-mkinitfs.sh
source "$LIB_DIR/_lib-mkinitfs.sh"
# shellcheck source=scripts/_lib-build-container.sh
source "$LIB_DIR/_lib-build-container.sh"
# shellcheck source=scripts/_lib-rootfs-overlays.sh
source "$LIB_DIR/_lib-rootfs-overlays.sh"
# shellcheck source=scripts/_lib-greetd-guarantee.sh
source "$LIB_DIR/_lib-greetd-guarantee.sh"
# shellcheck source=scripts/_lib-verify.sh
source "$LIB_DIR/_lib-verify.sh"
# shellcheck source=scripts/_lib-bootimg.sh
source "$LIB_DIR/_lib-bootimg.sh"
# shellcheck source=scripts/_lib-pack-sparse.sh
source "$LIB_DIR/_lib-pack-sparse.sh"

# ---- profile env ------------------------------------------------------
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

if [ -z "${PROFILE_NAME:-}" ]; then
    echo "ERROR: PROFILE_NAME missing in $PROFILE_ENV_SOURCE" >&2
    exit 2
fi
if [ "${PMOS_DEVICE:-}" != "fairphone-fp4" ]; then
    echo "ERROR: PMOS_DEVICE='${PMOS_DEVICE:-}' (expected 'fairphone-fp4')." >&2
    exit 2
fi
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: build-fairphone4-v2.sh requires a Linux host (loop devices + privileged container)." >&2
    exit 2
fi

# ---- globals expected by libs -----------------------------------------
BUILD_DIR="$ROOT_DIR/build"
EXPORT_DIR="$BUILD_DIR/host-export-${PROFILE_NAME}"
WORK_DIR="$BUILD_DIR/fairphone4-v2-${PROFILE_NAME}"
BOOT_IMG_PATH="$EXPORT_DIR/boot.img"
ROOTFS_IMG_PATH="$EXPORT_DIR/${PROFILE_NAME}.img"
ALPINE_IMAGE="${ATOMOS_FP4V2_ALPINE_CONTAINER_IMAGE:-alpine:edge}"
PMOS_CHANNEL="${ATOMOS_FP4V2_PMOS_CHANNEL:-master}"
PMOS_MIRROR="${ATOMOS_FP4V2_PMOS_MIRROR:-https://mirror.postmarketos.org/postmarketos/}"
INSTALL_PASSWORD="${PMOS_INSTALL_PASSWORD:-147147}"
PMOS_USER_UID="${PMOS_USER_UID:-10000}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
ROOTFS_VOLUME="atomos-fp4v2-rootfs-${PROFILE_NAME}"
MESON_CACHE_HOST_DIR="${ATOMOS_FP4V2_MESON_CACHE_HOST_DIR:-}"
MESON_CACHE_CLEAN="${ATOMOS_FP4V2_MESON_CACHE_CLEAN:-0}"
ROOTFS_SIZE_MB="${ATOMOS_FP4V2_ROOTFS_SIZE_MB:-}"

mkdir -p "$EXPORT_DIR" "$WORK_DIR"

# ---- fresh-export gate ------------------------------------------------
# Mirrors d6405345 ATOMOS_FRESH_ROOTFS_IMAGES behaviour:
# delete previous boot.img and fairphone-fp4.img up front so a failed
# build never leaves a stale image that the user might flash by mistake.
if [ "${ATOMOS_FP4V2_FRESH_EXPORT:-1}" = "1" ]; then
    for stale in \
        "$EXPORT_DIR/boot.img" \
        "$EXPORT_DIR/fairphone-fp4.img" \
        "$EXPORT_DIR/fairphone-fp4.img.partial"
    do
        if [ -f "$stale" ]; then
            echo "build-fairphone4-v2: removing prior export $stale"
            rm -f "$stale"
        fi
    done
fi

# ---- engine selection -------------------------------------------------
atomos_require_tools
ENGINE="${ATOMOS_FP4V2_BUILD_ENGINE:-$(atomos_find_container_engine)}"
if [ -z "$ENGINE" ]; then
    echo "ERROR: docker or podman is required for FP4 image build." >&2
    exit 2
fi

# ---- volume cleanup gate (cached rootfs across iterations) ------------
cleanup_volume() {
    if [ "${ATOMOS_FP4V2_KEEP_ROOTFS_VOLUME:-0}" = "1" ]; then
        echo "build-fairphone4-v2: keeping rootfs volume $ROOTFS_VOLUME (KEEP=1)"
        return 0
    fi
    atomos_cleanup_volume "$ENGINE" "$ROOTFS_VOLUME"
}
trap cleanup_volume EXIT
cleanup_volume
"$ENGINE" volume create "$ROOTFS_VOLUME" >/dev/null

# ---- the actual pipeline (one line per phase) -------------------------
atomos_pmos_setup
atomos_deviceinfo_setup
atomos_meson_cache_setup

# pmbootstrap-faithful order: pmb.chroot.init creates a minimal Alpine
# chroot first (alpine-baselayout, apk-tools, busybox, musl-utils),
# THEN set_user(config) creates uid 10000 in /etc/passwd, THEN
# pmb.chroot.apk.install does the full install. This ordering is
# explicitly documented in pmb/install/_install.py:1273 ("legacy
# reasons: pmaports#820"). post-installs that do
#   default_user=$(getent passwd "10000" | cut -d: -f1)
#   usermod -aG <group> "$default_user"
# only work when uid 10000 already exists at apk-install time.
atomos_bootstrap_minimal                # Phase 1: minimal Alpine chroot
atomos_ensure_system_users              # Phase 2: create user 10000 + greetd BEFORE full install
atomos_bootstrap_full                   # Phase 3: install everything else
atomos_mkinitfs_fixup                   # Phase 3.5: regen initramfs (device-fairphone-fp4 added kernel)
atomos_init_rootfs_basics               # Phase 4: hostname/fstab/runlevels/overlay drops
atomos_build_heavy_components           # Phase 5: vendor phosh + Rust components
atomos_apply_overlays                   # Phase 6: AtomOS overlay installers
atomos_greetd_guarantee post-overlays   # belt: defend against any overlay regression
atomos_verify_rootfs                    # Phase 7: final verification
atomos_export_bootimg                   # Phase 8: boot.img
atomos_assert_prepack_invariants        # Phase 8.5
atomos_greetd_guarantee pre-pack        # braces: last sweep before sparse image lands
atomos_pack_sparse_rootfs               # Phase 9: sparse rootfs image
atomos_normalize_export_ownership

cat <<EOF

Build complete:
EOF
# Print fresh timestamps so user can confirm they aren't about to flash
# a stale artifact left over from a prior build (mtime in local TZ).
for img in "$BOOT_IMG_PATH" "$ROOTFS_IMG_PATH"; do
    if [ -f "$img" ]; then
        ts=$(date -r "$img" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown)
        sz=$(ls -lh "$img" 2>/dev/null | awk '{print $5}')
        printf '  %s   (%s, %s)\n' "$img" "$ts" "${sz:-?}"
    else
        printf '  %s   (MISSING -- build did not produce this file!)\n' "$img" >&2
    fi
done
cat <<EOF

Flash with fastboot (device in bootloader):
  fastboot flash boot     $BOOT_IMG_PATH
  fastboot flash userdata $ROOTFS_IMG_PATH

  (BOTH must be flashed; a stale boot.img against a new userdata image
  will silently boot the OLD initramfs and you will see no behavioural
  change from the latest fixes.)
EOF
