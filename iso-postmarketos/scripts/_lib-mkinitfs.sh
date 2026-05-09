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

# ---- subpartition dm cleanup snippet (FP4 super partition) ----------
# Mirrors apply_mkinitfs_subpartition_dm_compat from d6405345 build-image.sh.
# postmarketos-initramfs ships /usr/share/initramfs/init_functions.sh which
# contains a "Mount subpartitions of $partition" block. On FP4 the kernel
# remembers /dev/mapper/<part>_<slot> entries from previous boots; the
# initramfs hook then trips over them with:
#   udev[271]: conflicting device node '/dev/mapper/odm_a' found,
#       link to '/dev/dm-4' will not be created
# pmbootstrap's path patches the pmaports cache so the BUILT apk has the
# cleanup snippet baked in. We can't patch the apk source (it's a binary
# pull), so we patch the EXTRACTED file in /target before mkinitfs reads
# it into the new initramfs cpio. Idempotent (marker comment guards
# against double-insertion).
init_functions=/target/usr/share/initramfs/init_functions.sh
if [ -f "$init_functions" ]; then
    if grep -q "ATOMOS_DYN_PART_DM_CLEANUP_BEGIN" "$init_functions"; then
        echo "fixup: init_functions.sh already has dm cleanup snippet"
    elif grep -q 'echo "Mount subpartitions of ' "$init_functions"; then
        # Build the snippet in a temp file and inject it before the
        # "Mount subpartitions of" echo. Single-quoted heredoc so the
        # busybox-shell-isms ($_atomos_part etc.) survive verbatim.
        cat > /tmp/dm-cleanup.snippet <<'DMSNIPPET'
				# ATOMOS_DYN_PART_DM_CLEANUP_BEGIN
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
DMSNIPPET
        # Use awk for the insertion (sed is fiddly with multi-line content).
        awk -v snippet_file=/tmp/dm-cleanup.snippet '
            /^[[:space:]]*echo "Mount subpartitions of / && !inserted {
                while ((getline line < snippet_file) > 0) print line
                close(snippet_file)
                inserted = 1
            }
            { print }
        ' "$init_functions" > "$init_functions.new"
        mv "$init_functions.new" "$init_functions"
        chmod 0644 "$init_functions"
        echo "fixup: injected dm cleanup snippet into $init_functions"
        rm -f /tmp/dm-cleanup.snippet
    else
        echo "fixup: WARN init_functions.sh present but no 'Mount subpartitions of' anchor; skipping dm cleanup patch" >&2
    fi
else
    echo "fixup: WARN $init_functions missing -- postmarketos-initramfs may not be installed" >&2
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
