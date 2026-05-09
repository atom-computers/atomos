# shellcheck shell=bash
# scripts/_lib-deviceinfo.sh -- source pmaports deviceinfo and export
# the boot.img layout values the rest of the build needs.
#
# Required globals at call time:
#   ROOT_DIR              -- iso-postmarketos directory
#   PMOS_DEVICE           -- e.g. "fairphone-fp4"
#   PROFILE_ENV_SOURCE    -- profile env path (re-sourced after we are done
#                            because deviceinfo can clobber profile vars)
#
# Exports on success: DEVICE_DTB DEVICE_ARCH DEVICE_APPEND_DTB
# DEVICE_PAGESIZE DEVICE_BASE DEVICE_KOFF DEVICE_ROFF DEVICE_SOFF
# DEVICE_TOFF DEVICE_FLASH_SPARSE DEVICE_KERNEL_CMDLINE DEVICEINFO_HOST

# Locate the deviceinfo file under pmaports. We probe the
# community / testing / archived / main subtrees because pmOS reorgs
# devices between maturity tiers fairly often.
atomos_deviceinfo_locate() {
    local sub
    for sub in community testing archived downstream main; do
        local cand="$ROOT_DIR/pmaports/device/${sub}/device-${PMOS_DEVICE}/deviceinfo"
        if [ -f "$cand" ]; then
            DEVICEINFO_HOST="$cand"
            export DEVICEINFO_HOST
            return 0
        fi
    done
    echo "ERROR: deviceinfo not found for PMOS_DEVICE=$PMOS_DEVICE" >&2
    echo "  Looked under: pmaports/device/{community,testing,archived,downstream,main}/device-${PMOS_DEVICE}/" >&2
    return 2
}

# Source deviceinfo in a subshell first to verify the required keys
# exist; then source it for real and copy the values out under the
# DEVICE_* names. We re-source the profile env afterwards because some
# deviceinfo files set vars (e.g. arch) that the profile env also sets.
atomos_deviceinfo_load() {
    : "${DEVICEINFO_HOST:?atomos_deviceinfo_locate must be called first}"

    (
        set +u
        # shellcheck source=/dev/null
        source "$DEVICEINFO_HOST"
        : "${deviceinfo_dtb:?missing deviceinfo_dtb}"
        : "${deviceinfo_arch:?missing deviceinfo_arch}"
    )

    # shellcheck source=/dev/null
    source "$DEVICEINFO_HOST"
    DEVICE_DTB="${deviceinfo_dtb}"
    DEVICE_ARCH="${deviceinfo_arch:-aarch64}"
    DEVICE_APPEND_DTB="${deviceinfo_append_dtb:-false}"
    DEVICE_PAGESIZE="${deviceinfo_flash_pagesize:-4096}"
    DEVICE_BASE="${deviceinfo_flash_offset_base:-0x00000000}"
    DEVICE_KOFF="${deviceinfo_flash_offset_kernel:-0x00008000}"
    DEVICE_ROFF="${deviceinfo_flash_offset_ramdisk:-0x01000000}"
    DEVICE_SOFF="${deviceinfo_flash_offset_second:-0x00000000}"
    DEVICE_TOFF="${deviceinfo_flash_offset_tags:-0x00000100}"
    DEVICE_FLASH_SPARSE="${deviceinfo_flash_sparse:-true}"
    DEVICE_KERNEL_CMDLINE="${deviceinfo_kernel_cmdline:-PMOS_NO_OUTPUT_REDIRECT}"

    # Drop the deviceinfo_* shell vars we no longer need; they linger
    # otherwise and pollute downstream env diagnostics.
    unset deviceinfo_dtb deviceinfo_arch deviceinfo_append_dtb deviceinfo_format_version 2>/dev/null || true
    unset deviceinfo_flash_pagesize deviceinfo_flash_offset_base deviceinfo_flash_offset_kernel \
          deviceinfo_flash_offset_ramdisk deviceinfo_flash_offset_second deviceinfo_flash_offset_tags \
          deviceinfo_flash_sparse deviceinfo_kernel_cmdline 2>/dev/null || true

    if [ "$DEVICE_ARCH" != "aarch64" ]; then
        echo "ERROR: unsupported deviceinfo_arch '$DEVICE_ARCH' (expected aarch64)." >&2
        return 2
    fi

    # Re-source the profile env so PMOS_EXTRA_PACKAGES /
    # PMOS_PARITY_PACKAGE_CANDIDATES / etc. survive the deviceinfo source.
    # shellcheck source=/dev/null
    source "$PROFILE_ENV_SOURCE"

    export DEVICE_DTB DEVICE_ARCH DEVICE_APPEND_DTB DEVICE_PAGESIZE \
           DEVICE_BASE DEVICE_KOFF DEVICE_ROFF DEVICE_SOFF DEVICE_TOFF \
           DEVICE_FLASH_SPARSE DEVICE_KERNEL_CMDLINE
}

# One-shot: locate + load + report.
atomos_deviceinfo_setup() {
    atomos_deviceinfo_locate
    atomos_deviceinfo_load
    cat <<EOF
build-fairphone4-v2: deviceinfo: $DEVICEINFO_HOST
build-fairphone4-v2:   dtb=$DEVICE_DTB arch=$DEVICE_ARCH append_dtb=$DEVICE_APPEND_DTB
build-fairphone4-v2:   pagesize=$DEVICE_PAGESIZE base=$DEVICE_BASE
build-fairphone4-v2:   koff=$DEVICE_KOFF roff=$DEVICE_ROFF soff=$DEVICE_SOFF toff=$DEVICE_TOFF
build-fairphone4-v2:   flash_sparse=$DEVICE_FLASH_SPARSE
build-fairphone4-v2:   cmdline='$DEVICE_KERNEL_CMDLINE'
EOF
}
