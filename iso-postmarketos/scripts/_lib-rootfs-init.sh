# shellcheck shell=bash
# scripts/_lib-rootfs-init.sh -- post-bootstrap rootfs configuration
# (hostname, fstab, runlevel symlinks, pmaports overlay drops, sshd
# sanitize, ssh host-key gen).
#
# Splits Step 2 of the original build-fairphone4.sh into focused
# helpers. User creation is intentionally NOT here -- it lives in
# _lib-rootfs-users.sh because it has its own diagnostic story.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME ROOT_DIR
# PROFILE_NAME PMOS_USER_UID

# Container body: write hostname + fstab + runlevel symlinks + pmaports
# config drops + sshd sanitize. All of this is rootfs file plumbing
# (no user/group state, no chroot apk runs) -- safe to do in one pass.
_atomos_init_container_body() {
    cat <<'INIT_BODY'
mkdir -p /target/etc /target/boot /target/etc/network /target/etc/conf.d
printf "%s\n" "$PROFILE_NAME" > /target/etc/hostname

# Minimal fstab. FP4's rootfs is mounted by postmarketos-initramfs via
# dynamic partitions (make-dynpart-mappings), so we only need the
# kernel virtual filesystems here -- ext4 root mount happens earlier.
cat > /target/etc/fstab <<EOF
proc            /proc           proc    defaults        0 0
sysfs           /sys            sysfs   defaults        0 0
devpts          /dev/pts        devpts  defaults        0 0
tmpfs           /tmp            tmpfs   defaults        0 0
EOF

mkdir -p /target/etc/runlevels/sysinit \
         /target/etc/runlevels/boot \
         /target/etc/runlevels/default

# All runlevel symlinks are RELATIVE (../../init.d/X) so they
# resolve correctly whether the rootfs is mounted at /, /target,
# or /mnt/recovery. Matches what `rc-update add` would produce on
# a real OpenRC system.
ln_runlevel() { # ln_runlevel <init.d-name> <runlevel>
    ln -sf "../../init.d/$1" "/target/etc/runlevels/$2/$1" || true
}

# Sysinit
for s in udev udev-trigger udev-settle; do ln_runlevel "$s" sysinit; done

# --- BOOT runlevel ----------------------------------------------------
# IMPORTANT for headless FP4 debug:
# OpenRC runs the BOOT runlevel SEQUENTIALLY before DEFAULT. Anything
# we put here is guaranteed to be running by the time DEFAULT-runlevel
# services (greetd, etc.) even start. So we put SSH + USB networking
# here -- if greetd or any other DEFAULT service hangs the boot, we
# can still SSH to the device at 172.16.42.1 to investigate.
#
# dbus is also pulled forward because both NetworkManager and usb-moded
# need it. seatd + elogind likewise so a user shell at the console has
# a working seat without waiting for default-runlevel deps.
for s in hostname bootmisc syslog modules \
         dbus seatd elogind \
         networkmanager wpa_supplicant \
         sshd; do
    ln_runlevel "$s" boot
done
# usb-moded brings up usb0 (172.16.42.1) + unudhcpd via the
# developer_mode_openrc dyn-mode hook. Put it in boot too so the
# ethernet gadget is up by the time the host plugs the USB cable in.
if [ -f /target/etc/init.d/usb-moded ]; then
    ln_runlevel usb-moded boot
fi

# --- DEFAULT runlevel -------------------------------------------------
# NOTE on display manager: we use GREETD+PHROG -- matches what the
# current postmarketos-ui-phosh-openrc package (pkgver=28) does:
#   depends="greetd-openrc"
#   replaces="greetd-openrc"
#   post-install: rc-update add greetd default
# We do this manually here instead of installing postmarketos-ui-phosh
# (whose post-install runs through apk's qemu-user emulation and has
# been a source of lockfile races / silent failures on this build path).
#
# Greetd can be SUPPRESSED at build time by setting
#   ATOMOS_FP4V2_DEBUG_NO_GREETD=1
# (orchestrator passes it through). With greetd not in the runlevel
# the device boots into a getty / SSH-reachable state without any DM
# trying to start, so a developer can `rc-service greetd start`
# manually and watch the failure live.
for s in cgroups haveged chronyd udev-postmount bluetooth \
         iio-sensor-proxy apk-polkit-server sleep-inhibitor \
         openrc-settingsd modemmanager \
         zram-init rfkill; do
    ln_runlevel "$s" default
done
if [ "${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" = "1" ]; then
    echo "init: ATOMOS_FP4V2_DEBUG_NO_GREETD=1 -- skipping greetd in default runlevel"
    echo "       (greetd binary, config, init.d still present; start manually with"
    echo "        sudo rc-service greetd start)"
else
    ln_runlevel greetd default
fi

# FP4-specific: hexagonrpcd (Qualcomm fastrpc daemon) when the apk
# dropped its init script. Suppress at build time with
#   ATOMOS_FP4V2_DEBUG_NO_HEXAGONRPCD=1
# (helpful when fastrpc user creation fails under qemu-user race).
if [ -f /target/etc/init.d/hexagonrpcd ] \
    && [ "${ATOMOS_FP4V2_DEBUG_NO_HEXAGONRPCD:-0}" != "1" ]; then
    ln_runlevel hexagonrpcd default
fi

# pmaports config drops. We pull from /iso/pmaports/main since the
# FP4 build uses the vendored pmaports tree.
mkdir -p /target/usr/share/glib-2.0/schemas \
         /target/usr/share/applications \
         /target/etc/xdg/autostart \
         /target/etc/chrony \
         /target/etc/elogind \
         /target/etc/X11 \
         /target/usr/lib/NetworkManager/conf.d \
         /target/usr/lib/NetworkManager/dispatcher.d \
         /target/usr/share/wireplumber/wireplumber.conf.d \
         /target/usr/lib/udev/rules.d \
         /target/usr/share/mkinitfs/files \
         /target/usr/share/flatpak/remotes.d \
         /target/etc/profile.d \
         /target/etc/skel
PM=/iso/pmaports/main
install_pm() {  # install_pm <relpath-under-PM> <target-abs-path>
    if [ -f "$PM/$1" ]; then
        install -Dm644 "$PM/$1" "/target$2"
    fi
}
install_pm postmarketos-ui-phosh/01_postmarketos-ui-phosh.gschema.override \
    /usr/share/glib-2.0/schemas/01_postmarketos-ui-phosh.gschema.override
install_pm postmarketos-ui-phosh/mimeapps.list /usr/share/applications/mimeapps.list
install_pm postmarketos-ui-phosh/udiskie.desktop /etc/xdg/autostart/udiskie.desktop
install_pm postmarketos-base-ui-gnome/00_postmarketos-base-ui-gnome.gschema.override \
    /usr/share/glib-2.0/schemas/00_postmarketos-base-ui-gnome.gschema.override
install_pm postmarketos-base-ui-gnome/10_postmarketos-green-accent.gschema.override \
    /usr/share/glib-2.0/schemas/10_postmarketos-green-accent.gschema.override
install_pm postmarketos-artwork/10_pmOS-wallpaper.gschema.override \
    /usr/share/glib-2.0/schemas/10_pmOS-wallpaper.gschema.override

# Recompile gschema cache so overrides take effect at runtime.
glib-compile-schemas /target/usr/share/glib-2.0/schemas/ 2>/dev/null || true

# Override prebuilt postmarketos-usb-moded files with our patched versions from the vendored pmaports tree
USB_MODED_PM="postmarketos-usb-moded"
if [ -d "$PM/$USB_MODED_PM" ]; then
    install -Dm755 "$PM/$USB_MODED_PM/rootfs-usr-bin-usb-moded-developer-mode" /target/usr/bin/usb-moded-developer-mode
    install -Dm755 "$PM/$USB_MODED_PM/rootfs-usr-bin-usb-moded-tethering-mode" /target/usr/bin/usb-moded-tethering-mode
    install -Dm755 "$PM/$USB_MODED_PM/rootfs-etc-init.d-usb-moded-developer-mode.initd" /target/etc/init.d/usb-moded-developer-mode
    install -Dm755 "$PM/$USB_MODED_PM/rootfs-etc-init.d-usb-moded-tethering-mode.initd" /target/etc/init.d/usb-moded-tethering-mode
    install -Dm644 "$PM/$USB_MODED_PM/rootfs-etc-usb-moded-configfs.ini" /target/etc/usb-moded/configfs.ini
    install -Dm644 "$PM/$USB_MODED_PM/rootfs-etc-usb-moded-dyn-modes-developer_mode_openrc.ini" /target/etc/usb-moded/dyn-modes/developer_mode_openrc.ini
    install -Dm644 "$PM/$USB_MODED_PM/rootfs-etc-usb-moded-dyn-modes-tethering_mode_openrc.ini" /target/etc/usb-moded/dyn-modes/tethering_mode_openrc.ini
    install -Dm644 "$PM/$USB_MODED_PM/rootfs-etc-usb-moded-dyn-modes-mtp_ffs_mode_openrc.ini" /target/etc/usb-moded/dyn-modes/mtp_ffs_mode_openrc.ini
    install -Dm644 "$PM/$USB_MODED_PM/rootfs-etc-umtprd-umtprd.conf" /target/etc/umtprd/umtprd.conf

    # Ensure default mode is developer mode
    mkdir -p /target/etc/usb-moded
    cat << 'EOF' > /target/etc/usb-moded/usbmode.ini
[usbmode]
mode = developer_mode
EOF
fi


# greetd config: point greetd at our session (V2) or phrog (V1).
mkdir -p /target/etc/conf.d
if [ "${ATOMOS_V2:-0}" = "1" ]; then
    cat > /target/etc/conf.d/greetd <<'GREETD_CONFD'
# Configuration for greetd
cfgfile="/etc/greetd/config.toml"
GREETD_CONFD

    mkdir -p /target/etc/greetd
    cat > /target/etc/greetd/config.toml <<'GREETD_TOML'
[terminal]
vt = 7

[default_session]
command = "/usr/bin/atomos-session"
user = "user"

[initial_session]
command = "/usr/bin/atomos-session"
user = "user"
GREETD_TOML
else
    cat > /target/etc/conf.d/greetd <<'GREETD_CONFD'
# Configuration for greetd
# Path to config file to use (phrog provides this)
cfgfile="/etc/phrog/greetd-config.toml"
GREETD_CONFD
fi

# sshd policy sanitize. Some OpenSSH builds in this image path do
# not support UsePAM; if left in place sshd exits at boot and
# hostfwd :2222 hangs. Strip the directive.
if [ -f /target/etc/ssh/sshd_config ]; then
    sed -i '/^[[:space:]]*PasswordAuthentication/d' /target/etc/ssh/sshd_config
    echo "PasswordAuthentication yes" >> /target/etc/ssh/sshd_config
    sed -i '/^[[:space:]]*PermitRootLogin/d' /target/etc/ssh/sshd_config
    echo "PermitRootLogin no" >> /target/etc/ssh/sshd_config
fi
if [ -f /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf ]; then
    sed -i '/^[[:space:]]*UsePAM[[:space:]]\+/d' /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    sed -i '/^[[:space:]]*PasswordAuthentication/d' /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    echo "PasswordAuthentication yes" >> /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    sed -i '/^[[:space:]]*PermitRootLogin/d' /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    echo "PermitRootLogin no" >> /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
fi
# Pre-generate SSH host keys so first boot has a ready sshd.
if [ -x /target/usr/bin/ssh-keygen ]; then
    chroot /target /usr/bin/ssh-keygen -A >/dev/null 2>&1 || true
fi

# --- pmbootstrap parity: setup_locale + setup_timezone + skel home ------
# pmbootstrap (pmb/install/_install.py:1342-1352) does these between
# apk install and final boot.img assembly. They are not strictly
# required for the device to boot, but matching pmbootstrap's behavior
# means fewer "works on pmbootstrap, not on us" surprises later.

# setup_timezone: pmbootstrap uses `setup-timezone -i UTC`. setup-timezone
# is from alpine-conf, which we install via alpine-baselayout deps.
if [ -x /target/sbin/setup-timezone ] || [ -x /target/usr/sbin/setup-timezone ]; then
    chroot /target /usr/bin/env PATH=/usr/sbin:/sbin:/usr/bin:/bin \
        setup-timezone -i UTC >/dev/null 2>&1 || true
    echo "init: setup-timezone -i UTC"
fi

# setup_locale: matches pmb/install/_install.py:381-409. Without this,
# user-facing apps default to C.UTF-8 with no LANG set, and various
# GNOME / Phosh utilities log warnings.
mkdir -p /target/etc /target/etc/profile.d
echo 'LANG=C.UTF-8' > /target/etc/locale.conf
printf '#!/bin/sh\nsource /etc/locale.conf\nexport LANG\n' > /target/etc/profile.d/10locale-pmos.sh
chmod 0755 /target/etc/profile.d/10locale-pmos.sh

# postmarketos-base-nftables-openrc.post-install may symlink nftables into
# default when apk pulls postmarketos-config-nftables (via device-fairphone-fp4
# -> postmarketos-base). That config ends with 99_drop_log.nft which drops all
# input not matched earlier; USB NCM gadgets often expose ifnames like enp*
# rather than usb*, so ping/SSH over 172.16.42.1 can fail while the host still
# sees layer-3 reachability. Default OFF on this build path (matches qemu).
if [ "${ATOMOS_ENABLE_NFTABLES:-0}" = "1" ]; then
    ln_runlevel nftables boot
else
    rm -f /target/etc/runlevels/default/nftables \
          /target/etc/runlevels/boot/nftables
    echo "init: nftables service not enabled in runlevel (ATOMOS_ENABLE_NFTABLES!=1)"
fi

# Debug/Developer Mode firewall exceptions when nftables is used manually.
if [ "${ATOMOS_DEBUG_FIREWALL:-0}" = "1" ]; then
    mkdir -p /target/etc/nftables.d
    # pmaports ships a blanket drop as 99_drop_log.nft; remove it for developer
    # images so SSH/USB debug is not silently blocked.
    rm -f /target/etc/nftables.d/99_drop_log.nft
    cat > /target/etc/nftables.d/55_atomos_developer_usb.nft <<'EOF'
#!/usr/sbin/nft -f
table inet filter {
    chain input {
        iifname { "usb*", "rndis*", "ncm*", "eth*", "enp*", "ens*" } accept comment "debug netdevs"
        ip saddr { 172.16.42.0/16, 10.0.2.0/24 } accept comment "USB gadget + QEMU SLIRP"
        tcp dport { 22, 2222 } accept comment "SSH in Debug/Developer Mode"
    }
}
EOF
    chmod 0644 /target/etc/nftables.d/55_atomos_developer_usb.nft
    echo "init: developer nftables exceptions (USB subnet + SSH, drop-log removed)"

    # Make sure the main nftables.nft config includes the rules in nftables.d/
    if [ -f /target/etc/nftables.nft ]; then
        if ! grep -F -q 'include "/etc/nftables.d/*.nft"' /target/etc/nftables.nft; then
            echo 'include "/etc/nftables.d/*.nft"' >> /target/etc/nftables.nft
            echo "init: Appended include for /etc/nftables.d/*.nft to /etc/nftables.nft"
        fi
    else
        cat > /target/etc/nftables.nft <<'EOF'
flush ruleset
include "/etc/nftables.d/*.nft"
EOF
        echo "init: Created /etc/nftables.nft with include for /etc/nftables.d/*.nft"
    fi
fi

# create_home_from_skel: matches pmb/install/_install.py:162-174.
# Many GNOME/Phosh apps rely on /etc/skel templates being copied into
# /home/user (e.g. .config dotfiles). Without this they create the
# user's home from scratch on first launch.
if [ -d /target/etc/skel ] && [ ! -e /target/home/user/.skel-applied ]; then
    cp -an /target/etc/skel/. /target/home/user/ 2>/dev/null || true
    touch /target/home/user/.skel-applied
    chown -R "${PMOS_USER_UID}:${PMOS_USER_UID}" /target/home/user 2>/dev/null || true
    echo "init: copied /etc/skel/ -> /home/user/ (uid ${PMOS_USER_UID})"
fi
INIT_BODY
}

atomos_init_rootfs_basics() {
    echo "=== build-fairphone4-v2: base rootfs configuration ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        -e PROFILE_NAME="$PROFILE_NAME" \
        -e PMOS_USER_UID="$PMOS_USER_UID" \
        -e ATOMOS_V2="${ATOMOS_V2:-0}" \
        -e ATOMOS_FP4V2_DEBUG_NO_GREETD="${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" \
        -e ATOMOS_FP4V2_DEBUG_NO_HEXAGONRPCD="${ATOMOS_FP4V2_DEBUG_NO_HEXAGONRPCD:-0}" \
        -e ATOMOS_DEBUG_FIREWALL="${ATOMOS_DEBUG_FIREWALL:-${ATOMOS_DEVELOPER_MODE:-0}}" \
        -e ATOMOS_ENABLE_NFTABLES="${ATOMOS_ENABLE_NFTABLES:-0}" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$ROOT_DIR:/iso:ro" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_init_container_body)"
}
