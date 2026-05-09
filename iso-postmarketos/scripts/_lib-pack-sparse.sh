# shellcheck shell=bash
# scripts/_lib-pack-sparse.sh -- pack the bootstrapped rootfs into a
# sparse ext4 image suitable for `fastboot flash userdata`.
#
# Filesystem label MUST be `pmOS_root`. postmarketos-initramfs's
# init_functions.sh `find_root_partition` looks up the rootfs via
# `blkid --label pmOS_root`; any other label means "Waiting for root
# partition..." forever on first boot.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME EXPORT_DIR
# PROFILE_NAME DEVICE_FLASH_SPARSE
# Optional: ROOTFS_SIZE_MB (size override)

_atomos_pack_container_body() {
    cat <<'PACK_BODY'
# Intentionally not installing GNU coreutils here; alpine:edge often
# has a newer musl symbol set than its coreutils expects (renameat2),
# so /bin/rm hits "Error relocating ... symbol not found". Busybox
# supports every option this script uses.
apk add --no-interactive e2fsprogs util-linux mount rsync android-tools >/dev/null

RAW=/exportdir/${PROFILE_NAME}.raw.img
SPARSE=/exportdir/${PROFILE_NAME}.img
rm -f "$RAW" "$SPARSE"

if [ -n "${ROOTFS_SIZE_MB:-}" ]; then
    SIZE_MB="$ROOTFS_SIZE_MB"
else
    USED_KB="$(du -sk /target | cut -f1)"
    SIZE_MB=$(( (USED_KB / 1024) + 256 ))
    REM=$(( SIZE_MB % 64 ))
    if [ "$REM" -ne 0 ]; then SIZE_MB=$(( SIZE_MB + 64 - REM )); fi
fi
echo "build-fairphone4-v2: rootfs raw image size = ${SIZE_MB} MiB"

truncate -s "${SIZE_MB}M" "$RAW"
mkfs.ext4 -F -L pmOS_root "$RAW"

mkdir -p /mnt/root
mount -o loop "$RAW" /mnt/root
rsync -aHAX --delete --numeric-ids /target/ /mnt/root/
sync
umount /mnt/root

if [ "${DEVICE_FLASH_SPARSE:-true}" = "true" ]; then
    echo "build-fairphone4-v2: converting raw image to sparse via img2simg"
    img2simg "$RAW" "$SPARSE"
    rm -f "$RAW"
else
    mv "$RAW" "$SPARSE"
fi
ls -la "$SPARSE"
PACK_BODY
}

atomos_pack_sparse_rootfs() {
    echo "=== build-fairphone4-v2: pack rootfs into sparse image ==="
    "$ENGINE" run --rm --privileged --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target:ro" \
        -v "$EXPORT_DIR:/exportdir" \
        -e PROFILE_NAME="$PROFILE_NAME" \
        -e ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-}" \
        -e DEVICE_FLASH_SPARSE="$DEVICE_FLASH_SPARSE" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_pack_container_body)"
}

# Best-effort export ownership normalize (matches build-fairphone4.sh).
atomos_normalize_export_ownership() {
    if [ "${ATOMOS_SKIP_EXPORT_CHOWN:-0}" = "1" ]; then
        return 0
    fi
    if ! "$ENGINE" run --rm \
        -v "$EXPORT_DIR:/export" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "chown -R $HOST_UID:$HOST_GID /export" \
        >/dev/null 2>&1; then
        echo "Note: skipped export ownership adjustment (expected on some rootless runtimes)."
    fi
}
