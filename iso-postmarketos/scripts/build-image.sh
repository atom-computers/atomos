#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: build-image.sh [profile-env] [--without-overview-chat-ui] [--without-home-bg]

Options:
  --without-overview-chat-ui, --skip-overview-chat-ui
      Skip building/installing atomos-overview-chat-ui during image build.
  --without-home-bg, --skip-home-bg
      Skip building/installing atomos-home-bg during image build.
EOF
}

PROFILE_ENV=""
BUILD_OVERVIEW_CHAT_UI=1
BUILD_HOME_BG=1

while [ "$#" -gt 0 ]; do
    case "$1" in
        --without-overview-chat-ui|--skip-overview-chat-ui)
            BUILD_OVERVIEW_CHAT_UI=0
            ;;
        --without-home-bg|--skip-home-bg)
            BUILD_HOME_BG=0
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

clear_legacy_gsd_config_provider() {
    local cfg_file="$1"
    python3 - "$cfg_file" <<'PY'
import configparser
import os
import sys

cfg_file = sys.argv[1]
if not os.path.exists(cfg_file):
    raise SystemExit(0)

cfg = configparser.ConfigParser()
cfg.read(cfg_file)
if not cfg.has_section("providers"):
    raise SystemExit(0)

changed = False
for key in ("gnome-settings-daemon", "gnome-settings-daemon-mobile"):
    if cfg.remove_option("providers", key):
        changed = True

if changed:
    with open(cfg_file, "w", encoding="utf-8") as f:
        cfg.write(f)
    print("Cleared legacy gnome-settings-daemon provider override(s).")
PY
}

clear_legacy_gsd_world_entries() {
    set +e
    pmb chroot -r -- /bin/sh -eu -c '
        world=/etc/apk/world
        [ -f "$world" ] || exit 0
        tmp="${world}.atomos.tmp"
        grep -Ev "^(gnome-settings-daemon|gnome-settings-daemon-mobile)$" "$world" > "$tmp" || true
        mv "$tmp" "$world"
    ' >/dev/null 2>&1
    set -e
}

prepare_rootfs_systemd_apk_state() {
    # Stale rootfs chroots can keep wrong ownership/mode on /var/lib/systemd-apk.
    # postmarketos-base-systemd pre-commit hooks require this path writable.
    set +e
    pmb chroot -r -- /bin/sh -eu -c '
        mkdir -p /var/lib/systemd-apk
        chown root:root /var /var/lib /var/lib/systemd-apk 2>/dev/null || true
        chmod 755 /var /var/lib /var/lib/systemd-apk 2>/dev/null || true
        install -m 644 -o root -g root /dev/null /var/lib/systemd-apk/installed.units
    ' >/dev/null 2>&1
    set -e
}

cleanup_stale_dynamic_partition_mappers() {
    command -v dmsetup >/dev/null 2>&1 || return 0
    local mapper_name mapper_dev
    while IFS= read -r mapper_name; do
        [ -n "$mapper_name" ] || continue
        mapper_dev="/dev/mapper/${mapper_name}"
        if grep -q " ${mapper_dev} " /proc/mounts 2>/dev/null; then
            continue
        fi
        sudo dmsetup remove "$mapper_name" >/dev/null 2>&1 || sudo dmsetup remove -f "$mapper_name" >/dev/null 2>&1 || true
    done < <(
        dmsetup ls --target linear 2>/dev/null \
            | sed -n 's/^\([^[:space:]]\+\).*/\1/p' \
            | sed -n '/^\(system\|system_ext\|product\|vendor\|odm\|vendor_dlkm\|system_dlkm\|odm_dlkm\)_[ab]$/p'
    )
}

verify_vendor_phosh_source_contract() {
    if [ "$PMOS_UI" != "phosh" ] || [ "$USE_VENDOR_PHOSH" != "1" ]; then
        return 0
    fi
    local src_dir="$ROOT_DIR/rust/phosh/phosh"
    [ -d "$src_dir" ] || return 0
    echo "=== Verify local Phosh fork source tree ==="
    test -f "$src_dir/meson.build"
    test -f "$src_dir/src/home.c"
    test -f "$src_dir/src/ui/home.ui"
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

apply_mkinitfs_subpartition_dm_compat_in_pmaports_cache() {
    if [ "${ATOMOS_MKINITFS_SUBPARTITION_DM_COMPAT_PATCH:-1}" != "1" ]; then
        return 0
    fi
    if [ ! -d "$PMAPORTS_CACHE" ]; then
        return 0
    fi

    local matches changed=0 f
    matches="$(rg -l "Mount subpartitions of|failed to mount subpartitions" "$PMAPORTS_CACHE" || true)"
    if [ -z "$matches" ]; then
        return 0
    fi

    echo "Applying mkinitfs subpartition dm compatibility patch in pmaports cache..."
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        _patch_result="$(python3 - "$f" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "# ATOMOS_DYN_PART_DM_CLEANUP_BEGIN"
if marker in text:
    print("UNCHANGED")
    raise SystemExit(0)

needle = 'echo "Mount subpartitions of '
idx = text.find(needle)
if idx == -1:
    print("UNCHANGED")
    raise SystemExit(0)

snippet = """# ATOMOS_DYN_PART_DM_CLEANUP_BEGIN
if command -v dmsetup >/dev/null 2>&1; then
    for _atomos_part in system system_ext product vendor odm vendor_dlkm system_dlkm odm_dlkm; do
        for _atomos_slot in a b; do
            _atomos_map="${_atomos_part}_${_atomos_slot}"
            if [ -e "/dev/mapper/${_atomos_map}" ] && ! grep -q " /dev/mapper/${_atomos_map} " /proc/mounts 2>/dev/null; then
                dmsetup remove "${_atomos_map}" 2>/dev/null || dmsetup remove -f "${_atomos_map}" 2>/dev/null || true
            fi
        done
    done
fi
# ATOMOS_DYN_PART_DM_CLEANUP_END
"""

text = text[:idx] + snippet + text[idx:]
path.write_text(text, encoding="utf-8")
print("PATCHED")
PY
)"
        if [ "$_patch_result" = "PATCHED" ]; then
            changed=1
        fi
    done <<EOF
$matches
EOF

    if [ "$changed" -eq 1 ]; then
        echo "Patched mkinitfs subpartition mount hook(s) in pmaports cache."
    fi
}

export PATH="$HOME/.local/bin:$PATH"
bash "$ROOT_DIR/scripts/pmb/ensure-pmbootstrap.sh"

USE_VENDOR_PHOSH=0
if [ "$PMOS_UI" = "phosh" ]; then
    USE_VENDOR_PHOSH=1
    case "${PMOS_DEVICE:-}" in
        fairphone-fp4)
            if [ "${ATOMOS_ENABLE_VENDOR_PHOSH_ON_FP4:-0}" = "1" ] || [ "${ATOMOS_ENABLE_VENDOR_PHOSH:-0}" = "1" ]; then
                # Keep parity with QEMU: vendor phosh is opt-in.
                export ATOMOS_SKIP_VENDOR_PHOSH_BUILD=0
                echo "=== FP4 profile detected; vendor phosh enabled by opt-in flag. ==="
            elif [ "${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" != "1" ]; then
                echo "=== FP4 profile detected; defaulting to stock phosh (skip vendor phosh build). ==="
                echo "    Set ATOMOS_ENABLE_VENDOR_PHOSH_ON_FP4=1 or ATOMOS_ENABLE_VENDOR_PHOSH=1 to opt in to patched vendor phosh on FP4."
                export ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1
            fi
            ;;
        qemu-*|qemu_*)
            if [ "${ATOMOS_ENABLE_VENDOR_PHOSH:-0}" != "1" ] && [ "${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" != "1" ]; then
                echo "=== QEMU profile detected; defaulting to stock phosh (skip vendor phosh build). ==="
                echo "    Set ATOMOS_ENABLE_VENDOR_PHOSH=1 to opt in to patched vendor phosh on QEMU."
                export ATOMOS_SKIP_VENDOR_PHOSH_BUILD=1
            fi
            ;;
    esac
    if [ "${ATOMOS_SKIP_VENDOR_PHOSH_BUILD:-0}" = "1" ]; then
        USE_VENDOR_PHOSH=0
    fi
fi

if [ "$USE_VENDOR_PHOSH" = "1" ]; then
    if [ -z "${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT:-}" ]; then
        export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT=0
        echo "=== Defaulting ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT to $ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT ==="
    fi
    echo "=== Sync local Phosh fork sources ==="
    bash "$ROOT_DIR/scripts/phosh/checkout-phosh.sh"
    verify_vendor_phosh_source_contract
else
    echo "=== Skip local Phosh fork sync (stock phosh mode) ==="
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
# Older runs could leave a stale gnome-settings-daemon provider override in
# pmbootstrap config, which later forces conflicting world resolution in chroots.
clear_legacy_gsd_config_provider "$CFG"
pin_pmaports_commit
apply_mkinitfs_udev_compat_in_pmaports_cache
apply_mkinitfs_subpartition_dm_compat_in_pmaports_cache

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

# Stale rootfs chroots accumulate broken state (wrong permissions, half-installed
# packages, leftover commit-hook artifacts) across failed builds.  Delete the
# rootfs chroot directory so `pmb install` bootstraps a clean one every time.
if [ -d "${PMB_WORK_OVERRIDE}/chroot_rootfs_${PMOS_DEVICE}" ]; then
    echo "=== ATOMOS: removing stale rootfs chroot for clean install ==="
    sudo rm -rf "${PMB_WORK_OVERRIDE}/chroot_rootfs_${PMOS_DEVICE}"
fi

# img2simg runs as pmos in the native chroot and writes to /home/pmos/rootfs/.
# Stale builds can leave this directory root-owned, causing "Cannot open output
# file" failures at the sparse-image step.
prepare_native_rootfs_output_permissions() {
    pmb chroot -- /bin/sh -eu -c '
        mkdir -p /home/pmos/rootfs
        # Make directory recursively writable by pmos and clear stale sparse
        # outputs that may be root-owned from interrupted installs.
        chown -R pmos:pmos /home/pmos/rootfs || true
        chmod -R u+rwX /home/pmos/rootfs || true
        rm -f /home/pmos/rootfs/*-sparse.img || true
    '
}
prepare_native_rootfs_output_permissions

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

verify_home_bg_install() {
    echo "=== Verify atomos-home-bg install in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c \
        'test -x /usr/local/bin/atomos-home-bg && test -x /usr/bin/atomos-home-bg && test -x /usr/libexec/atomos-home-bg && test -d /usr/share/atomos-home-bg'
}

# Final rootfs assertion right before resync: prove that the rootfs chroot
# actually carries the AtomOS-patched vendor phosh + the Rust binaries we
# expect to ship. Without this, silent package-solver regressions between
# promote_local_vendor_phosh_into_rootfs and resync (e.g.
# install-atomos-agents.sh:59 `apk upgrade --no-interactive` re-solving the
# world and replacing our phosh with upstream) produce a stock-phosh image
# without any build-time error. This turns that failure mode into a hard
# exit 9 with a precise diagnostic.
verify_final_rootfs_customizations() {
    echo "=== Final rootfs verification (pre-resync) ==="
    local must_have_overview="${BUILD_OVERVIEW_CHAT_UI:-1}"
    local must_have_home_bg="${BUILD_HOME_BG:-1}"
    local must_have_vendor_phosh="${USE_VENDOR_PHOSH:-0}"
    pmb chroot -r -- /bin/sh -eu -c '
        fail=0
        if [ "'"$must_have_vendor_phosh"'" = "1" ]; then
            if ! test -x /usr/libexec/phosh; then
                echo "FINAL-VERIFY FAIL: /usr/libexec/phosh missing" >&2
                fail=1
            else
                # Two independent vendor-phosh signals. EITHER is sufficient;
                # we only fail if BOTH are absent.
                #
                # (1) Installed pkgver carries a `_p<digits>` suffix that
                #     abuild stamps on `pmbootstrap build --src=...` builds
                #     but NEVER on stock Alpine edge phosh. This is the
                #     strongest possible signal: it comes from apk'"'"'s
                #     installed-package database, not from guessing the
                #     binary content.
                #
                # (2) strings(1) of /usr/libexec/phosh finds one of the
                #     AtomOS markers. `atomos-overview-chat-submit` is the
                #     most reliable here because it is a string literal in
                #     the C source (spawn argv), so the compiler embeds it
                #     directly in .rodata where `strings` can see it even
                #     after -O2 / strip. The two GtkBuilder widget ids
                #     `atomos-home-chat-entry` and `atomos-apps-toggle`
                #     live inside the embedded .gresource bundle which is
                #     gzip-compressed by default on Alpine, so `strings`
                #     cannot see them without decompressing the resource
                #     blob first. We keep them as a best-effort bonus but
                #     do NOT require them.
                installed_ver=""
                if command -v apk >/dev/null 2>&1; then
                    # `apk info -v phosh` emits e.g. "phosh-0.54.0_p20260422014925-r0".
                    installed_ver="$(apk info -v phosh 2>/dev/null | sed -n "s/^phosh-//p")"
                fi
                pkgver_has_p_suffix=0
                case "$installed_ver" in
                    *_p[0-9]*) pkgver_has_p_suffix=1 ;;
                esac

                strings_has_submit=0
                if command -v strings >/dev/null 2>&1; then
                    if strings /usr/libexec/phosh 2>/dev/null | grep -q "atomos-overview-chat-submit"; then
                        strings_has_submit=1
                    fi
                fi

                # Best-effort diagnostic for the two gresource markers; not
                # required, just logged so we can see what got picked up.
                gresource_markers=""
                if command -v strings >/dev/null 2>&1; then
                    for marker in atomos-home-chat-entry atomos-apps-toggle; do
                        if strings /usr/libexec/phosh 2>/dev/null | grep -q "$marker"; then
                            gresource_markers="${gresource_markers} ${marker}"
                        fi
                    done
                fi

                if [ "$pkgver_has_p_suffix" -eq 1 ] || [ "$strings_has_submit" -eq 1 ]; then
                    echo "final-verify: vendor phosh confirmed"
                    echo "  installed pkgver: ${installed_ver:-<apk-info-unavailable>} (has _p<timestamp> suffix: $pkgver_has_p_suffix)"
                    echo "  strings atomos-overview-chat-submit marker: $strings_has_submit"
                    if [ -n "$gresource_markers" ]; then
                        echo "  bonus gresource-visible markers detected:${gresource_markers}"
                    else
                        echo "  gresource-embedded widget ids (atomos-home-chat-entry / atomos-apps-toggle) not visible via strings - expected when .gresource is gzip-compressed; ignore."
                    fi
                else
                    echo "FINAL-VERIFY FAIL: /usr/libexec/phosh does not look like the AtomOS vendor build." >&2
                    echo "  installed pkgver: ${installed_ver:-<apk-info-unavailable>}" >&2
                    echo "  pkgver _p<timestamp> suffix: $pkgver_has_p_suffix (expected 1)" >&2
                    echo "  strings atomos-overview-chat-submit marker: $strings_has_submit (expected 1)" >&2
                    echo "  Vendor phosh was promoted earlier but subsequently replaced." >&2
                    echo "  Re-run make build-qemu, or set ATOMOS_SKIP_FINAL_VERIFY=1 to downgrade to WARN." >&2
                    fail=1
                fi
            fi
        fi
        if [ "'"$must_have_overview"'" = "1" ]; then
            for p in /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui /usr/libexec/atomos-overview-chat-ui /usr/libexec/atomos-overview-chat-submit; do
                if ! test -x "$p"; then
                    echo "FINAL-VERIFY FAIL: $p missing" >&2
                    fail=1
                fi
            done
            [ "$fail" -eq 0 ] && echo "final-verify: atomos-overview-chat-ui binary + launcher + submit helper present"
        fi
        if [ "'"$must_have_home_bg"'" = "1" ]; then
            for p in /usr/local/bin/atomos-home-bg /usr/bin/atomos-home-bg /usr/libexec/atomos-home-bg; do
                if ! test -x "$p"; then
                    echo "FINAL-VERIFY FAIL: $p missing" >&2
                    fail=1
                fi
            done
            if ! test -d /usr/share/atomos-home-bg; then
                echo "FINAL-VERIFY FAIL: /usr/share/atomos-home-bg missing" >&2
                fail=1
            fi
            [ "$fail" -eq 0 ] && echo "final-verify: atomos-home-bg binary + launcher + content dir present"
        fi
        if [ "$fail" -ne 0 ]; then
            if [ "${ATOMOS_SKIP_FINAL_VERIFY:-0}" = "1" ]; then
                echo "WARN: final rootfs verification failed; continuing because ATOMOS_SKIP_FINAL_VERIFY=1." >&2
                exit 0
            fi
            exit 9
        fi
    '
}

verify_home_bg_launcher_contract() {
    echo "=== Verify atomos-home-bg launcher contract in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c '
        test -x /usr/libexec/atomos-home-bg
        grep -q "ATOMOS_HOME_BG_ENABLE_RUNTIME" /usr/libexec/atomos-home-bg
        grep -q "atomos-home-bg.disabled" /usr/libexec/atomos-home-bg
        grep -q "ATOMOS_HOME_BG_LAYER" /usr/libexec/atomos-home-bg
        grep -q "ATOMOS_HOME_BG_INTERACTIVE" /usr/libexec/atomos-home-bg
    '
}

verify_overview_chat_ui_launcher_contract() {
    echo "=== Verify atomos-overview-chat-ui launcher contract in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c "
        test -x /usr/libexec/atomos-overview-chat-ui
        grep -q "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME" /usr/libexec/atomos-overview-chat-ui
        grep -q "atomos-overview-chat-ui.disabled" /usr/libexec/atomos-overview-chat-ui
        grep -q "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS" /usr/libexec/atomos-overview-chat-ui
        test -f /etc/atomos/overview-chat-ui-overlay-contract
        grep -q "overview-chat-ui-overlay-v5-lifecycle-only" /etc/atomos/overview-chat-ui-overlay-contract
        test ! -e /etc/xdg/autostart/atomos-overview-chat-ui.desktop
        test ! -e /usr/libexec/atomos-overview-chat-ui-boot
        test ! -e /usr/lib/systemd/user/atomos-overview-chat-ui.service
        test ! -e /etc/systemd/user/default.target.wants/atomos-overview-chat-ui.service
        test ! -e /etc/atomos/overview-chat-ui-always-on
    "
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

verify_vendor_phosh_origin() {
    if [ "$PMOS_UI" != "phosh" ] || [ "$USE_VENDOR_PHOSH" != "1" ]; then
        return 0
    fi
    echo "=== Verify vendor phosh package origin in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c '
        test -x /usr/libexec/phosh
        # Ensure rootfs picks up the newest locally-built vendor phosh package.
        apk add --upgrade phosh >/dev/null
        policy="$(apk policy phosh phoc phosh-mobile-settings 2>/dev/null || true)"
        printf "%s\n" "$policy"
        local_repo=0
        if printf "%s\n" "$policy" | grep -Eq "/(mnt/pmbootstrap|home/pmos)/packages/"; then
            local_repo=1
        fi
        installed_ver="$(printf "%s\n" "$policy" | awk '"'"'
            /phosh policy:/ { in_policy=1; next }
            in_policy && $1 ~ /^[0-9]/ { ver=$1; sub(":", "", ver) }
            in_policy && /lib\/apk\/db\/installed/ { print ver; exit }
        '"'"')"
        latest_local_ver="$(printf "%s\n" "$policy" | awk '"'"'
            /phosh policy:/ { in_policy=1; next }
            in_policy && $1 ~ /^[0-9]/ { ver=$1; sub(":", "", ver) }
            in_policy && /\/(mnt\/pmbootstrap|home\/pmos)\/packages\// { latest=ver }
            END { print latest }
        '"'"')"
        if [ "$local_repo" -eq 1 ] && [ -n "$latest_local_ver" ] && [ "$installed_ver" != "$latest_local_ver" ]; then
            echo "ERROR: installed phosh version ($installed_ver) is not newest local vendor build ($latest_local_ver)." >&2
            exit 4
        fi
        marker_ok=0
        set +e
        if command -v gresource >/dev/null 2>&1; then
            gresource list /usr/libexec/phosh >/dev/null 2>&1
            gresource_capable=$?
            if [ "$gresource_capable" -eq 0 ]; then
                gresource extract /usr/libexec/phosh /mobi/phosh/ui/home.ui \
                    | grep -q "home_chat_entry"
                home_ui_check=$?
                gresource extract /usr/libexec/phosh /mobi/phosh/ui/app-grid.ui \
                    | grep -q "atomos_apps_toggle_btn"
                app_grid_ui_check=$?
                if [ "$home_ui_check" -eq 0 ] && [ "$app_grid_ui_check" -eq 0 ]; then
                    marker_ok=1
                    echo "vendor phosh compiled UI markers detected via gresource."
                fi
            else
                echo "WARN: gresource lacks ELF support in rootfs; skipping compiled UI marker check." >&2
            fi
        else
            echo "WARN: gresource unavailable; skipping compiled UI marker check." >&2
        fi
        if [ "$marker_ok" -ne 1 ] && command -v strings >/dev/null 2>&1; then
            # Binary string retention can vary with compiler/strip settings.
            strings /usr/libexec/phosh | grep -q "atomos-overview-chat-submit"
            has_submit_marker=$?
            strings /usr/libexec/phosh | grep -q "atomos-home-chat-entry"
            has_home_marker=$?
            strings /usr/libexec/phosh | grep -q "atomos-apps-toggle"
            has_toggle_marker=$?
            if [ "$has_submit_marker" -eq 0 ] && [ "$has_home_marker" -eq 0 ] && [ "$has_toggle_marker" -eq 0 ]; then
                marker_ok=1
                echo "vendor phosh marker strings detected in binary."
            fi
        fi
        set -e
        if [ "$local_repo" -ne 1 ]; then
            if [ "$marker_ok" -eq 1 ]; then
                echo "WARN: vendor phosh did not resolve from local repo path, but installed binary contains AtomOS markers; continuing." >&2
            else
                echo "WARN: vendor phosh origin could not be proven (no local repo path, no detectable markers); continuing for diagnostic builds." >&2
            fi
        fi
    '
}

# Stage the locally-built vendor phosh/phoc/phosh-mobile-settings APK
# artifacts directly into the rootfs chroot filesystem at
# /tmp/atomos-vendor-phosh/ from the HOST, bypassing pmbootstrap bind-mount
# semantics.
#
# Background: pmbootstrap 3.9 bind-mounts <WORK>/packages to
# /mnt/pmbootstrap/packages only during its `install` command, NOT for
# subsequent `chroot -r` invocations. That means the APK files
# `recover_edge_repo_from_any_local_phosh_artifacts` wrote to the host at
# <WORK>/packages/edge/<arch>/phosh-*.apk are INVISIBLE from inside the
# rootfs chroot where promote_local_vendor_phosh_into_rootfs runs.
#
# Fix: on the host, walk every place pmbootstrap / the recovery helpers
# could have dropped the APK (host workdir, native chroot, buildroot
# chroot) and copy the newest build-version-matching files straight into
# <PMB_WORK>/chroot_rootfs_<device>/tmp/atomos-vendor-phosh/ via plain
# filesystem I/O + sudo. promote_local_vendor_phosh_into_rootfs then finds
# them at /tmp/atomos-vendor-phosh/ inside the chroot and
# `apk add --upgrade --allow-untrusted` the whole set in one transaction.
stage_vendor_phosh_apks_into_rootfs_chroot() {
    if [ "$PMOS_UI" != "phosh" ] || [ "$USE_VENDOR_PHOSH" != "1" ]; then
        return 0
    fi
    if [ -z "${PMB_WORK_OVERRIDE:-}" ]; then
        echo "stage_vendor_phosh_apks_into_rootfs_chroot: WARN PMB_WORK_OVERRIDE unset; skipping" >&2
        return 0
    fi
    local chroot_root stage_host_path arch
    chroot_root="${PMB_WORK_OVERRIDE}/chroot_rootfs_${PMOS_DEVICE}"
    if [ ! -d "$chroot_root" ]; then
        echo "stage_vendor_phosh_apks_into_rootfs_chroot: WARN rootfs chroot not found at $chroot_root; skipping" >&2
        return 0
    fi
    arch="${ATOMOS_PHOSH_BUILD_ARCH:-aarch64}"
    stage_host_path="${chroot_root}/tmp/atomos-vendor-phosh"

    # Candidate source dirs on the HOST, in the order the newest-wins logic
    # below walks them. Cover every layout we have ever observed from
    # pmb+abuild (host workdir, native chroot, buildroot chroot).
    local -a search_dirs=(
        "${PMB_WORK_OVERRIDE}/packages/edge/${arch}"
        "${PMB_WORK_OVERRIDE}/packages/pmos/${arch}"
        "${PMB_WORK_OVERRIDE}/packages/edge/pmos/${arch}"
        "${PMB_WORK_OVERRIDE}/packages/systemd-edge/${arch}"
        "${PMB_WORK_OVERRIDE}/chroot_native/home/pmos/packages/edge/${arch}"
        "${PMB_WORK_OVERRIDE}/chroot_native/home/pmos/packages/pmos/${arch}"
        "${PMB_WORK_OVERRIDE}/chroot_native/home/pmos/packages/edge/pmos/${arch}"
        "${PMB_WORK_OVERRIDE}/chroot_buildroot_${arch}/home/pmos/packages/edge/${arch}"
        "${PMB_WORK_OVERRIDE}/chroot_buildroot_${arch}/home/pmos/packages/pmos/${arch}"
        "${PMB_WORK_OVERRIDE}/chroot_buildroot_${arch}/home/pmos/packages/edge/pmos/${arch}"
    )

    _atomos_find_newest_apk_for_pkg() {
        local pkg="$1" latest="" d f
        for d in "${search_dirs[@]}"; do
            [ -d "$d" ] || continue
            for f in "$d"/"${pkg}"-*.apk; do
                [ -f "$f" ] || continue
                if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then
                    latest="$f"
                fi
            done
        done
        printf '%s' "$latest"
    }

    # pmbootstrap build --src=rust/phosh/phosh --force phosh produces the
    # whole phosh subpackage set for the build's pkgver timestamp (phosh +
    # libphosh + phosh-schemas + phosh-systemd + phosh-portalsconf +
    # phosh-lang + phosh-doc + phosh-dev + libphosh-dev + phosh-dbg). Stage
    # every subpackage we can find from the same source dir, so apk add
    # --upgrade installs a consistent version set instead of leaving the
    # rootfs with a mix of 0.54.0_p<ts>-r0 (our phosh) and 0.54.0-r0 (stock
    # phosh-schemas/phosh-systemd/...). phoc and phosh-mobile-settings are
    # SEPARATE pmaports packages that our --src=phosh build does NOT produce;
    # their entries below are best-effort and will be empty in the default
    # pipeline, which is correct (stock phoc is untouched by AtomOS's
    # modifications; the AtomOS markers live in phosh proper).
    local phosh_src
    phosh_src="$(_atomos_find_newest_apk_for_pkg phosh)"

    if [ -z "$phosh_src" ]; then
        echo "stage_vendor_phosh_apks_into_rootfs_chroot: no local phosh-*.apk found under host workdir" >&2
        echo "  searched:" >&2
        local d
        for d in "${search_dirs[@]}"; do
            echo "    $d (exists: $( [ -d "$d" ] && echo yes || echo no ))" >&2
        done
        return 0
    fi

    local phosh_base phosh_ver
    phosh_base="$(basename "$phosh_src")"
    phosh_ver="${phosh_base#phosh-}"
    phosh_ver="${phosh_ver%.apk}"

    local -a runner=()
    if ! mkdir -p "$stage_host_path" 2>/dev/null; then
        if command -v sudo >/dev/null 2>&1; then
            runner=(sudo)
            sudo mkdir -p "$stage_host_path"
        else
            echo "stage_vendor_phosh_apks_into_rootfs_chroot: WARN cannot create $stage_host_path and sudo unavailable; skipping" >&2
            return 0
        fi
    fi
    "${runner[@]}" rm -f "$stage_host_path"/*.apk 2>/dev/null || true

    local -a pkg_candidates=(
        phosh
        libphosh
        phosh-schemas
        phosh-systemd
        phosh-portalsconf
        phosh-lang
        phosh-doc
        phosh-dev
        libphosh-dev
        phosh-dbg
        phoc
        phosh-mobile-settings
    )

    local staged=""
    local pkg src candidate_exact
    for pkg in "${pkg_candidates[@]}"; do
        src=""
        for d in "${search_dirs[@]}"; do
            [ -d "$d" ] || continue
            candidate_exact="$d/${pkg}-${phosh_ver}.apk"
            if [ -f "$candidate_exact" ]; then
                src="$candidate_exact"
                break
            fi
        done
        if [ -z "$src" ]; then
            src="$(_atomos_find_newest_apk_for_pkg "$pkg")"
        fi
        [ -n "$src" ] && [ -f "$src" ] || continue
        if "${runner[@]}" cp -f "$src" "$stage_host_path/"; then
            staged="${staged} $(basename "$src")"
        else
            echo "stage_vendor_phosh_apks_into_rootfs_chroot: WARN failed to stage $src" >&2
        fi
    done
    "${runner[@]}" chmod -R u+rwX,go+rX "$stage_host_path" 2>/dev/null || true

    if [ -z "$staged" ]; then
        echo "stage_vendor_phosh_apks_into_rootfs_chroot: WARN no apk files staged (every copy failed?)" >&2
        return 0
    fi
    echo "stage_vendor_phosh_apks_into_rootfs_chroot: staged into ${stage_host_path}:${staged}"
    unset -f _atomos_find_newest_apk_for_pkg
}

promote_local_vendor_phosh_into_rootfs() {
    if [ "$PMOS_UI" != "phosh" ] || [ "$USE_VENDOR_PHOSH" != "1" ]; then
        return 0
    fi
    # Always (re-)stage from host first so /tmp/atomos-vendor-phosh/ in the
    # rootfs chroot has the newest local APKs even when pmbootstrap bind
    # mounts have gone missing between install and here.
    stage_vendor_phosh_apks_into_rootfs_chroot
    echo "=== Prefer local vendor phosh APK artifacts in rootfs ==="
    pmb chroot -r -- /bin/sh -eu -c '
        arch="$(apk --print-arch 2>/dev/null || true)"
        [ -n "$arch" ] || arch="aarch64"

        find_latest_local_apk() {
            pkg="$1"
            latest=""
            # /tmp/atomos-vendor-phosh first: that is our host-staged copy,
            # filled directly from the build-host filesystem and immune to
            # pmbootstrap /mnt/pmbootstrap/packages mount quirks. The other
            # dirs are kept as fallbacks in case the caller bypassed the
            # host staging step.
            for d in \
                "/tmp/atomos-vendor-phosh" \
                "/mnt/pmbootstrap/packages/edge/${arch}" \
                "/mnt/pmbootstrap/packages/pmos/${arch}" \
                "/mnt/pmbootstrap/packages/edge/pmos/${arch}" \
                "/home/pmos/packages/edge/${arch}" \
                "/home/pmos/packages/pmos/${arch}" \
                "/home/pmos/packages/edge/pmos/${arch}"
            do
                [ -d "$d" ] || continue
                for f in "$d"/"${pkg}"-*.apk; do
                    [ -f "$f" ] || continue
                    if [ -z "$latest" ] || [ "$f" -nt "$latest" ]; then
                        latest="$f"
                    fi
                done
            done
            printf "%s" "$latest"
        }

        # phosh is the one package we MUST find. phoc + phosh-mobile-settings
        # are separate pmaports packages that our --src=rust/phosh/phosh
        # build does NOT produce, so they are normally absent from the
        # staged set - that is expected, stock phoc+phosh-mobile-settings
        # are untouched by AtomOS modifications (markers live in phosh
        # proper, not phoc). Requiring phoc here would make promote a
        # permanent no-op for the default vendor-phosh path.
        phosh_apk="$(find_latest_local_apk phosh)"

        if [ -z "$phosh_apk" ]; then
            echo "WARN: local vendor phosh APK not found in /tmp/atomos-vendor-phosh or fallback mount paths; skipping forced local install." >&2
            echo "  dir listings:" >&2
            for d in /tmp/atomos-vendor-phosh /mnt/pmbootstrap/packages/edge/$arch /home/pmos/packages/edge/$arch; do
                if [ -d "$d" ]; then
                    echo "    $d:" >&2
                    ls -la "$d" >&2 2>&1 | head -n 20 || true
                else
                    echo "    $d: (missing)" >&2
                fi
            done
            exit 0
        fi

        # Install EVERY apk that we host-staged under /tmp/atomos-vendor-phosh
        # in one transaction so the full set (phosh + libphosh +
        # phosh-schemas + phosh-systemd + phosh-portalsconf + ...) gets
        # upgraded to our AtomOS build in lockstep. Without this, apk
        # would only upgrade phosh and leave e.g. phosh-schemas at stock
        # 0.54.0-r0 while phosh is at 0.54.0_p<ts>-r0 - a version skew
        # that can hide AtomOS schema/UI additions at runtime.
        stage_apks=""
        if [ -d /tmp/atomos-vendor-phosh ]; then
            for f in /tmp/atomos-vendor-phosh/*.apk; do
                [ -f "$f" ] || continue
                stage_apks="$stage_apks $f"
            done
        fi
        if [ -z "$stage_apks" ]; then
            # Fallback: at least force the single newest phosh.apk from
            # whichever path find_latest_local_apk resolved. This path is
            # taken when host staging silently failed (mkdir/sudo gap) but
            # phosh still surfaced via the mount paths.
            stage_apks="$phosh_apk"
        fi

        echo "apk add --upgrade --allow-untrusted${stage_apks}"
        set +e
        apk add --upgrade --allow-untrusted $stage_apks >/dev/null
        rc=$?
        set -e
        if [ "$rc" -ne 0 ]; then
            echo "WARN: failed to force-install local vendor phosh APK artifacts (exit $rc); retrying one-by-one for diagnostics..." >&2
            set +e
            for apk_file in $stage_apks; do
                if ! apk add --upgrade --allow-untrusted "$apk_file" >/dev/null 2>&1; then
                    echo "  per-apk fail: $apk_file" >&2
                fi
            done
            set -e
            # Do not exit non-zero; verify_final_rootfs_customizations will
            # catch the case where phosh markers are still missing after this.
            exit 0
        fi

        echo "Installed local vendor phosh artifacts:"
        for apk_file in $stage_apks; do
            echo "  $apk_file"
        done
    '
}

run_bt_tool_installs() {
    if [ "${ATOMOS_SKIP_BT_TOOLS:-0}" = "1" ]; then
        echo "=== Skip Bluetooth tool installers (ATOMOS_SKIP_BT_TOOLS=1) ==="
        return 0
    fi
    bash "$ROOT_DIR/scripts/rootfs/install-btlescan.sh" "$PROFILE_ENV_SOURCE"
    bash "$ROOT_DIR/scripts/rootfs/install-bt-tools.sh" "$PROFILE_ENV_SOURCE"
}

sync_local_systemd_edge_indexes() {
    local packages_root edge_root pmos_root systemd_root updated use_sudo
    packages_root="${PMB_WORK_OVERRIDE}/packages"
    edge_root="${packages_root}/edge"
    pmos_root="${packages_root}/pmos"
    systemd_root="${packages_root}/systemd-edge"
    [ -d "$packages_root" ] || return 0
    use_sudo=0
    # pmbootstrap can index locally-built APKs under packages/pmos/<arch> while
    # install/verify paths read packages/edge/<arch>. Mirror pmos -> edge first.
    if [ -d "$pmos_root" ]; then
        for arch_dir in "$pmos_root"/*; do
            [ -d "$arch_dir" ] || continue
            local arch src_dir dst_dir
            arch="$(basename "$arch_dir")"
            src_dir="${pmos_root}/${arch}"
            dst_dir="${edge_root}/${arch}"
            if [ "$use_sudo" -eq 1 ]; then
                sudo mkdir -p "$dst_dir"
                sudo cp -af "${src_dir}/." "$dst_dir/" && updated=1
            else
                mkdir -p "$dst_dir" 2>/dev/null || {
                    if command -v sudo >/dev/null 2>&1; then
                        sudo mkdir -p "$dst_dir"
                        use_sudo=1
                    else
                        echo "WARN: cannot create $dst_dir and sudo is unavailable; skipping pmos->edge mirror for $arch." >&2
                        continue
                    fi
                }
                if [ "$use_sudo" -eq 1 ]; then
                    sudo cp -af "${src_dir}/." "$dst_dir/" && updated=1
                else
                    cp -af "${src_dir}/." "$dst_dir/" 2>/dev/null && updated=1 || {
                        if command -v sudo >/dev/null 2>&1; then
                            sudo cp -af "${src_dir}/." "$dst_dir/" && updated=1 && use_sudo=1
                        else
                            echo "WARN: failed to mirror ${src_dir} -> ${dst_dir} and sudo is unavailable." >&2
                        fi
                    }
                fi
            fi
        done
    fi
    [ -d "$edge_root" ] || return 0
    if ! mkdir -p "$systemd_root" 2>/dev/null; then
        if command -v sudo >/dev/null 2>&1; then
            sudo mkdir -p "$systemd_root"
            use_sudo=1
        else
            echo "WARN: cannot create $systemd_root and sudo is unavailable; skipping systemd-edge index sync." >&2
            return 0
        fi
    fi
    updated=0
    for arch_dir in "$edge_root"/*; do
        [ -d "$arch_dir" ] || continue
        local arch src_idx dst_dir dst_idx
        arch="$(basename "$arch_dir")"
        src_idx="${arch_dir}/APKINDEX.tar.gz"
        [ -f "$src_idx" ] || continue
        dst_dir="${systemd_root}/${arch}"
        dst_idx="${dst_dir}/APKINDEX.tar.gz"
        if [ "$use_sudo" -eq 1 ]; then
            sudo mkdir -p "$dst_dir"
        else
            mkdir -p "$dst_dir" 2>/dev/null || {
                if command -v sudo >/dev/null 2>&1; then
                    sudo mkdir -p "$dst_dir"
                    use_sudo=1
                else
                    echo "WARN: cannot create $dst_dir and sudo is unavailable; skipping this arch index sync." >&2
                    continue
                fi
            }
        fi
        if [ ! -f "$dst_idx" ] || [ "$src_idx" -nt "$dst_idx" ]; then
            if [ "$use_sudo" -eq 1 ]; then
                sudo cp -f "$src_idx" "$dst_idx" && updated=1
            else
                cp -f "$src_idx" "$dst_idx" 2>/dev/null && updated=1 || {
                    if command -v sudo >/dev/null 2>&1; then
                        sudo cp -f "$src_idx" "$dst_idx" && updated=1 && use_sudo=1
                    else
                        echo "WARN: failed to copy $src_idx -> $dst_idx and sudo is unavailable." >&2
                    fi
                }
            fi
        fi
    done
    if [ "$updated" -eq 1 ]; then
        echo "Synced local APK repositories: pmos -> edge -> systemd-edge"
    fi
}

run_pmb_install_with_recovery() {
    local log_file install_rc
    log_file="$(mktemp)"
    sync_local_systemd_edge_indexes
    prepare_rootfs_systemd_apk_state
    prepare_native_rootfs_output_permissions

    # extra_packages is already set via `pmb config extra_packages` above.
    # Passing the same list again via `--add` duplicates packages in the
    # install transaction and can create avoidable resolver conflicts.
    set +e
    pmb install --password "$PMOS_INSTALL_PASSWORD" 2>&1 | tee "$log_file"
    install_rc=${PIPESTATUS[0]}
    set -e
    if [ "$install_rc" -eq 0 ]; then
        rm -f "$log_file"
        return 0
    fi

    if rg -q "device-mapper: create ioctl on .* failed: Resource busy|failed to mount subpartitions" "$log_file"; then
        echo "WARN: detected busy device-mapper / subpartition mount failure; cleaning up pmbootstrap state and retrying once..." >&2
        cleanup_stale_dynamic_partition_mappers
        set +e
        pmb shutdown
        _retry_shutdown_rc=$?
        set -e
        if [ "$_retry_shutdown_rc" -ne 0 ]; then
            echo "Note: pmbootstrap shutdown exited $_retry_shutdown_rc during recovery (continuing)." >&2
        fi
        set +e
        sync_local_systemd_edge_indexes
        prepare_rootfs_systemd_apk_state
        prepare_native_rootfs_output_permissions
        pmb install --password "$PMOS_INSTALL_PASSWORD"
        install_rc=$?
        set -e
    fi

    if [ "$install_rc" -ne 0 ] && \
        rg -q "chrony-common-[^:]+: trying to overwrite etc/chrony/chrony\\.conf owned by postmarketos-base-ui" "$log_file"; then
        echo "WARN: detected chrony overwrite conflict in rootfs; applying force-overwrite recovery and retrying once..." >&2
        clear_legacy_gsd_world_entries
        set +e
        sync_local_systemd_edge_indexes
        prepare_rootfs_systemd_apk_state
        prepare_native_rootfs_output_permissions
        pmb chroot -r -- /bin/sh -eu -c '
            # Keep this targeted: avoid full upgrades that can alter apk-tools
            # behavior mid-build and cause resolver/index regressions.
            apk add --no-interactive --force-overwrite chrony-common chrony
        '
        _chrony_recovery_rc=$?
        set -e
        if [ "$_chrony_recovery_rc" -ne 0 ]; then
            echo "WARN: chrony overwrite recovery exited ${_chrony_recovery_rc}; continuing with install retry." >&2
        fi
        set +e
        sync_local_systemd_edge_indexes
        prepare_rootfs_systemd_apk_state
        prepare_native_rootfs_output_permissions
        pmb install --password "$PMOS_INSTALL_PASSWORD"
        install_rc=$?
        set -e
    fi

    if [ "$install_rc" -ne 0 ] && \
        rg -q "postmarketos-base-systemd: line [0-9]+: can't create /var/lib/systemd-apk/installed\\.units: Permission denied" "$log_file"; then
        echo "WARN: detected systemd-apk state permission issue in rootfs; repairing /var/lib/systemd-apk and retrying once..." >&2
        set +e
        prepare_rootfs_systemd_apk_state
        sync_local_systemd_edge_indexes
        prepare_native_rootfs_output_permissions
        pmb install --password "$PMOS_INSTALL_PASSWORD"
        install_rc=$?
        set -e
    fi

    if [ "$install_rc" -ne 0 ] && \
        rg -q "img2simg .*Cannot open output file|Cannot open output file .*sparse\\.img" "$log_file"; then
        echo "WARN: detected img2simg output permission issue in native chroot; repairing /home/pmos/rootfs permissions and retrying once..." >&2
        set +e
        prepare_native_rootfs_output_permissions
        pmb install --password "$PMOS_INSTALL_PASSWORD"
        install_rc=$?
        set -e
    fi

    if [ "$install_rc" -ne 0 ] && [ -f "${PMB_WORK_OVERRIDE}/log.txt" ]; then
        echo "=== Last 120 lines of ${PMB_WORK_OVERRIDE}/log.txt ===" >&2
        tail -n 120 "${PMB_WORK_OVERRIDE}/log.txt" >&2 || true
    fi

    rm -f "$log_file"
    return "$install_rc"
}

if ! run_pmb_install_with_recovery; then
    echo "WARN: pmbootstrap install failed; attempting mkinitfs udev compatibility recovery..." >&2
    mkinitfs_udev_compat_patch || true
    echo "Retrying pmbootstrap install..." >&2
    run_pmb_install_with_recovery
fi
promote_local_vendor_phosh_into_rootfs
verify_stock_phosh_origin
verify_vendor_phosh_origin

echo "=== Apply AtomOS rootfs customizations ==="
bash "$ROOT_DIR/scripts/rootfs/wire-custom-apk-repos.sh" "$PROFILE_ENV_SOURCE"
bash "$ROOT_DIR/scripts/rootfs/install-atomos-agents.sh" "$PROFILE_ENV_SOURCE"
run_bt_tool_installs
if [ "$BUILD_OVERVIEW_CHAT_UI" -eq 1 ]; then
    bash "$ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"
    bash "$ROOT_DIR/scripts/overview-chat-ui/install-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"
    verify_overview_chat_ui_install
else
    echo "=== Skip atomos-overview-chat-ui (BUILD_OVERVIEW_CHAT_UI=0) ==="
fi

# atomos-home-bg: webview-backed home background surface. Same pattern as
# overview-chat-ui: cross-build the aarch64-musl binary against the pmOS
# rootfs sysroot, then drop the binary + lifecycle launcher + placeholder
# content into the rootfs chroot. Disable with --without-home-bg /
# BUILD_HOME_BG=0 when the WebKit + GTK4 dev-lib pull is undesirable.
if [ "$BUILD_HOME_BG" -eq 1 ]; then
    # Gracefully skip when the home-bg build+install helpers are not present
    # on this checkout. The scripts/home-bg/ tree + rust/atomos-home-bg/
    # crate ship together; a build host that cloned atomos from a tag cut
    # before those additions were committed (or pulled a branch that does
    # not carry them) should not hard-fail just because of home-bg.
    HOME_BG_BUILD="$ROOT_DIR/scripts/home-bg/build-atomos-home-bg.sh"
    HOME_BG_INSTALL="$ROOT_DIR/scripts/home-bg/install-atomos-home-bg.sh"
    if [ ! -f "$HOME_BG_BUILD" ] || [ ! -f "$HOME_BG_INSTALL" ]; then
        echo "=== Skip atomos-home-bg (helper scripts missing on this host) ==="
        echo "    missing: $HOME_BG_BUILD" >&2
        echo "    missing: $HOME_BG_INSTALL" >&2
        echo "    To enable: commit scripts/home-bg/ + rust/atomos-home-bg/ to" >&2
        echo "    the branch being built here, or set WITHOUT_HOME_BG=1 explicitly" >&2
        echo "    to silence this notice." >&2
        # Disable the subsequent final-verify requirement so the downstream
        # verify_final_rootfs_customizations does not look for binaries we
        # intentionally did not build.
        BUILD_HOME_BG=0
    else
        bash "$HOME_BG_BUILD" "$PROFILE_ENV_SOURCE"
        bash "$HOME_BG_INSTALL" "$PROFILE_ENV_SOURCE"
        verify_home_bg_install
    fi
    unset HOME_BG_BUILD HOME_BG_INSTALL
else
    echo "=== Skip atomos-home-bg (BUILD_HOME_BG=0) ==="
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
if [ "$BUILD_HOME_BG" -eq 1 ]; then
    verify_home_bg_launcher_contract
fi

# Re-promote vendor phosh after every apk-mutating customization step has
# run. install-atomos-agents.sh and install-bt-tools.sh both run
# `apk update` + `apk add` inside the rootfs chroot; the former also has
# an `apk upgrade --no-interactive` fallback
# (scripts/rootfs/install-atomos-agents.sh:59) that re-solves the package
# world and can replace our locally-built vendor phosh with a newer stock
# phosh from the live Alpine mirror without any build-time error.
# Re-running promote_local_vendor_phosh_into_rootfs here force-installs
# the local phosh subpackage set again so the final rootfs chroot (and
# therefore the resync'd disk image) definitely carries the AtomOS-patched
# phosh.
promote_local_vendor_phosh_into_rootfs
verify_vendor_phosh_origin

echo "=== Resync rootfs and export image ==="
# Hard-fail RIGHT BEFORE resync if the rootfs chroot is missing the things
# we expect to land in the exported image. Without this assert, silent
# regressions between "promote vendor phosh" and "resync" (e.g. apk
# upgrade replaying against a live mirror) produce a stock-phosh image
# without any error code.
verify_final_rootfs_customizations
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
