#!/bin/bash
set -euo pipefail

# In Docker Desktop Linux VMs, loop partition nodes (e.g. /dev/loop0p1) may
# not appear unless udev is running and has processed events.
if [ -x /lib/systemd/systemd-udevd ]; then
    /lib/systemd/systemd-udevd --daemon || true
elif command -v udevd >/dev/null 2>&1; then
    udevd --daemon || true
fi

if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger || true
    udevadm settle || true
fi

ensure_loop_partitions() {
    # Some kernels default loop.max_part=0; no /dev/loopXp1 nodes appear.
    if command -v modprobe >/dev/null 2>&1; then
        modprobe loop max_part=63 >/dev/null 2>&1 || true
        modprobe dm_mod >/dev/null 2>&1 || true
    fi
    if [ ! -d /dev/mapper ]; then
        mkdir -p /dev/mapper >/dev/null 2>&1 || true
    fi
    if [ ! -e /dev/mapper/control ]; then
        mknod /dev/mapper/control c 10 236 >/dev/null 2>&1 || true
    fi
    if [ -r /sys/module/loop/parameters/max_part ]; then
        CUR="$(cat /sys/module/loop/parameters/max_part 2>/dev/null || echo 0)"
        if [ "${CUR:-0}" = "0" ]; then
            echo "WARNING: loop.max_part appears to be 0 in this container; partition nodes may require kpartx mapping." >&2
        fi
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm trigger --subsystem-match=block || true
        udevadm settle || true
    fi
}

ensure_loop_partitions

prepare_loop_pool() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe loop max_part=63 max_loop=256 >/dev/null 2>&1 || true
    fi
    if [ ! -e /dev/loop-control ]; then
        mknod /dev/loop-control c 10 237 >/dev/null 2>&1 || true
    fi
    # Ensure a healthy set of loop nodes exists for losetup -f scans.
    i=0
    while [ "$i" -lt 256 ]; do
        DEV="/dev/loop$i"
        if [ ! -e "$DEV" ]; then
            mknod "$DEV" b 7 "$i" >/dev/null 2>&1 || true
        fi
        i=$((i + 1))
    done
}

cleanup_stale_pmbootstrap_loops() {
    command -v losetup >/dev/null 2>&1 || return 0
    while IFS= read -r LINE; do
        LOOP_DEV="${LINE%%:*}"
        BACKING="$(printf '%s\n' "$LINE" | sed -n 's/.*(\(.*\)).*/\1/p')"
        case "$BACKING" in
            */home/pmos/rootfs/*.img|*/pmbootstrap*/rootfs/*.img)
                if ! grep -q "^${LOOP_DEV} " /proc/mounts 2>/dev/null; then
                    if command -v kpartx >/dev/null 2>&1; then
                        kpartx -d "$LOOP_DEV" >/dev/null 2>&1 || true
                    fi
                    losetup -d "$LOOP_DEV" >/dev/null 2>&1 || true
                fi
                ;;
        esac
    done < <(losetup -a 2>/dev/null || true)
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
        dmsetup remove "$mapper_name" >/dev/null 2>&1 || dmsetup remove -f "$mapper_name" >/dev/null 2>&1 || true
    done < <(
        dmsetup ls --target linear 2>/dev/null \
            | sed -n 's/^\([^[:space:]]\+\).*/\1/p' \
            | sed -n '/^\(system\|system_ext\|product\|vendor\|odm\|vendor_dlkm\|system_dlkm\|odm_dlkm\)_[ab]$/p'
    )
}

prepare_loop_pool
cleanup_stale_dynamic_partition_mappers
cleanup_stale_pmbootstrap_loops

map_loop_device_partitions() {
    local loop_dev="$1"
    [ -b "$loop_dev" ] || return 0
    if command -v partx >/dev/null 2>&1; then
        partx -u "$loop_dev" >/dev/null 2>&1 || true
    fi
    if command -v kpartx >/dev/null 2>&1; then
        MAP_OUT="$(kpartx -av "$loop_dev" 2>/dev/null || true)"
        if [ -z "$MAP_OUT" ]; then
            MAP_OUT="$(kpartx -l "$loop_dev" 2>/dev/null || true)"
        fi
        while IFS= read -r line; do
            map_name="$(printf '%s\n' "$line" | sed -n 's/.*\(loop[0-9]\+p[0-9]\+\).*/\1/p')"
            [ -n "$map_name" ] || continue
            if [ -b "/dev/mapper/$map_name" ] && [ ! -e "/dev/$map_name" ]; then
                ln -s "/dev/mapper/$map_name" "/dev/$map_name" >/dev/null 2>&1 || true
            fi
        done <<< "$MAP_OUT"
    fi
}

loop_partition_compat_shim() {
    # Some environments never expose /dev/loopXp1 nodes. Mirror mapper nodes
    # from kpartx as /dev/loopXpN symlinks so pmbootstrap can mount partitions.
    while true; do
        for LOOP_DEV in /dev/loop[0-9]*; do
            [ -b "$LOOP_DEV" ] || continue
            map_loop_device_partitions "$LOOP_DEV"
            LOOP_NAME="$(basename "$LOOP_DEV")"
            for MAP_DEV in /dev/mapper/"${LOOP_NAME}"p*; do
                [ -b "$MAP_DEV" ] || continue
                LINK_DEV="/dev/$(basename "$MAP_DEV")"
                if [ -L "$LINK_DEV" ] && [ ! -e "$LINK_DEV" ]; then
                    rm -f "$LINK_DEV" >/dev/null 2>&1 || true
                fi
                if [ ! -e "$LINK_DEV" ]; then
                    ln -s "$MAP_DEV" "$LINK_DEV" >/dev/null 2>&1 || true
                fi
            done
        done
        sleep 1
    done
}

loop_partition_compat_shim &
LOOP_SHIM_PID=$!

TMP_LOG="$(mktemp)"
cleanup() {
    if [ -n "${LOOP_SHIM_PID:-}" ]; then
        kill "$LOOP_SHIM_PID" >/dev/null 2>&1 || true
    fi
    rm -f "$TMP_LOG"
}
trap cleanup EXIT

set +e
bash scripts/pmb/pmb.sh "$@" 2>&1 | tee "$TMP_LOG"
STATUS="${PIPESTATUS[0]}"
set -e

if [ "$STATUS" -eq 0 ]; then
    exit 0
fi

if grep -q "expected it to be at /dev/loop[0-9]\\+p1" "$TMP_LOG"; then
    echo "Detected missing /dev/loopXp1 node; forcing loop/udev rescan and retrying once..." >&2
    ensure_loop_partitions
    cleanup_stale_dynamic_partition_mappers
    cleanup_stale_pmbootstrap_loops
    FAILED_LOOP="$(grep -Eo '/dev/loop[0-9]+' "$TMP_LOG" | tail -n1 || true)"
    if [ -n "$FAILED_LOOP" ]; then
        map_loop_device_partitions "$FAILED_LOOP"
    fi
    for LOOP_DEV in /dev/loop[0-9]*; do
        [ -b "$LOOP_DEV" ] || continue
        map_loop_device_partitions "$LOOP_DEV"
    done
    sleep 2
    exec bash scripts/pmb/pmb.sh "$@"
fi

exit "$STATUS"
