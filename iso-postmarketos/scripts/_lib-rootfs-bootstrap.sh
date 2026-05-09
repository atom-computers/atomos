# shellcheck shell=bash
# scripts/_lib-rootfs-bootstrap.sh -- bootstrap an aarch64 Alpine + pmOS
# rootfs into a docker volume.
#
# Differences vs build-fairphone4.sh's inlined Step 1:
#   - The package manifests live in BASE_APK_PACKAGES / PMOS_APK_PACKAGES
#     arrays defined here (single source of truth).
#   - After the second-pass apk install we GREP THE LOG for
#     `WARNING: failed to execute pre-install` and treat any matches as
#     fatal (with the package name printed). Only the
#     `postmarketos-mkinitfs-*.trigger` family is allow-listed.
#     This is the diagnostic that names the failure mode behind
#     `ERROR: user.greetd failed to start` instead of silently moving on.
#
# Required globals at call time:
#   ENGINE ALPINE_IMAGE ROOTFS_VOLUME REPOSITORIES_FILE PMOS_KEY_HOST
#   PMOS_EXTRA_PACKAGES (optional CSV) PMOS_PARITY_PACKAGE_CANDIDATES (optional CSV)
#
# Side effects: creates and populates the named docker volume
# $ROOTFS_VOLUME with an aarch64 rootfs ready for the configuration
# stage.

# Base Alpine + GNOME + Phosh package set (no postmarketOS-only packages).
# Order is informative; merging with PMOS_APK_PACKAGES below preserves it.
atomos_bootstrap_base_packages() {
    BASE_APK_PACKAGES=(
        # Alpine base + OpenRC plumbing.
        alpine-base
        busybox-openrc
        openrc
        dbus
        dbus-openrc
        bash
        shadow
        util-linux
        util-linux-openrc
        # losetup is its own apk on Alpine edge; pmOS mkinitfs hooks
        # reference /usr/sbin/losetup which we symlink in step 1.5.
        losetup
        util-linux-misc
        # boot-deploy needs GNU coreutils (df --output=avail) and GNU
        # bc (multi-character variable names); busybox versions reject
        # both. Listed explicitly so the bootstrap manifest is
        # self-documenting.
        coreutils
        bc
        boot-deploy
        e2fsprogs
        dosfstools
        openssh
        openssh-server-pam
        sudo
        doas
        haveged
        haveged-openrc
        chrony
        chrony-openrc
        nftables
        nftables-openrc
        eudev
        eudev-openrc
        elogind
        elogind-openrc
        sleep-inhibitor
        sleep-inhibitor-openrc
        openrc-settingsd
        openrc-settingsd-openrc
        polkit-elogind
        seatd
        seatd-openrc
        zram-init
        zram-init-openrc
        networkmanager
        networkmanager-openrc
        modemmanager
        modemmanager-openrc
        wpa_supplicant
        wpa_supplicant-openrc
        bluez
        bluez-openrc
        pipewire
        pipewire-pulse
        wireplumber
        dconf
        # GNOME / portals / phosh runtime.
        gnome-session
        gnome-settings-daemon
        gnome-control-center
        gnome-shell-schemas
        gnome-bluetooth
        gnome-keyring
        xwayland
        adwaita-icon-theme
        xdg-desktop-portal-gtk
        xdg-desktop-portal-wlr
        xdg-desktop-portal-phosh
        xdg-user-dirs
        xdg-user-dirs-gtk
        udiskie
        dnsmasq
        gcr-ssh-agent
        glycin-loaders-all
        glycin-thumbnailer
        gnome-backgrounds
        gst-thumbnailers
        iio-sensor-proxy
        iio-sensor-proxy-openrc
        power-profiles-daemon
        apk-polkit-rs-openrc
        # Phosh stack. We carry the `phosh` apk so dependents resolve;
        # the heavy build container reinstalls phosh from
        # rust/phosh/phosh under DESTDIR=/target on top of it (vendor
        # phosh is ON by default in v2 -- mirrors build-qemu).
        phoc
        phoc-schemas
        phosh
        phosh-schemas
        phosh-mobile-settings
        phosh-wallpapers
        feedbackd
        squeekboard
        simdutf
        greetd
        greetd-openrc
        greetd-phrog
        # AtomOS overlay runtime libs.
        webkit2gtk-6.0
        gtk4-layer-shell
        # On-device dev tooling.
        build-base
        binutils
        gdb
        cargo
        rust
        pkgconf
        ripgrep
        glib-dev
        gdk-pixbuf-dev
        pango-dev
        cairo-dev
        gtk4.0-dev
        libadwaita-dev
        gtk4-layer-shell-dev
        graphene-dev
        gsettings-desktop-schemas
        # postmarketos-base-ui-gnome _pmb_recommends app set.
        decibels
        g4music
        gnome-calculator
        gnome-calendar
        gnome-clocks
        gnome-console
        gnome-contacts
        gnome-maps
        gnome-software
        gnome-software-plugin-apk2
        gnome-text-editor
        gnome-user-share
        gnome-weather
        gvfs-full
        nautilus
        papers
        showtime
        snapshot
        firefox-esr
        flatpak
        fprintd
        loupe
    )
    export BASE_APK_PACKAGES
}

# FP4-essential packages only (matches build-qemu's "vanilla Alpine + only
# what the device needs" pattern). Anything not strictly required for the
# Fairphone 4 to boot into our custom phosh stack stays out -- in
# particular the postmarketOS metapackages
#   postmarketos-base-ui / -ui-gnome / -ui-gnome-mobile
#   postmarketos-ui-phosh
# are deliberately NOT pinned. Their post-install scripts run via apk
# under qemu-user emulation against /target and have historically been
# the source of subtle race / lockfile bugs that produce
# "* ERROR: user.greetd failed to start" boot loops on the FP4. Their
# config drops (gschema overrides, /etc/conf.d/greetd, etc.) are written
# directly by _lib-rootfs-init.sh from pmaports source files instead --
# same approach build-qemu.sh uses (see lines 553-688 over there).
#
# device-fairphone-fp4 STILL transitively pulls postmarketos-base (it is
# a hard depends= entry in the device APKBUILD), and postmarketos-base's
# openrc subpackage in turn pulls openrc-user-pam (the /etc/init.d/user
# template). That template is harmless on its own -- it only does
# anything when symlinked as user.<name>, which nothing in our pipeline
# does. _lib-greetd-guarantee-body.sh proactively scrubs any stray
# user.* runlevel links as belt-and-braces.
atomos_bootstrap_pmos_packages() {
    PMOS_APK_PACKAGES=(
        # FP4 hardware: kernel (linux-postmarketos-qcom-sm6350), firmware-*,
        # hexagonrpcd, make-dynpart-mappings, mkbootimg, soc-qcom*, plus
        # postmarketos-base (transitive). All come from this one dep.
        device-fairphone-fp4
        # boot.img assembly: pmOS uses the osm0sis fork of mkbootimg for
        # the FP4-specific header layout (see deviceinfo offsets).
        mkbootimg-osm0sis
        # FP4 boots via the dynamic-partition mapper (super partition
        # contains system, vendor, etc.) -- this provides the mapper.
        make-dynpart-mappings
        # FP4 needs the pmOS mkinitfs (its boot-deploy hook is what
        # produces the boot.img after kernel install) AND the pmOS
        # initramfs init scripts (find_root_partition matches by
        # filesystem label "pmOS_root" which our packer step writes).
        postmarketos-mkinitfs
        postmarketos-initramfs
        # img2simg for sparse rootfs image conversion.
        android-tools
        # USB networking (CRITICAL for headless debug on FP4 -- without
        # it the only way to reach the device when the GUI is down is
        # serial UART, which most users do not have hooked up). The
        # default-profile-developer subpackage is what tells usb-moded
        # to bring up usb0 with 172.16.42.1 + unudhcpd at boot.
        # Without pmbootstrap nothing selects this subpackage
        # automatically (it is _pmb_select-driven), so we pin it.
        usb-moded
        usb-moded-openrc
        postmarketos-usb-moded
        postmarketos-usb-moded-openrc
        postmarketos-usb-moded-default-profile-developer
        unudhcpd
    )
    export PMOS_APK_PACKAGES
}

# Build the effective package manifest (a single space-separated string
# in PACKAGE_MANIFEST). Merge order: base -> pmos -> profile -> parity,
# de-duplicating while preserving first-seen order. Honors a small
# replacements map for legacy names that creep in from older configs.
atomos_bootstrap_build_manifest() {
    local profile_csv="${PMOS_EXTRA_PACKAGES:-}"
    local parity_csv="${PMOS_PARITY_PACKAGE_CANDIDATES:-}"
    PACKAGE_MANIFEST="$(
        python3 - "$profile_csv" "$parity_csv" "${BASE_APK_PACKAGES[*]}" "${PMOS_APK_PACKAGES[*]}" <<'PY'
import sys

profile = [p.strip() for p in sys.argv[1].split(",") if p.strip()]
parity  = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
base    = [p.strip() for p in sys.argv[3].split() if p.strip()]
pmos    = [p.strip() for p in sys.argv[4].split() if p.strip()]

replacements = {
    "webkit6.0-gtk4-dev": "webkit2gtk-6.0-dev",
}
ordered = []
for group in (base, pmos, profile, parity):
    for p in group:
        p = replacements.get(p, p)
        if not p:
            continue
        if p not in ordered:
            ordered.append(p)
print(" ".join(ordered))
PY
    )"
    export PACKAGE_MANIFEST
    echo "Effective APK package set:"
    echo "  $PACKAGE_MANIFEST"
}

# The container body. We define it as a function-emitted string rather
# than a global because it interpolates ${BASE_APK_PACKAGES[*]} and
# ${PMOS_APK_PACKAGES[*]} at construction time (those arrays come from
# the orchestrator and survive longer than a heredoc would).
_atomos_bootstrap_container_body() {
    cat <<BOOTSTRAP_BODY
mkdir -p /target/etc/apk/keys
cp -r /etc/apk/keys/. /target/etc/apk/keys/
# Trust the postmarketOS signing key in BOTH the host apk DB (so
# apk --root /target add can verify pmOS index signatures during
# bootstrap) AND in the target rootfs (so on-device apk continues
# to trust the same mirror).
cp /tmp/pmos.rsa.pub /etc/apk/keys/build.postmarketos.org.rsa.pub
cp /tmp/pmos.rsa.pub /target/etc/apk/keys/build.postmarketos.org.rsa.pub
cp /tmp/repositories /target/etc/apk/repositories
cp /tmp/repositories /etc/apk/repositories
apk update >/dev/null

set +e
apk --root /target \\
    --initdb \\
    --keys-dir /target/etc/apk/keys \\
    --repositories-file /target/etc/apk/repositories \\
    --update-cache \\
    --no-interactive \\
    add ${PACKAGE_MANIFEST} >/tmp/apk-manifest.log 2>&1
rc_manifest=\$?
set -e
cat /tmp/apk-manifest.log
if [ "\$rc_manifest" -ne 0 ]; then
    echo "WARN: full manifest install returned non-zero (\$rc_manifest); retrying base+pmOS set..." >&2
fi

# Retry pass with just the BASE + PMOS sets so a missing optional
# package (parity/profile extra) doesn't sink the whole bootstrap.
set +e
apk --root /target \\
    --keys-dir /target/etc/apk/keys \\
    --repositories-file /target/etc/apk/repositories \\
    --no-interactive \\
    add ${BASE_APK_PACKAGES[*]} ${PMOS_APK_PACKAGES[*]} >/tmp/apk-base.log 2>&1
rc=\$?
set -e
cat /tmp/apk-base.log

# --- pre-install / post-install warning audit (NEW in v2) -----------
# This is the diagnostic that exposes the root cause behind
# "ERROR: user.greetd failed to start". When apk runs a package's
# pre-install script via QEMU user-mode emulation under macOS docker,
# busybox's lckpwdf() against /target/etc/.pwd.lock can return EAGAIN,
# leaving adduser/addgroup as silent no-ops. Apk reports this as
# WARNING (not ERROR) and exits 0, so the build appears successful
# while greetd, seatd, polkitd etc. land WITHOUT their system users.
# We surface every such warning here and refuse to proceed unless the
# only ones are the known-recoverable mkinitfs trigger.
preinstall_warnings=\$(
    grep -E 'WARNING:.*(failed to execute (pre-install|post-install|pre-upgrade|post-upgrade)|script .* failed)' \\
         /tmp/apk-manifest.log /tmp/apk-base.log 2>/dev/null \\
    | grep -Ev 'postmarketos-mkinitfs-[^ ]+\\.trigger:' \\
    || true
)
if [ -n "\$preinstall_warnings" ]; then
    echo "" >&2
    echo "FATAL: apk reported pre/post-install script warnings during bootstrap." >&2
    echo "       This is the root cause behind 'ERROR: user.greetd failed to start' boot loops:" >&2
    echo "       a package's user-creation script silently no-op'd under qemu-user emulation." >&2
    echo "       The build can be retried; if the warning persists, check the docker engine" >&2
    echo "       (colima/orbstack/docker desktop) for binfmt-misc and bind-mount issues." >&2
    printf '%s\\n' "\$preinstall_warnings" | sed 's/^/  WARN: /' >&2
    exit 20
fi

if [ "\$rc" -ne 0 ]; then
    # apk returns non-zero when ANY post-install or trigger script
    # fails. The postmarketos-mkinitfs trigger commonly fails on first
    # bootstrap (losetup path mismatch); we fix that in the mkinitfs
    # fixup step. Treat ONLY that trigger as recoverable.
    non_trigger_errors=\$(
        grep -E '^ERROR:' /tmp/apk-base.log \\
        | grep -Ev 'apk/exec/postmarketos-mkinitfs-[^ ]+\\.trigger:' \\
        || true
    )

    # --- Recovery branch: chrony-common overwrite conflict ----------------
    # Mirror of build-image.sh d6405345 run_pmb_install_with_recovery.
    # postmarketos-base-ui sometimes ships a chrony.conf that conflicts
    # with chrony-common's chrony.conf, producing:
    #   chrony-common-X: trying to overwrite etc/chrony/chrony.conf owned by postmarketos-base-ui
    # Fix: install chrony with --force-overwrite, then continue.
    if echo "\$non_trigger_errors" | grep -q 'chrony-common.*trying to overwrite'; then
        echo "NOTE: detected chrony-common overwrite conflict; applying --force-overwrite recovery..." >&2
        set +e
        apk --root /target \\
            --keys-dir /target/etc/apk/keys \\
            --repositories-file /target/etc/apk/repositories \\
            --no-interactive \\
            --force-overwrite \\
            add chrony-common chrony >/tmp/apk-chrony-fix.log 2>&1
        chrony_rc=\$?
        set -e
        cat /tmp/apk-chrony-fix.log
        if [ "\$chrony_rc" -ne 0 ]; then
            echo "WARN: chrony --force-overwrite recovery exited \$chrony_rc; continuing." >&2
        fi
        # Re-evaluate non-trigger errors AFTER the recovery
        non_trigger_errors=\$(
            grep -E '^ERROR:' /tmp/apk-base.log /tmp/apk-chrony-fix.log 2>/dev/null \\
            | grep -Ev 'apk/exec/postmarketos-mkinitfs-[^ ]+\\.trigger:' \\
            | grep -v 'chrony-common.*trying to overwrite' \\
            || true
        )
    fi

    if [ -n "\$non_trigger_errors" ]; then
        echo "ERROR: base+pmOS package install failed (\$rc) with non-trigger errors:" >&2
        printf '%s\\n' "\$non_trigger_errors" >&2
        exit "\$rc"
    fi
    echo "NOTE: apk exited \$rc but only recoverable trigger/overwrite errors were reported; will regenerate initramfs in post-bootstrap fixup." >&2
fi

# --- additional apk WARN audit (broader patterns) ----------------------
# pre/post-install warnings are caught above. Now catch the OTHER
# silent-drop patterns:
#   "WARNING: <pkg>: package mentioned in index not found"
#   "WARNING: unable to satisfy <pkg>"
#   "ERROR: unable to select packages:" (followed by name + reason)
# These produce build "successes" with whole packages missing, which is
# exactly how device-fairphone-fp4's transitive firmware-* deps can
# silently fail to install -> no /lib/firmware/qcom/a630_sqe.fw on the
# device -> GPU never inits -> no display -> greetd stuck -> boot loop.
silent_drop_warnings=\$(
    grep -E '^WARNING:.*(package mentioned in index not found|unable to satisfy)' \\
         /tmp/apk-manifest.log /tmp/apk-base.log 2>/dev/null \\
    || true
)
if [ -n "\$silent_drop_warnings" ]; then
    echo "" >&2
    echo "FATAL: apk reported silent-drop warnings (packages not installed despite no error)." >&2
    printf '%s\\n' "\$silent_drop_warnings" | sed 's/^/  WARN: /' >&2
    exit 21
fi

# --- firmware safety net: forced re-extraction of FP4 firmware -------
# device-fairphone-fp4 transitively depends on these, but we have seen
# cases where apk reports the device package as installed yet the
# firmware-* deps did not actually land on disk. Force RE-EXTRACTION
# (not just plain add; apk treats already-installed packages as no-ops
# on plain add). Two-step:
#   1. apk del to remove the package + its files
#   2. apk add to install fresh, re-extracting from the .apk
# We use apk fix --reinstall if available (cleaner), falling back to
# del+add. After all that we check the actual filesystem -- the file
# either exists or it doesn't, regardless of what apk's rc says.
#
# rc-handling: apk's rc=1 here is almost always the
# postmarketos-mkinitfs trigger (losetup path mismatch -- recoverable,
# fixed in the post-bootstrap mkinitfs fixup). Apply the same filter
# the main install uses: only fail on non-trigger ERROR lines.
echo "=== bootstrap: explicit firmware re-extraction (FP4 safety net) ==="
fp4_fw_pkgs="
    firmware-qcom-adreno-a630-sqe
    firmware-fairphone-fp4-adreno
    firmware-fairphone-fp4-adsp
    firmware-fairphone-fp4-cdsp
    firmware-fairphone-fp4-modem
    firmware-fairphone-fp4-wlan
    firmware-fairphone-fp4-bluetooth
    firmware-fairphone-fp4-ipa
    firmware-fairphone-fp4-hexagonfs
    firmware-fairphone-fp4-audio
"
set +e
# Try apk fix --reinstall first (apk-tools 3.x supports it).
apk --root /target \\
    --keys-dir /target/etc/apk/keys \\
    --repositories-file /target/etc/apk/repositories \\
    --no-interactive \\
    --force-overwrite \\
    fix --reinstall \$fp4_fw_pkgs >/tmp/apk-firmware-fix.log 2>&1
fix_rc=\$?
set -e
cat /tmp/apk-firmware-fix.log
if [ "\$fix_rc" -ne 0 ]; then
    # Filter mkinitfs-trigger noise -- the same way the main install does.
    fw_real_errs=\$(
        grep -E '^ERROR:' /tmp/apk-firmware-fix.log \\
        | grep -Ev 'apk/exec/postmarketos-mkinitfs-[^ ]+\\.trigger:' \\
        || true
    )
    if [ -n "\$fw_real_errs" ]; then
        echo "FATAL: firmware re-extraction reported NON-trigger errors:" >&2
        printf '%s\\n' "\$fw_real_errs" >&2
        # Fall back to del+add only if the only error is a real one --
        # if it's the mkinitfs trigger, the files are extracted fine.
        echo "Trying fallback: apk del + apk add ..." >&2
        set +e
        apk --root /target --no-interactive del \$fp4_fw_pkgs >/tmp/apk-firmware-del.log 2>&1
        apk --root /target \\
            --keys-dir /target/etc/apk/keys \\
            --repositories-file /target/etc/apk/repositories \\
            --no-interactive \\
            --force-overwrite \\
            add \$fp4_fw_pkgs >/tmp/apk-firmware-readd.log 2>&1
        readd_rc=\$?
        set -e
        cat /tmp/apk-firmware-del.log /tmp/apk-firmware-readd.log
        # Recheck real errors after the fallback.
        fw_real_errs=\$(
            grep -E '^ERROR:' /tmp/apk-firmware-readd.log \\
            | grep -Ev 'apk/exec/postmarketos-mkinitfs-[^ ]+\\.trigger:' \\
            || true
        )
        if [ -n "\$fw_real_errs" ]; then
            echo "FATAL: del+add fallback also produced non-trigger errors." >&2
            exit 22
        fi
    fi
    # If we got here, the rc was non-zero only because of the
    # mkinitfs trigger -- recoverable. Continue to the file check.
    echo "NOTE: firmware re-extraction rc=\$fix_rc, but only the postmarketos-mkinitfs trigger failed (recoverable in fixup step)."
fi

# AUTHORITATIVE CHECK: is the file on disk?
# This is what actually matters. apk's rc lies; the filesystem doesn't.
if [ -f /target/lib/firmware/qcom/a630_sqe.fw ]; then
    echo "  OK /lib/firmware/qcom/a630_sqe.fw present (size: \$(wc -c < /target/lib/firmware/qcom/a630_sqe.fw) bytes)"
else
    echo "FATAL: /lib/firmware/qcom/a630_sqe.fw missing AFTER forced re-extraction." >&2
    echo "       Diagnostic dump:" >&2
    echo "       --- apk info -e firmware-qcom-adreno-a630-sqe ---" >&2
    apk --root /target info -e firmware-qcom-adreno-a630-sqe >&2 || true
    echo "       --- apk info -L firmware-qcom-adreno-a630-sqe (files apk thinks it shipped) ---" >&2
    apk --root /target info -L firmware-qcom-adreno-a630-sqe 2>&1 | head -30 >&2 || true
    echo "       --- /target/lib/firmware/qcom listing ---" >&2
    ls -la /target/lib/firmware/qcom/ 2>&1 | head -30 >&2 || true
    echo "       --- /target/lib/firmware top-level ---" >&2
    ls -la /target/lib/firmware/ 2>&1 | head -30 >&2 || true
    echo "       --- find a630_sqe anywhere ---" >&2
    find /target -name 'a630_sqe*' 2>/dev/null | head -10 >&2 || true
    exit 23
fi

# Hard fail only when bootstrap produced an obviously unusable rootfs.
test -x /target/bin/sh
test -x /target/usr/sbin/sshd
test -x /target/usr/bin/mkbootimg
test -d /target/lib/modules
BOOTSTRAP_BODY
}

# --- minimal first phase (matches pmbootstrap pmb.chroot.init) ---------
# pmbootstrap installs ONLY {alpine-baselayout, apk-tools, busybox, musl-utils}
# in this phase so /etc/{passwd,group,shadow} exist for set_user(). We add
# `shadow` so we have `usermod` available too, and the pmOS signing key
# so the FULL phase can reach the pmOS mirror later.
#
# This is the critical pmbootstrap-parity fix: by creating the user
# (uid 10000) BETWEEN this minimal phase and the full apk install,
# every postmarketos-ui-*.post-install that does
#   default_user=$(getent passwd "10000" | cut -d: -f1)
#   usermod -aG <group> "$default_user"
# gets a real value for $default_user instead of silently no-op'ing
# (pmaports#820 -- documented in pmb/install/_install.py:1273).
_atomos_minimal_container_body() {
    cat <<'MINIMAL_BODY'
mkdir -p /target/etc/apk/keys
cp -r /etc/apk/keys/. /target/etc/apk/keys/
cp /tmp/pmos.rsa.pub /etc/apk/keys/build.postmarketos.org.rsa.pub
cp /tmp/pmos.rsa.pub /target/etc/apk/keys/build.postmarketos.org.rsa.pub
cp /tmp/repositories /target/etc/apk/repositories
cp /tmp/repositories /etc/apk/repositories
apk update >/dev/null

# --- usr-merge symlinks (CRITICAL for FP4 firmware loading) ----------
# pmaports.cfg declares supported_usr_merge=True. pmbootstrap creates
# /bin /sbin /lib as SYMLINKS to /usr/bin /usr/sbin /usr/lib BEFORE
# any package install (pmb/chroot/init.py:125-135). Without this, the
# packaged binaries which abuild has installed under /usr/lib/firmware/...
# (because abuild applies usr-merge at PACKAGE BUILD time) end up at
#   /usr/lib/firmware/qcom/a630_sqe.fw
# but the kernel's firmware loader looks at the LEGACY path:
#   /lib/firmware/qcom/a630_sqe.fw
# Result: every firmware lookup silently fails. The Adreno GPU never
# initializes, msm DRM never exposes a wayland output, phoc cannot
# spawn a session, greetd reports "failed to start" 60s later.
#
# We support two scenarios:
#   1. FRESH rootfs (most common): just create the symlinks before any
#      apk install.
#   2. CACHED rootfs (KEEP=1) from a previous build that ran BEFORE the
#      usr-merge fix landed: /lib already exists as a real directory
#      with content. Migrate it: rsync /lib/* into /usr/lib/, then
#      remove /lib and create the symlink. Same for /bin and /sbin.
#      Idempotent (no-op when already merged).
merge_one() {
    src=$1     # bin | sbin | lib
    if [ -L "/target/$src" ]; then
        # already merged
        return 0
    fi
    if [ ! -e "/target/$src" ]; then
        # fresh: just symlink
        ln -s "usr/$src" "/target/$src"
        return 0
    fi
    # /target/$src exists as a real dir. Migrate its content to
    # /target/usr/$src/ then replace with a symlink.
    if [ -d "/target/$src" ]; then
        echo "minimal: migrating /target/$src -> /target/usr/$src (cached non-merged rootfs)"
        mkdir -p "/target/usr/$src"
        # rsync would be cleaner but may not be in the alpine container.
        # cp -aT preserves symlinks, perms, timestamps.
        cp -an "/target/$src/." "/target/usr/$src/"
        rm -rf "/target/$src"
        ln -s "usr/$src" "/target/$src"
        echo "minimal: migrated /target/$src; now points to usr/$src"
    else
        echo "minimal: ERROR /target/$src is neither symlink nor directory" >&2
        ls -la "/target/$src" >&2 || true
        return 1
    fi
}

mkdir -p /target/usr/bin /target/usr/sbin /target/usr/lib
merge_one bin
merge_one sbin
merge_one lib
echo "minimal: usr-merge symlinks:"
ls -la /target/bin /target/sbin /target/lib | sed 's/^/  /'

# Minimal package set: just enough to get a usable /etc/{passwd,group,shadow}
# and (later) `usermod`. We deliberately do NOT include alpine-base
# here because alpine-base depends on openrc, and installing openrc
# now (before our user is in /etc/passwd) would re-trigger the same
# qemu-user lockfile race we are working around.
apk --root /target \
    --initdb \
    --keys-dir /target/etc/apk/keys \
    --repositories-file /target/etc/apk/repositories \
    --update-cache \
    --no-interactive \
    add alpine-baselayout apk-tools busybox musl-utils shadow

# Sanity: /etc/passwd must exist for the user-creation phase to write to.
test -f /target/etc/passwd
test -f /target/etc/group
test -f /target/etc/shadow
echo "minimal: /etc/passwd has $(wc -l < /target/etc/passwd) entries"

# Verify usr-merge survived alpine-baselayout install. If /lib is a
# real directory at this point we have a broken cached rootfs (most
# likely from a build that ran BEFORE we added the usr-merge
# symlinks). Hard-fail with a clear remediation so the user does not
# silently flash an image where every firmware lookup fails.
merge_fail=0
for d in bin sbin lib; do
    if [ -L "/target/$d" ]; then
        echo "minimal: ok /target/$d -> $(readlink "/target/$d")"
    else
        echo "minimal: FAIL /target/$d is NOT a symlink (usr-merge broken)" >&2
        ls -la "/target/$d" 2>&1 | head -5 >&2 || true
        merge_fail=1
    fi
done
if [ "$merge_fail" -ne 0 ]; then
    echo "" >&2
    echo "FATAL: rootfs is not usr-merged. Packaged firmware/libraries will land at" >&2
    echo "       /usr/lib/firmware/... where the kernel cannot find them at /lib/firmware/..." >&2
    echo "       This usually means a CACHED rootfs from before usr-merge was added." >&2
    echo "       Remediation:" >&2
    echo "         unset ATOMOS_FP4V2_KEEP_ROOTFS_VOLUME" >&2
    echo "         make build-fairphone4" >&2
    exit 24
fi
MINIMAL_BODY
}

# Public: phase 1 entry point.
atomos_bootstrap_minimal() {
    echo "=== build-fairphone4-v2: bootstrap minimal Alpine chroot ==="
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$REPOSITORIES_FILE:/tmp/repositories:ro" \
        -v "$PMOS_KEY_HOST:/tmp/pmos.rsa.pub:ro" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_minimal_container_body)"
}

# Public: phase 3 entry point. Same as the OLD atomos_bootstrap_rootfs
# (build manifest, apk install, audit warnings) but assumes the minimal
# chroot + user 10000 already exist.
atomos_bootstrap_full() {
    echo "=== build-fairphone4-v2: full apk install (user 10000 should already exist) ==="
    atomos_bootstrap_base_packages
    atomos_bootstrap_pmos_packages
    atomos_bootstrap_build_manifest

    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$REPOSITORIES_FILE:/tmp/repositories:ro" \
        -v "$PMOS_KEY_HOST:/tmp/pmos.rsa.pub:ro" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_bootstrap_container_body)"
}

# Backwards-compat wrapper: callers that still want the one-shot can use this.
# v2 orchestrator switches to bootstrap_minimal -> ensure_users -> bootstrap_full.
atomos_bootstrap_rootfs() {
    atomos_bootstrap_minimal
    # Caller is responsible for invoking atomos_ensure_system_users between
    # minimal and full to get the pmbootstrap ordering. If they just call
    # atomos_bootstrap_rootfs we fall back to legacy single-shot install
    # (which silently no-ops user-touching post-installs).
    echo "WARN: atomos_bootstrap_rootfs called as one-shot -- post-installs will not see user 10000." >&2
    atomos_bootstrap_full
}
