# shellcheck shell=bash
# scripts/_lib-pkg-cache.sh -- local-first package store for the FP4 v2
# build (apk packages + Rust crates).
#
# Goal: make the build resilient to mirror / DNS / internet outages. Once
# a build has run online ONCE, every subsequent build reuses the locally
# stored package versions and makes NO web requests -- unless newer
# versions are explicitly requested (ATOMOS_FP4V2_PKG_REFRESH=1) or the
# local store cannot satisfy the request (then it auto-refreshes from the
# network and repopulates the store).
#
# Two backends (same pattern as _lib-meson-cache.sh):
#
#   - DEFAULT: a NAMED docker volume (atomos-fp4v2-pkg-cache-<profile>).
#     apk's --cache-dir needs a native Linux filesystem; multipass/macOS
#     virtiofs bind mounts of the repo tree return EOPNOTSUPP ("Not
#     supported") when apk tries to set up its cache there. Keeping the
#     store inside the engine VM sidesteps that.
#   - OPT-IN HOST DIR: set ATOMOS_FP4V2_PKG_CACHE_HOST_DIR=<path> on a
#     VM-native ext4 path (e.g. $HOME/.atomos/pkg-cache-<profile>), NOT
#     on a multipass-shared /home/ubuntu/atomos mount.
#
# Store layout (inside the volume or host dir, mounted at /pkgcache):
#   apk/         -> apk --cache-dir (downloaded .apk + APKINDEX snaps)
#   cargo-home/  -> CARGO_HOME (crates.io registry index + crate srcs)
#
# Required globals at call time: ENGINE ALPINE_IMAGE PROFILE_NAME
#
# Exports for the phase docker-run call sites:
#   PKG_CACHE_MOUNT_SRC       value for `-v SRC:/pkgcache` (volume or host path)
#   PKG_CACHE_MOUNT           container mount point (/pkgcache)
#   PKG_CACHE_KIND            human label
#   APK_CACHE_CONTAINER_DIR   /pkgcache/apk
#   CARGO_HOME_CONTAINER_DIR  /pkgcache/cargo-home
#   PKG_REFRESH               1 => always go online + pull newest versions
#   ATOMOS_APK_NET            set per phase by atomos_run_net_phase
#   ATOMOS_CARGO_OFFLINE      set per phase by atomos_run_net_phase

# Return 0 when $1 lives on a filesystem apk cannot use as --cache-dir.
_atomos_pkg_cache_fs_unsafe() {
    local path="$1"
    local fstype
    fstype="$(df -T "$path" 2>/dev/null | awk 'NR==2 {print $2}')"
    case "$fstype" in
        virtiofs|9p|fuse.sshfs|nfs|nfs4|cifs|smbfs|fuse) return 0 ;;
    esac
    return 1
}

atomos_pkg_cache_select_backend() {
    PKG_CACHE_VOLUME="atomos-fp4v2-pkg-cache-${PROFILE_NAME}"
    PKG_CACHE_MOUNT="/pkgcache"
    APK_CACHE_CONTAINER_DIR="$PKG_CACHE_MOUNT/apk"
    CARGO_HOME_CONTAINER_DIR="$PKG_CACHE_MOUNT/cargo-home"

    if [ -n "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR:-}" ]; then
        if _atomos_pkg_cache_fs_unsafe "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR"; then
            echo "ERROR: ATOMOS_FP4V2_PKG_CACHE_HOST_DIR=$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR" >&2
            echo "       is on filesystem type '$(df -T "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR" 2>/dev/null | awk 'NR==2 {print $2}')'." >&2
            echo "       apk --cache-dir needs a native Linux fs (ext4/xfs/btrfs)." >&2
            echo "       On multipass, the shared repo mount (/home/ubuntu/atomos) does NOT work." >&2
            echo "       Omit ATOMOS_FP4V2_PKG_CACHE_HOST_DIR to use the default docker volume," >&2
            echo "       or set it to a VM-native path, e.g.:" >&2
            echo "         ATOMOS_FP4V2_PKG_CACHE_HOST_DIR=\$HOME/.atomos/pkg-cache-${PROFILE_NAME}" >&2
            return 2
        fi
        PKG_CACHE_MOUNT_SRC="$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR"
        PKG_CACHE_KIND="host directory: $ATOMOS_FP4V2_PKG_CACHE_HOST_DIR"
        mkdir -p "$PKG_CACHE_MOUNT_SRC/apk" "$PKG_CACHE_MOUNT_SRC/cargo-home"
    else
        PKG_CACHE_MOUNT_SRC="$PKG_CACHE_VOLUME"
        PKG_CACHE_KIND="docker volume: $PKG_CACHE_VOLUME"
        "$ENGINE" volume create "$PKG_CACHE_VOLUME" >/dev/null
        # Ensure the expected subdirs exist inside the volume.
        "$ENGINE" run --rm -v "$PKG_CACHE_VOLUME:/pkgcache" \
            "$ALPINE_IMAGE" /bin/sh -c 'mkdir -p /pkgcache/apk /pkgcache/cargo-home' \
            >/dev/null
    fi

    export PKG_CACHE_VOLUME PKG_CACHE_MOUNT_SRC PKG_CACHE_MOUNT \
           APK_CACHE_CONTAINER_DIR CARGO_HOME_CONTAINER_DIR PKG_CACHE_KIND
}

# Is the apk store populated enough for an offline attempt?
_atomos_pkg_cache_apk_populated() {
    if [ -n "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR:-}" ]; then
        ls "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR}"/apk/*.apk >/dev/null 2>&1
        return $?
    fi
    "$ENGINE" run --rm -v "$PKG_CACHE_MOUNT_SRC:/pkgcache:ro" \
        "$ALPINE_IMAGE" /bin/sh -c 'ls /pkgcache/apk/*.apk >/dev/null 2>&1' \
        >/dev/null 2>&1
}

_atomos_pkg_cache_cargo_populated() {
    if [ -n "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR:-}" ]; then
        [ -d "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR}/cargo-home/registry" ]
        return $?
    fi
    "$ENGINE" run --rm -v "$PKG_CACHE_MOUNT_SRC:/pkgcache:ro" \
        "$ALPINE_IMAGE" /bin/sh -c 'test -d /pkgcache/cargo-home/registry' \
        >/dev/null 2>&1
}

atomos_pkg_cache_wipe() {
    echo "build-fairphone4-v2: wiping package store ($PKG_CACHE_KIND)"
    if [ -n "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR:-}" ] && [ -d "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR" ]; then
        "$ENGINE" run --rm -v "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR:/pkgcache" \
            "$ALPINE_IMAGE" /bin/sh -c 'rm -rf /pkgcache/apk /pkgcache/cargo-home; mkdir -p /pkgcache/apk /pkgcache/cargo-home' \
            >/dev/null 2>&1 \
            || rm -rf "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR/apk" "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR/cargo-home"
        mkdir -p "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR/apk" "$ATOMOS_FP4V2_PKG_CACHE_HOST_DIR/cargo-home"
    elif [ -z "${ATOMOS_FP4V2_PKG_CACHE_HOST_DIR:-}" ]; then
        "$ENGINE" volume rm -f "$PKG_CACHE_VOLUME" >/dev/null 2>&1 || true
        "$ENGINE" volume create "$PKG_CACHE_VOLUME" >/dev/null
        "$ENGINE" run --rm -v "$PKG_CACHE_VOLUME:/pkgcache" \
            "$ALPINE_IMAGE" /bin/sh -c 'mkdir -p /pkgcache/apk /pkgcache/cargo-home' \
            >/dev/null
    fi
}

atomos_pkg_cache_setup() {
    atomos_pkg_cache_select_backend

    if [ "${ATOMOS_FP4V2_PKG_CACHE_CLEAN:-0}" = "1" ]; then
        atomos_pkg_cache_wipe
    fi

    # Refresh flag (accept a couple of intuitive aliases).
    PKG_REFRESH="${ATOMOS_FP4V2_PKG_REFRESH:-${ATOMOS_FP4V2_APK_REFRESH:-0}}"

    if _atomos_pkg_cache_apk_populated; then
        APK_CACHE_POPULATED=1
    else
        APK_CACHE_POPULATED=0
    fi
    if _atomos_pkg_cache_cargo_populated; then
        CARGO_CACHE_POPULATED=1
    else
        CARGO_CACHE_POPULATED=0
    fi

    # Initialise the per-phase knobs so call sites always have a value.
    ATOMOS_APK_NET="--update-cache"
    ATOMOS_CARGO_OFFLINE=0

    export PKG_REFRESH APK_CACHE_POPULATED CARGO_CACHE_POPULATED \
           ATOMOS_APK_NET ATOMOS_CARGO_OFFLINE

    echo "build-fairphone4-v2: package store backend: $PKG_CACHE_KIND"
    echo "build-fairphone4-v2:   apk cache:   $([ "$APK_CACHE_POPULATED" = 1 ] && echo 'populated (offline-capable)' || echo 'empty (first build seeds it online)')"
    echo "build-fairphone4-v2:   cargo cache: $([ "$CARGO_CACHE_POPULATED" = 1 ] && echo 'populated (offline-capable)' || echo 'empty (first build seeds it online)')"
    if [ "$PKG_REFRESH" = 1 ]; then
        echo "build-fairphone4-v2:   PKG_REFRESH=1 -> always online; pulling NEWEST package + crate versions"
    fi
}

# _atomos_phase_offline_ok <kind>
#   kind=apk   -> needs the apk store populated
#   kind=heavy -> needs BOTH apk and cargo stores populated
# Returns 0 (true) when an offline-first attempt is warranted.
_atomos_phase_offline_ok() {
    local kind="$1"
    [ "${PKG_REFRESH:-0}" = 1 ] && return 1
    case "$kind" in
        apk)   [ "${APK_CACHE_POPULATED:-0}" = 1 ] ;;
        heavy) [ "${APK_CACHE_POPULATED:-0}" = 1 ] && [ "${CARGO_CACHE_POPULATED:-0}" = 1 ] ;;
        *) return 1 ;;
    esac
}

# atomos_run_net_phase <kind> <phase-fn> [args...]
#   Run a network-touching phase local-first. If the offline attempt is
#   warranted and succeeds, no web request was made. Otherwise (or on
#   offline failure) run it online, which repopulates the local store
#   with the versions actually used.
atomos_run_net_phase() {
    local kind="$1"; shift
    local label="${1:-phase}"

    if _atomos_phase_offline_ok "$kind"; then
        echo "build-fairphone4-v2: [$kind] OFFLINE attempt from local store ($label)"
        export ATOMOS_APK_NET="--no-network" ATOMOS_CARGO_OFFLINE=1
        if "$@"; then
            return 0
        fi
        echo "build-fairphone4-v2: [$kind] local store could not satisfy '$label'; refreshing from network..." >&2
    fi

    echo "build-fairphone4-v2: [$kind] ONLINE (refresh local store: $label)"
    export ATOMOS_APK_NET="--update-cache" ATOMOS_CARGO_OFFLINE=0
    "$@"
}

# NOTE: offline-eligibility is decided from the START-OF-BUILD store
# detection (atomos_pkg_cache_setup), NOT updated mid-build. The minimal
# bootstrap phase only seeds a small subset of packages, so flipping the
# "populated" flag after it would make the full phase wastefully attempt
# an offline install against an incomplete cache before falling back.
