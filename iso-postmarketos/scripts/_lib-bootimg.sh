# shellcheck shell=bash
# scripts/_lib-bootimg.sh -- export boot.img.
#
# Strategy: prefer the artifact boot-deploy produced in the mkinitfs
# fixup step; only fall back to a hand-rolled mkbootimg call if no
# usable boot.img landed in /target/boot/.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME EXPORT_DIR
# DEVICE_DTB DEVICE_APPEND_DTB DEVICE_PAGESIZE DEVICE_BASE
# DEVICE_KOFF DEVICE_ROFF DEVICE_SOFF DEVICE_TOFF DEVICE_KERNEL_CMDLINE

_atomos_bootimg_container_body() {
    cat <<'BOOTIMG_BODY'
# ---- boot-deploy output preferred path -------------------------
# boot-deploy convention: /boot/boot.img-<flavor> per kernel and
# /boot/boot.img as a generic copy. When both exist the generic
# /boot/boot.img is what we ship.
for cand in \
    /target/boot/boot.img \
    /target/boot/boot.img-postmarketos-qcom-sm6350 \
    /target/boot/boot.img-pmos; do
    if [ -f "$cand" ]; then
        echo "build-fairphone4-v2: using boot-deploy artifact: $cand"
        cp -f "$cand" /exportdir/boot.img
        ls -la /exportdir/boot.img
        exit 0
    fi
done
boot_img_glob="$(ls /target/boot/boot.img* 2>/dev/null | head -n 1 || true)"
if [ -n "$boot_img_glob" ] && [ -f "$boot_img_glob" ]; then
    echo "build-fairphone4-v2: using boot-deploy artifact (glob): $boot_img_glob"
    cp -f "$boot_img_glob" /exportdir/boot.img
    ls -la /exportdir/boot.img
    exit 0
fi

echo "build-fairphone4-v2: no boot-deploy boot.img found; falling back to manual mkbootimg." >&2

# ---- manual mkbootimg fallback ---------------------------------
KERNEL=""
for k in /target/boot/vmlinuz-postmarketos-qcom-sm6350 \
         /target/boot/vmlinuz-pmos \
         /target/boot/vmlinuz; do
    if [ -f "$k" ]; then KERNEL="$k"; break; fi
done
if [ -z "$KERNEL" ]; then
    KERNEL="$(ls /target/boot/vmlinuz* 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$KERNEL" ] || [ ! -f "$KERNEL" ]; then
    echo "ERROR: no kernel image under /target/boot/" >&2
    ls -la /target/boot/ >&2 || true
    exit 1
fi
echo "build-fairphone4-v2: kernel: $KERNEL"

INITRAMFS=""
for r in /target/boot/initramfs-postmarketos-qcom-sm6350 \
         /target/boot/initramfs-pmos \
         /target/boot/initramfs; do
    if [ -f "$r" ]; then INITRAMFS="$r"; break; fi
done
if [ -z "$INITRAMFS" ]; then
    INITRAMFS="$(ls /target/boot/initramfs* 2>/dev/null | head -n 1 || true)"
fi
if [ -z "$INITRAMFS" ] || [ ! -f "$INITRAMFS" ]; then
    apk add --no-interactive postmarketos-mkinitfs >/dev/null 2>&1 || true
    chroot /target /sbin/mkinitfs >/dev/null 2>&1 || true
    for r in /target/boot/initramfs-postmarketos-qcom-sm6350 \
             /target/boot/initramfs-pmos \
             /target/boot/initramfs; do
        if [ -f "$r" ]; then INITRAMFS="$r"; break; fi
    done
fi
if [ -z "$INITRAMFS" ] || [ ! -f "$INITRAMFS" ]; then
    echo "ERROR: no initramfs under /target/boot/" >&2
    ls -la /target/boot/ >&2 || true
    exit 1
fi
echo "build-fairphone4-v2: initramfs: $INITRAMFS"

DTB_PATH="/target/usr/share/dtb/${DEVICE_DTB}.dtb"
if [ ! -f "$DTB_PATH" ]; then
    for cand in \
        "/target/boot/dtbs/${DEVICE_DTB}.dtb" \
        "/target/boot/dtbs-postmarketos-qcom-sm6350/${DEVICE_DTB}.dtb" \
        "/target/lib/firmware/dtbs/${DEVICE_DTB}.dtb"; do
        if [ -f "$cand" ]; then DTB_PATH="$cand"; break; fi
    done
fi
if [ ! -f "$DTB_PATH" ]; then
    echo "ERROR: DTB not found for ${DEVICE_DTB}.dtb" >&2
    find /target -name "*.dtb" -path "*sm7225-fairphone*" 2>/dev/null | sed "s|^|  candidate: |" >&2 || true
    exit 1
fi
echo "build-fairphone4-v2: dtb: $DTB_PATH"

WORK=/tmp/atomos-bootimg
mkdir -p "$WORK"
cp "$KERNEL" "$WORK/kernel"
if [ "$DEVICE_APPEND_DTB" = "true" ]; then
    cat "$DTB_PATH" >> "$WORK/kernel"
    DTARG=""
else
    cp "$DTB_PATH" "$WORK/dtb"
    DTARG="--dt $WORK/dtb"
fi
cp "$INITRAMFS" "$WORK/initramfs"

# shellcheck disable=SC2086
mkbootimg \
    --kernel "$WORK/kernel" \
    --ramdisk "$WORK/initramfs" \
    --base "$DEVICE_BASE" \
    --kernel_offset "$DEVICE_KOFF" \
    --ramdisk_offset "$DEVICE_ROFF" \
    --second_offset "$DEVICE_SOFF" \
    --tags_offset "$DEVICE_TOFF" \
    --pagesize "$DEVICE_PAGESIZE" \
    --cmdline "$DEVICE_KERNEL_CMDLINE" \
    $DTARG \
    --output /exportdir/boot.img
ls -la /exportdir/boot.img
BOOTIMG_BODY
}

atomos_export_bootimg() {
    echo "=== build-fairphone4-v2: export boot.img ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$EXPORT_DIR:/exportdir" \
        -e DEVICE_DTB="$DEVICE_DTB" \
        -e DEVICE_APPEND_DTB="$DEVICE_APPEND_DTB" \
        -e DEVICE_PAGESIZE="$DEVICE_PAGESIZE" \
        -e DEVICE_BASE="$DEVICE_BASE" \
        -e DEVICE_KOFF="$DEVICE_KOFF" \
        -e DEVICE_ROFF="$DEVICE_ROFF" \
        -e DEVICE_SOFF="$DEVICE_SOFF" \
        -e DEVICE_TOFF="$DEVICE_TOFF" \
        -e DEVICE_KERNEL_CMDLINE="$DEVICE_KERNEL_CMDLINE" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_bootimg_container_body)"
}
