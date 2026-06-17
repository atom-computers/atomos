# shellcheck shell=bash
# scripts/_lib-mkinitfs.sh -- post-bootstrap mkinitfs + boot-deploy
# fixup. Same effect as Step 1.5 of the original build-fairphone4.sh,
# in a focused helper.
#
# What this fixes:
#   1. Alpine ships losetup at /sbin/losetup; postmarketos-mkinitfs
#      hook 00-initramfs-base.files lists /usr/sbin/losetup. Without
#      the symlink the trigger fails with:
#        hookfiles: unable to add "/usr/sbin/losetup":
#        getFile: failed to stat file "/usr/sbin/losetup":
#        stat /usr/sbin/losetup: no such file or directory
#   2. Some hookfile fragments reference udev/udev.conf which doesn't
#      ship in modern eudev; strip the offending lines.
#   3. boot-deploy needs /proc/mounts (`df --output=avail`) and GNU
#      bc (multi-char vars). Bind-mount proc/sys/dev into the chroot
#      and force PATH so /usr/bin shadows busybox.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME

_atomos_mkinitfs_container_body() {
    cat <<'MKI_BODY'
# ---- losetup path fix --------------------------------------------
if [ ! -e /target/usr/sbin/losetup ]; then
    if [ -e /target/sbin/losetup ]; then
        mkdir -p /target/usr/sbin
        ln -sf ../../sbin/losetup /target/usr/sbin/losetup
        echo "fixup: created /usr/sbin/losetup -> /sbin/losetup"
    else
        echo "ERROR: /target/sbin/losetup is missing; losetup apk did not install correctly." >&2
        ls -la /target/sbin/ /target/usr/sbin/ 2>/dev/null | head -40 >&2 || true
        exit 1
    fi
fi

# ---- mkinitfs hook compat patches --------------------------------
for f in /target/usr/share/mkinitfs/files/*.files \
         /target/etc/mkinitfs/files/*.files; do
    [ -f "$f" ] || continue
    if grep -q "udev/udev.conf" "$f" 2>/dev/null; then
        sed -i "/udev\/udev\.conf/d" "$f"
        echo "fixup: patched udev.conf reference out of $f"
    fi
done

# ---- stale dm cleanup in init_2nd.sh (FP4 super partition) -----------
# init_2nd.sh calls setup_dynamic_partitions at line 31, BEFORE hooks
# run at line 33. Hooks run too late -- make-dynpart-mappings has
# already tripped on "Resource busy" by then. Inject the cleanup
# directly into init_2nd.sh right before setup_dynamic_partitions.
# dmsetup IS available here: init.sh already loaded initramfs-extra
# (which includes /sbin/dmsetup) before exec'ing init_2nd.sh.
init_2nd=/target/usr/share/initramfs/init_2nd.sh
if [ -f "$init_2nd" ]; then
    if grep -q "ATOMOS_DYN_PART_DM_CLEANUP_BEGIN" "$init_2nd"; then
        echo "fixup: init_2nd.sh already has dm cleanup"
    elif grep -q 'setup_dynamic_partitions' "$init_2nd"; then
        cat > /tmp/dm-cleanup-2nd.snippet <<'DMSNIPPET'
# ATOMOS_DYN_PART_DM_CLEANUP_BEGIN
for _atomos_part in system system_ext product vendor odm vendor_dlkm system_dlkm odm_dlkm; do
    for _atomos_slot in a b; do
        _atomos_map="${_atomos_part}_${_atomos_slot}"
        if [ -e "/dev/mapper/${_atomos_map}" ] && ! grep -q " /dev/mapper/${_atomos_map} " /proc/mounts 2>/dev/null; then
            dmsetup remove -f "${_atomos_map}" 2>/dev/null || true
        fi
    done
done || true
# ATOMOS_DYN_PART_DM_CLEANUP_END
DMSNIPPET
        awk -v snippet_file=/tmp/dm-cleanup-2nd.snippet '
            /^[[:space:]]*setup_dynamic_partitions/ && !inserted {
                while ((getline line < snippet_file) > 0) print line
                close(snippet_file)
                inserted = 1
            }
            { print }
        ' "$init_2nd" > "$init_2nd.new"
        mv "$init_2nd.new" "$init_2nd"
        chmod 0755 "$init_2nd"
        echo "fixup: injected dm cleanup into $init_2nd before setup_dynamic_partitions"
        rm -f /tmp/dm-cleanup-2nd.snippet
    else
        echo "fixup: WARN init_2nd.sh present but no setup_dynamic_partitions anchor" >&2
    fi
else
    echo "fixup: WARN $init_2nd missing -- postmarketos-initramfs may not be installed" >&2
fi

# Also install a hook as belt-and-braces (hooks run later but catch any
# entries that re-appear between init_2nd.sh injection and mount).
mkdir -p /target/usr/share/initramfs/hooks
cat > /target/usr/share/initramfs/hooks/00-atomos-dm-cleanup.sh <<'HOOKSCRIPT'
#!/bin/sh
for _part in system system_ext product vendor odm vendor_dlkm system_dlkm odm_dlkm; do
    for _slot in a b; do
        _map="${_part}_${_slot}"
        if [ -e "/dev/mapper/${_map}" ] && ! grep -q " /dev/mapper/${_map} " /proc/mounts 2>/dev/null; then
            dmsetup remove -f "${_map}" 2>/dev/null || true
        fi
    done
done || true
HOOKSCRIPT
chmod 0755 /target/usr/share/initramfs/hooks/00-atomos-dm-cleanup.sh
cat > /target/usr/share/mkinitfs/files/30-atomos-dm-cleanup.files <<'HOOKFILES'
usr/share/initramfs/hooks/00-atomos-dm-cleanup.sh
HOOKFILES
echo "fixup: installed 00-atomos-dm-cleanup.sh hook (belt-and-braces)"

# Remove any prior text-injection in other files.
init_functions=/target/usr/share/initramfs/init_functions.sh
if [ -f "$init_functions" ] && grep -q "ATOMOS_DYN_PART_DM_CLEANUP_BEGIN" "$init_functions"; then
    sed -i '/# ATOMOS_DYN_PART_DM_CLEANUP_BEGIN/,/# ATOMOS_DYN_PART_DM_CLEANUP_END/d' "$init_functions"
    echo "fixup: removed stale dm injection from $init_functions"
fi
init_script=/target/usr/share/initramfs/init.sh
if [ -f "$init_script" ] && grep -q "ATOMOS_DYN_PART_DM_CLEANUP_BEGIN" "$init_script"; then
    sed -i '/# ATOMOS_DYN_PART_DM_CLEANUP_BEGIN/,/# ATOMOS_DYN_PART_DM_CLEANUP_END/d' "$init_script"
    echo "fixup: removed stale dm injection from $init_script"
fi

# ---- chroot bind mounts ------------------------------------------
for fs in proc sys dev dev/pts; do mkdir -p /target/$fs; done
mount -t proc proc        /target/proc
mount -t sysfs sysfs      /target/sys
mount --bind /dev         /target/dev
mount --bind /dev/pts     /target/dev/pts 2>/dev/null || mount -t devpts devpts /target/dev/pts
cleanup() {
    umount /target/dev/pts 2>/dev/null || true
    umount /target/dev     2>/dev/null || true
    umount /target/sys     2>/dev/null || true
    umount /target/proc    2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---- depmod -a (CRITICAL for FP4) --------------------------------
# linux-postmarketos-qcom-sm6350's apk trigger normally runs depmod -a,
# but apk --root /target add can drop triggers when running under
# qemu-user emulation (no error reported). Without modules.dep being
# regenerated for the actual installed module set, udev can't resolve
# modaliases at boot -- exactly the
#   udevd: /lib/modules/<KVER>/.../qcom_common.ko.zst error=No such thing as a directory
# message we hit. Re-run depmod here so modules.dep matches what is on
# disk. KVER comes from /target/lib/modules/ (there should be exactly
# one entry).
KVER_DIR=$(ls -1 /target/lib/modules 2>/dev/null | head -1)
if [ -n "$KVER_DIR" ]; then
    if chroot /target /usr/bin/env PATH=/usr/sbin:/sbin:/usr/bin:/bin \
        depmod -a "$KVER_DIR" 2>&1 | sed 's/^/  depmod: /'; then
        echo "fixup: depmod -a $KVER_DIR completed"
    else
        echo "fixup: WARN depmod -a $KVER_DIR returned non-zero" >&2
    fi
else
    echo "fixup: WARN /target/lib/modules is empty -- linux-postmarketos-qcom-sm6350 missing?" >&2
fi

# ---- regenerate initramfs (and trigger boot-deploy) --------------
echo "fixup: regenerating initramfs"
if [ -x /target/sbin/postmarketos-mkinitfs ] || [ -x /target/usr/sbin/postmarketos-mkinitfs ]; then
    chroot /target /usr/bin/env PATH=/usr/bin:/usr/sbin:/sbin:/bin postmarketos-mkinitfs
else
    chroot /target /usr/bin/env PATH=/usr/bin:/usr/sbin:/sbin:/bin mkinitfs
fi

# ---- post-mkinitfs assertions ------------------------------------
if ! ls /target/boot/initramfs* >/dev/null 2>&1; then
    echo "ERROR: post-fixup mkinitfs run did not produce any initramfs in /target/boot/." >&2
    ls -la /target/boot/ >&2
    exit 2
fi
echo "fixup: initramfs files now under /target/boot/:"
ls -la /target/boot/initramfs* >&2
if ls /target/boot/boot.img* >/dev/null 2>&1; then
    echo "fixup: boot-deploy produced boot.img file(s):"
    ls -la /target/boot/boot.img* >&2
else
    echo "fixup: WARN no boot.img under /target/boot/ after mkinitfs; bootimg step will assemble manually." >&2
fi
MKI_BODY
}

atomos_mkinitfs_fixup() {
    echo "=== build-fairphone4-v2: post-bootstrap mkinitfs + boot-deploy fixup ==="
    "$ENGINE" run --rm --privileged --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_mkinitfs_container_body)"
}
