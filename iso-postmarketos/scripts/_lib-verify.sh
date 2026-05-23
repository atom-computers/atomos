# shellcheck shell=bash
# scripts/_lib-verify.sh -- final-verify and pre-pack assertion helpers.
#
# Two entry points:
#   atomos_verify_rootfs            -- run after overlays applied
#   atomos_assert_prepack_invariants -- run right before sparse pack
#
# Predicates (check_x / check_f / check_link / check_grep) live INSIDE
# the container body so they see the rootfs paths directly. The
# orchestrator just calls one of the entry points.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME
# BUILD_OVERVIEW_CHAT_UI BUILD_HOME_BG BUILD_APP_HANDLER

_atomos_verify_predicates_body() {
    cat <<'PRED_BODY'
FAIL=0
check_x() {
    if [ -x "$1" ]; then echo "  ok  -x $1"
    else echo "  FAIL -x $1" >&2; FAIL=1; fi
}
check_f() {
    if [ -f "$1" ]; then echo "  ok  -f $1"
    else echo "  FAIL -f $1" >&2; FAIL=1; fi
}
check_link() {
    if [ -L "$1" ]; then
        echo "  ok  symlink $1 -> $(readlink "$1")"
    elif [ -e "$1" ]; then
        echo "  ok  exists $1"
    else
        echo "  FAIL symlink/exists $1" >&2; FAIL=1
    fi
}
check_grep() {
    if [ -f "$2" ] && grep -q "$1" "$2"; then echo "  ok  grep $1 in $2"
    else echo "  FAIL grep $1 in $2" >&2; FAIL=1; fi
}
PRED_BODY
}

_atomos_verify_container_body() {
    cat <<VERIFY_BODY
$(_atomos_verify_predicates_body)

echo "--- core binaries ---"
check_x /target/usr/libexec/phosh
check_x /target/usr/sbin/sshd
check_x /target/usr/bin/mkbootimg
check_f /target/etc/ssh/ssh_host_ed25519_key
check_f /target/etc/ssh/ssh_host_rsa_key

echo "--- greetd + phrog wiring (matches postmarketos-ui-phosh-openrc) ---"
# phosh ships its main binary at /usr/libexec/phosh (already checked
# above under "core binaries"). It does NOT install a /usr/bin/phosh
# launcher; greetd-phrog's session helper /usr/libexec/phrog-greetd-session
# is what spawns it. Keep the libexec check authoritative; do not
# require a /usr/bin/phosh shim that pmaports never created.
check_x /target/usr/bin/phrog
check_x /target/usr/libexec/phrog-greetd-session
check_x /target/etc/init.d/greetd
check_x /target/etc/init.d/seatd
check_x /target/etc/init.d/elogind
# In v2 we move sshd, dbus, seatd, elogind, networkmanager, usb-moded
# to the BOOT runlevel (so they come up before any DEFAULT-runlevel
# service can hang). Accept the symlink in either runlevel.
check_link_in_runlevel() {
    local svc="\$1"
    if [ -L "/target/etc/runlevels/boot/\$svc" ]; then
        echo "  ok  symlink /etc/runlevels/boot/\$svc -> \$(readlink "/target/etc/runlevels/boot/\$svc")"
    elif [ -L "/target/etc/runlevels/default/\$svc" ]; then
        echo "  ok  symlink /etc/runlevels/default/\$svc -> \$(readlink "/target/etc/runlevels/default/\$svc")"
    else
        echo "  FAIL \$svc not in boot or default runlevel" >&2
        FAIL=1
    fi
}
check_link_in_runlevel seatd
check_link_in_runlevel elogind

# greetd in default runlevel: respect ATOMOS_FP4V2_DEBUG_NO_GREETD.
# Build can intentionally suppress greetd at boot so a developer can
# SSH in and start it manually to see the failure live.
if [ "\${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" = "1" ]; then
    if [ ! -L /target/etc/runlevels/default/greetd ] && [ ! -e /target/etc/runlevels/default/greetd ]; then
        echo "  ok  greetd NOT in default runlevel (DEBUG_NO_GREETD=1 honored)"
    else
        echo "  FAIL DEBUG_NO_GREETD=1 set but greetd is still in default runlevel" >&2
        FAIL=1
    fi
else
    check_link /target/etc/runlevels/default/greetd
fi

check_f /target/etc/conf.d/greetd
check_grep "phrog/greetd-config.toml" /target/etc/conf.d/greetd
check_f /target/etc/phrog/greetd-config.toml
check_f /target/etc/pam.d/greetd

# sshd MUST be present in either boot or default for headless debug.
if [ -L /target/etc/runlevels/boot/sshd ]; then
    echo "  ok  sshd in BOOT runlevel (sequential before default; reachable even if greetd hangs)"
elif [ -L /target/etc/runlevels/default/sshd ]; then
    echo "  ok  sshd in default runlevel"
else
    echo "  FAIL sshd not enabled in any runlevel" >&2
    FAIL=1
fi
# usb-moded similarly.
if [ -L /target/etc/runlevels/boot/usb-moded ]; then
    echo "  ok  usb-moded in BOOT runlevel"
elif [ -L /target/etc/runlevels/default/usb-moded ]; then
    echo "  ok  usb-moded in default runlevel"
else
    echo "  WARN usb-moded not enabled (USB ethernet 172.16.42.1 will not come up)"
fi

# Greetd setuid()s to the user named in the toml. If that user does not
# resolve via getent, greetd exits before writing its pidfile and
# OpenRC times out reporting "ERROR: greetd failed to start".
session_user=\$(awk -F"=" '/^[[:space:]]*user[[:space:]]*=/{gsub(/[\"[:space:]]/,"",\$2); print \$2; exit}' \
    /target/etc/phrog/greetd-config.toml 2>/dev/null)
session_user=\${session_user:-greetd}
echo "  greetd config session user: \"\$session_user\""
if chroot /target /bin/sh -c "getent passwd \$session_user >/dev/null 2>&1"; then
    chroot /target /bin/sh -c "getent passwd \$session_user" | sed "s|^|  ok  |"
else
    echo "  FAIL '\$session_user' does NOT resolve via getent" >&2
    grep -nE "^\$session_user:" /target/etc/passwd /target/etc/group /target/etc/shadow >&2 || echo "(no matches)" >&2
    FAIL=1
fi

# Login user (uid 10000) must exist for autologin / login screen.
if chroot /target /bin/sh -c "getent passwd user >/dev/null 2>&1"; then
    chroot /target /bin/sh -c "getent passwd user" | sed "s|^|  ok  |"
else
    echo "  FAIL getent passwd user fails -- no login user (uid 10000)" >&2
    FAIL=1
fi

# tinydm should NOT also be in default (would race greetd for VT/seat).
if [ -L /target/etc/runlevels/default/tinydm ] || [ -e /target/etc/runlevels/default/tinydm ]; then
    echo "  FAIL tinydm is also in default runlevel -- it will race greetd for the seat" >&2
    FAIL=1
else
    echo "  ok  tinydm NOT in default runlevel (correct; greetd is the DM)"
fi

echo "--- FP4 device package files ---"
check_f /target/usr/share/alsa/ucm2/Fairphone/fp4/HiFi.conf
check_f /target/usr/share/alsa/ucm2/Fairphone/fp4/fp4.conf
check_f /target/usr/share/wireplumber/wireplumber.conf.d/52-fairphone-fp4.conf
check_f /target/usr/lib/udev/rules.d/81-libssc-fairphone-fp4.rules
if ls /target/boot/vmlinuz* >/dev/null 2>&1; then
    echo "  ok  found /target/boot/vmlinuz*"
else
    echo "  FAIL no kernel image under /target/boot/" >&2; FAIL=1
fi

echo "--- usr-merge symlinks (CRITICAL for firmware lookup) ---"
# pmaports.cfg supported_usr_merge=True. Files in packages live at
# /usr/lib/firmware/... but the kernel looks at /lib/firmware/... The
# only thing bridging the two is /lib being a symlink to /usr/lib.
# If /lib is a real directory here, every firmware lookup at boot
# will silently fail (a630_sqe.fw not found, etc.).
for d in bin sbin lib; do
    if [ -L /target/\$d ]; then
        echo "  ok  /\$d -> \$(readlink /target/\$d)"
    else
        echo "  FAIL /\$d is NOT a symlink (usr-merge broken; firmware will not load at boot)" >&2
        FAIL=1
    fi
done

echo "--- FP4 firmware files (without these, no GPU/audio/modem at boot) ---"
# These paths come straight from the pmaports APKBUILDs:
#   pmaports/device/community/firmware-qcom-adreno/APKBUILD
#   pmaports/device/community/firmware-fairphone-fp4/APKBUILD
# Boot symptom of any miss: kernel reports "failed to load <fw>" early
# in dmesg, the relevant remoteproc / GPU / panel never initialises,
# greetd's session worker can never open a wayland output, and OpenRC
# eventually reports "ERROR: greetd failed to start" 60s later as a
# downstream consequence.
check_f /target/lib/firmware/qcom/a630_sqe.fw
check_f /target/lib/firmware/qcom/a619_gmu.bin
check_f /target/lib/firmware/qcom/sm7225/fairphone4/a615_zap.mbn
check_f /target/lib/firmware/qcom/sm7225/fairphone4/adsp.mbn
check_f /target/lib/firmware/qcom/sm7225/fairphone4/cdsp.mbn
check_f /target/lib/firmware/qcom/sm7225/fairphone4/modem.mbn
check_f /target/lib/firmware/qcom/sm7225/fairphone4/ipa_fws.mbn
check_f /target/lib/firmware/qcom/sm7225/fairphone4/wlanmdsp.mbn
check_f /target/lib/firmware/qca/apbtfw11.tlv
check_f /target/lib/firmware/qca/apnv11.bin
check_f /target/lib/firmware/postmarketos/aw882xx_monitor.bin

echo "--- FP4 kernel modules ---"
# Find the actual KVER directory under /lib/modules/ -- pmOS kernels can
# be either bare ("7.0.0") or suffixed ("7.0.0-postmarketos-qcom-sm6350").
KVER_DIR=\$(ls -1 /target/lib/modules 2>/dev/null | head -1)
if [ -z "\$KVER_DIR" ]; then
    echo "  FAIL /target/lib/modules is empty -- linux-postmarketos-qcom-sm6350 did not install" >&2
    FAIL=1
else
    echo "  ok  /lib/modules/\$KVER_DIR exists"
    # modules.dep MUST exist for udev to resolve any modalias.
    if [ -f /target/lib/modules/\$KVER_DIR/modules.dep ]; then
        echo "  ok  /lib/modules/\$KVER_DIR/modules.dep exists"
    else
        echo "  FAIL /lib/modules/\$KVER_DIR/modules.dep missing -- depmod never ran" >&2
        FAIL=1
    fi
    # remoteproc directory should exist (qcom_common loads from here).
    # msm and iommu may be BUILT-IN to the kernel (CONFIG_DRM_MSM=y rather
    # than =m) -- that's the typical pmOS sm6350 config. So WARN, do not
    # FAIL, when they are not present as separate modules.
    for m in kernel/drivers/remoteproc; do
        full=/target/lib/modules/\$KVER_DIR/\$m
        if [ -e "\$full" ]; then
            echo "  ok  /lib/modules/\$KVER_DIR/\$m"
        else
            echo "  FAIL /lib/modules/\$KVER_DIR/\$m missing" >&2
            FAIL=1
        fi
    done
    for m in kernel/drivers/gpu/drm/msm kernel/drivers/iommu; do
        full=/target/lib/modules/\$KVER_DIR/\$m
        if [ -e "\$full" ]; then
            echo "  ok  /lib/modules/\$KVER_DIR/\$m (loadable module)"
        else
            echo "  note: /lib/modules/\$KVER_DIR/\$m absent (likely built into vmlinuz)"
        fi
    done
fi

echo "--- apk database state for FP4-relevant packages ---"
# This is the diagnostic that distinguishes the two failure modes:
#   1. apk thinks pkg installed but files missing -> need --force-overwrite re-extract
#   2. apk says pkg NOT installed -> the apk add transaction silently dropped it
for pkg in device-fairphone-fp4 \\
           linux-postmarketos-qcom-sm6350 \\
           firmware-qcom-adreno-a630-sqe \\
           firmware-fairphone-fp4-adreno \\
           firmware-fairphone-fp4-adsp \\
           firmware-fairphone-fp4-cdsp \\
           firmware-fairphone-fp4-modem \\
           firmware-fairphone-fp4-wlan \\
           firmware-fairphone-fp4-bluetooth \\
           firmware-fairphone-fp4-ipa \\
           firmware-fairphone-fp4-hexagonfs \\
           firmware-fairphone-fp4-audio; do
    if apk --root /target info -e "\$pkg" >/dev/null 2>&1; then
        ver=\$(apk --root /target info "\$pkg" 2>/dev/null | head -1)
        echo "  installed: \$ver"
    else
        echo "  MISSING (apk info -e returns false): \$pkg" >&2
        FAIL=1
    fi
done

if [ "\${BUILD_OVERVIEW_CHAT_UI:-1}" = "1" ]; then
    echo "--- atomos-overview-chat-ui files ---"
    check_x /target/usr/local/bin/atomos-overview-chat-ui
    check_x /target/usr/bin/atomos-overview-chat-ui
    check_x /target/usr/libexec/atomos-overview-chat-ui
    check_x /target/usr/libexec/atomos-overview-chat-submit
    check_grep "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME" /target/usr/libexec/atomos-overview-chat-ui
    check_grep "atomos-overview-chat-ui.disabled" /target/usr/libexec/atomos-overview-chat-ui
    check_f /target/etc/xdg/autostart/atomos-overview-chat-ui.desktop
    check_grep "Exec=/usr/libexec/atomos-overview-chat-ui --show" /target/etc/xdg/autostart/atomos-overview-chat-ui.desktop
    check_grep "OnlyShowIn=GNOME;Phosh;" /target/etc/xdg/autostart/atomos-overview-chat-ui.desktop
fi

if [ "\${BUILD_HOME_BG:-1}" = "1" ]; then
    echo "--- atomos-home-bg files ---"
    check_x /target/usr/local/bin/atomos-home-bg
    check_x /target/usr/bin/atomos-home-bg
    check_x /target/usr/libexec/atomos-home-bg
    check_f /target/usr/share/atomos-home-bg/index.html
    check_grep "ATOMOS_HOME_BG_ENABLE_RUNTIME" /target/usr/libexec/atomos-home-bg
    check_grep "atomos-home-bg.disabled"       /target/usr/libexec/atomos-home-bg
    check_grep "ATOMOS_HOME_BG_LAYER"          /target/usr/libexec/atomos-home-bg
    check_grep "ATOMOS_HOME_BG_INTERACTIVE"    /target/usr/libexec/atomos-home-bg
    check_f /target/etc/xdg/autostart/atomos-home-bg.desktop
    check_grep "Exec=/usr/libexec/atomos-home-bg --show" /target/etc/xdg/autostart/atomos-home-bg.desktop
    for lib in libwebkitgtk-6.0.so libgtk4-layer-shell.so libgtk-4.so; do
        if find /target/usr/lib /target/lib -name "\${lib}*" -maxdepth 3 2>/dev/null | grep -q .; then
            echo "  ok  found \${lib}*"
        else
            echo "  FAIL \${lib}* not found" >&2; FAIL=1
        fi
    done
fi

if [ "\${BUILD_APP_HANDLER:-1}" = "1" ]; then
    echo "--- atomos-app-handler files ---"
    check_x /target/usr/local/bin/atomos-app-handler
    check_x /target/usr/bin/atomos-app-handler
    check_x /target/usr/libexec/atomos-app-handler
    check_grep "ATOMOS_APP_HANDLER_ENABLE_RUNTIME" /target/usr/libexec/atomos-app-handler
    check_grep "atomos-app-handler.disabled" /target/usr/libexec/atomos-app-handler
    echo "--- atomos phosh-profile.env (phosh-session sources before phosh shell) ---"
    check_f /target/etc/atomos/phosh-profile.env
    check_grep "^ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1" /target/etc/atomos/phosh-profile.env
    check_grep "^ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1" /target/etc/atomos/phosh-profile.env
    check_grep "^ATOMOS_APP_HANDLER_TAKES_OVER=1" /target/etc/atomos/phosh-profile.env

    echo "--- atomos stack integration contract (Phosh + app-handler) ---"
    check_f /target/etc/atomos/app-handler-contract
    check_f /target/etc/atomos/phosh-integration-contract
    check_grep "^app-handler-v1-launch-switcher-dbus-home$" /target/etc/atomos/app-handler-contract
    check_grep "^app-handler-v1-launch-switcher-dbus-home$" /target/etc/atomos/phosh-integration-contract
    if [ -f /target/etc/atomos/app-handler-contract ] && [ -f /target/etc/atomos/phosh-integration-contract ]; then
        hv="\$(tr -d '[:space:]' < /target/etc/atomos/app-handler-contract)"
        pv="\$(tr -d '[:space:]' < /target/etc/atomos/phosh-integration-contract)"
        if [ "\$hv" = "\$pv" ]; then
            echo "  ok  phosh-integration-contract matches app-handler-contract (\$hv)"
        else
            echo "  FAIL contract mismatch: handler=\$hv phosh=\$pv" >&2
            FAIL=1
        fi
    fi
    libphosh="\$(find /target/usr/lib /target/lib -maxdepth 2 -name 'libphosh-*.so*' ! -name '*.a' 2>/dev/null | head -n 1)"
    if [ -n "\$libphosh" ] && strings "\$libphosh" 2>/dev/null | grep -q 'org.atomos.PhoshHome'; then
        echo "  ok  strings \$libphosh contains org.atomos.PhoshHome"
    else
        echo "  FAIL libphosh missing org.atomos.PhoshHome (stock phosh in image?)" >&2
        FAIL=1
    fi
    echo "--- atomos-app-handler hybrid lifecycle contract ---"
    check_grep "action=show" /target/usr/libexec/atomos-app-handler
    check_grep "action=hide" /target/usr/libexec/atomos-app-handler
    check_grep "signal_show" /target/usr/libexec/atomos-app-handler
    check_grep "signal_hide" /target/usr/libexec/atomos-app-handler
    check_grep "kill -USR1"  /target/usr/libexec/atomos-app-handler
    check_grep "kill -USR2"  /target/usr/libexec/atomos-app-handler
    check_f /target/etc/xdg/autostart/atomos-app-handler.desktop
    check_grep "Exec=/usr/libexec/atomos-app-handler --start" /target/etc/xdg/autostart/atomos-app-handler.desktop
fi

if [ "\$FAIL" -ne 0 ]; then
    echo "ERROR: build-fairphone4-v2 final verification failed (see above)." >&2
    exit 1
fi
echo "build-fairphone4-v2: final verification OK"
VERIFY_BODY
}

atomos_verify_rootfs() {
    echo "=== build-fairphone4-v2: final verification ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -e BUILD_OVERVIEW_CHAT_UI="$BUILD_OVERVIEW_CHAT_UI" \
        -e BUILD_HOME_BG="$BUILD_HOME_BG" \
        -e BUILD_APP_HANDLER="${BUILD_APP_HANDLER:-1}" \
        -e ATOMOS_FP4V2_DEBUG_NO_GREETD="${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_verify_container_body)"
}

_atomos_prepack_container_body() {
    cat <<'PREPACK_BODY'
FAIL=0
echo "pre-pack: greetd row in /etc/passwd:"
if grep "^greetd:" /target/etc/passwd; then :
else echo "  FAIL: greetd not found in /target/etc/passwd" >&2; FAIL=1; fi

echo "pre-pack: greetd row in /etc/group:"
if grep "^greetd:" /target/etc/group; then :
else echo "  FAIL: greetd group not found in /target/etc/group" >&2; FAIL=1; fi

echo "pre-pack: greetd / seatd / elogind in any runlevel:"
# v2 puts seatd + elogind in BOOT runlevel (sequential before default)
# so SSH/USB networking come up regardless of greetd's status. greetd
# may be in default OR removed (DEBUG_NO_GREETD=1). Check across both.
for svc in seatd elogind; do
    if [ -L "/target/etc/runlevels/boot/$svc" ]; then
        echo "  ok   $svc in BOOT -> $(readlink "/target/etc/runlevels/boot/$svc")"
    elif [ -L "/target/etc/runlevels/default/$svc" ]; then
        echo "  ok   $svc in DEFAULT -> $(readlink "/target/etc/runlevels/default/$svc")"
    else
        echo "  FAIL $svc missing from boot AND default runlevels" >&2
        FAIL=1
    fi
done
if [ "${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" = "1" ]; then
    if [ ! -L /target/etc/runlevels/default/greetd ] && [ ! -e /target/etc/runlevels/default/greetd ]; then
        echo "  ok   greetd intentionally NOT in default runlevel (DEBUG_NO_GREETD=1)"
    else
        echo "  FAIL DEBUG_NO_GREETD=1 set but greetd still in default" >&2
        FAIL=1
    fi
else
    if [ -L /target/etc/runlevels/default/greetd ]; then
        echo "  ok   greetd in DEFAULT -> $(readlink /target/etc/runlevels/default/greetd)"
    else
        echo "  FAIL greetd missing from default runlevel" >&2
        FAIL=1
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    echo "FATAL: pre-pack rootfs assertion failed; refusing to build a broken sparse image." >&2
    ls -la /target/etc/runlevels/default/ /target/etc/runlevels/boot/ >&2 || true
    exit 14
fi
echo "pre-pack: rootfs ready for packing."
PREPACK_BODY
}

atomos_assert_prepack_invariants() {
    echo "=== build-fairphone4-v2: pre-pack rootfs assertion ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target:ro" \
        -e ATOMOS_FP4V2_DEBUG_NO_GREETD="${ATOMOS_FP4V2_DEBUG_NO_GREETD:-0}" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_prepack_container_body)"
}
