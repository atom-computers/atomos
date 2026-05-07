#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: build-qemu.sh [profile-env] [--without-home-bg]

Builds a bootable ARM64 QEMU image from Alpine Linux without pmbootstrap.

Options:
  --without-home-bg, --skip-home-bg
      Skip building/installing atomos-home-bg in the QEMU image.

Optional local Meson trees under iso-postmarketos/vendor/: vendor/phoc,
vendor/phosh-mobile-settings, vendor/phosh-wallpapers. Each is compiled into
the rootfs when that directory contains meson.build. Phoc and
phosh-mobile-settings ship Meson subprojects in-tree (no .wrap; see each
README "AtomOS vendored subprojects").

Environment (Meson incremental cache):
  (default)                           A named docker volume
                                      (atomos-qemu-meson-cache-<profile>) is
                                      created and reused across runs. The
                                      cache lives inside the engine VM so it
                                      is unaffected by macOS bind-mount
                                      EPERM quirks (colima#911) that break
                                      `ar` / `ld` when building phosh.
                                      Subdirs: gmobile, phosh, phoc,
                                      phosh-mobile-settings, phosh-wallpapers.
                                      Reuse across runs lets ninja do
                                      incremental rebuilds instead of full
                                      configure + compile (phosh + embedded
                                      wlroots is the dominant cost).
  ATOMOS_QEMU_MESON_CACHE_HOST_DIR=<dir>
                                      Opt out of the named volume and
                                      bind-mount this host directory at
                                      /cache instead. Recommended only on
                                      Linux hosts (or for CI that needs to
                                      upload the cache as an artifact).
                                      ATOMOS_QEMU_MESON_CACHE_DIR is the
                                      legacy alias and is still honored.
  ATOMOS_QEMU_MESON_CACHE_CLEAN=1     Wipe the Meson cache before building
                                      (works for both volume and host dir).
                                      Use after Alpine image upgrades or when
                                      seeing stale-link errors.
  ATOMOS_CCACHE_MAXSIZE=<size>        Bound the on-disk ccache size (default
                                      5G). Stored under <cache>/.ccache.
                                      Wrapping gcc via ccache makes ninja
                                      "rebuilds" caused by reinstalled header
                                      packages resolve as cache hits.
  ATOMOS_QEMU_ENABLE_NFTABLES=1       Enable nftables service in default
                                      runlevel. Default is 0 (disabled) for
                                      QEMU images so hostfwd SSH on :2222 is
                                      reachable without manual service stop.
EOF
}

PROFILE_ENV=""
WITHOUT_HOME_BG_FLAG=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --without-home-bg|--skip-home-bg)
            WITHOUT_HOME_BG_FLAG=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            if [ -n "$PROFILE_ENV" ]; then
                echo "ERROR: profile env provided more than once: $1" >&2
                usage
                exit 1
            fi
            PROFILE_ENV="$1"
            ;;
    esac
    shift
done
PROFILE_ENV="${PROFILE_ENV:-config/arm64-virt.env}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "ERROR: missing profile env: $PROFILE_ENV" >&2
    exit 2
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

if [ -z "${PROFILE_NAME:-}" ]; then
    echo "ERROR: PROFILE_NAME missing in $PROFILE_ENV_SOURCE" >&2
    exit 2
fi

if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: build-qemu.sh requires Linux host." >&2
    exit 2
fi

find_container_engine() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        echo "docker"
    elif command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
        echo "podman"
    else
        echo ""
    fi
}

require_tools() {
    local missing=0 t
    for t in dd rsync python3; do
        if ! command -v "$t" >/dev/null 2>&1; then
            echo "ERROR: required command missing: $t" >&2
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || exit 2
}

require_tools
ENGINE="$(find_container_engine)"
if [ -z "$ENGINE" ]; then
    echo "ERROR: docker or podman is required for Alpine ARM64 bootstrap/build." >&2
    exit 2
fi

BUILD_DIR="$ROOT_DIR/build"
EXPORT_DIR="$BUILD_DIR/host-export-${PROFILE_NAME}"
WORK_DIR="$BUILD_DIR/qemu-alpine-${PROFILE_NAME}"
IMAGE_PATH="$EXPORT_DIR/${PROFILE_NAME}.img"
IMAGE_SIZE="${PMOS_QEMU_IMAGE_SIZE:-8G}"
ALPINE_IMAGE="${ATOMOS_QEMU_ALPINE_CONTAINER_IMAGE:-alpine:edge}"
INSTALL_PASSWORD="${PMOS_INSTALL_PASSWORD:-147147}"
ATOMOS_QEMU_ENABLE_NFTABLES="${ATOMOS_QEMU_ENABLE_NFTABLES:-0}"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
REPO_TOP="$(cd "$ROOT_DIR/.." && pwd)"
VENDOR_DIR="$ROOT_DIR/vendor"
# postmarketOS default session user (postmarketos-ui-phosh post-install, pmb install).
PMOS_USER_UID="${PMOS_USER_UID:-10000}"
ROOTFS_VOLUME="atomos-qemu-rootfs-${PROFILE_NAME}"
REPOSITORIES_FILE="$WORK_DIR/etc_apk_repositories"
HOME_BG_MANIFEST="$ROOT_DIR/rust/atomos-home-bg/app-gtk/Cargo.toml"
BUILD_HOME_BG=1
if [ "$WITHOUT_HOME_BG_FLAG" = "1" ]; then
    BUILD_HOME_BG=0
    echo "build-qemu: --without-home-bg requested; home-bg disabled."
elif [ ! -f "$HOME_BG_MANIFEST" ]; then
    BUILD_HOME_BG=0
    echo "WARN: atomos-home-bg manifest missing; skipping home-bg build/install."
    echo "  missing: $HOME_BG_MANIFEST"
fi

mkdir -p "$EXPORT_DIR" "$WORK_DIR"
rm -f "$REPOSITORIES_FILE"

# Meson incremental cache. The heavy build container mounts /cache so subsequent
# runs reuse object files (phosh + embedded wlroots dominate compile time).
# `meson_cache_setup` (in build_container_script) only re-runs `meson setup`
# when args change or build.ninja is missing.
#
# Storage backend selection:
#   - DEFAULT: a NAMED docker volume (atomos-qemu-meson-cache-<profile>). The
#     cache lives entirely inside the engine VM. This is the only reliable
#     option on macOS Docker/Colima/OrbStack hosts: bind mounts of macOS-host
#     directories return EPERM at random under heavy small-file load (e.g. ar
#     opening ~150 .o files in one shot during phosh's libphosh-tool.a build),
#     surfacing as "ar: foo.o: Operation not permitted" / "ld: ... thin
#     archive member: Operation not permitted" — see colima#911. A named
#     volume sidesteps the macOS<->Linux file sharing layer entirely.
#   - OPT-IN HOST DIR: set ATOMOS_QEMU_MESON_CACHE_HOST_DIR=<path> to mount a
#     host directory instead. Useful on Linux hosts where bind mount is fast
#     and inspectability matters (e.g. CI artifact upload). Setting the legacy
#     ATOMOS_QEMU_MESON_CACHE_DIR=<path> is also honored for compatibility,
#     but the new var name is preferred because it makes the host-vs-volume
#     intent explicit at the call site.
MESON_CACHE_VOLUME="atomos-qemu-meson-cache-${PROFILE_NAME}"
MESON_CACHE_HOST_DIR="${ATOMOS_QEMU_MESON_CACHE_HOST_DIR:-${ATOMOS_QEMU_MESON_CACHE_DIR:-}}"
if [ -n "$MESON_CACHE_HOST_DIR" ]; then
    MESON_CACHE_MOUNT="$MESON_CACHE_HOST_DIR"
    MESON_CACHE_KIND="host directory: $MESON_CACHE_HOST_DIR"
    mkdir -p "$MESON_CACHE_HOST_DIR"
else
    MESON_CACHE_MOUNT="$MESON_CACHE_VOLUME"
    MESON_CACHE_KIND="docker volume: $MESON_CACHE_VOLUME"
    "$ENGINE" volume create "$MESON_CACHE_VOLUME" >/dev/null
fi

if [ "${ATOMOS_QEMU_MESON_CACHE_CLEAN:-0}" = "1" ]; then
    echo "build-qemu: ATOMOS_QEMU_MESON_CACHE_CLEAN=1 -> wiping cache ($MESON_CACHE_KIND)"
    # Wipe via the engine: docker-rootful writes cache files as root, which the
    # invoking user may not be able to remove directly. For named volumes we
    # destroy and recreate; for host dirs we rm -rf inside a container then
    # fall back to host rm.
    if [ -n "$MESON_CACHE_HOST_DIR" ] && [ -d "$MESON_CACHE_HOST_DIR" ]; then
        "$ENGINE" run --rm \
            -v "$MESON_CACHE_HOST_DIR:/cache" \
            "$ALPINE_IMAGE" /bin/sh -c 'rm -rf /cache/* /cache/.[!.]* 2>/dev/null || true' \
            >/dev/null 2>&1 || rm -rf "$MESON_CACHE_HOST_DIR"
        mkdir -p "$MESON_CACHE_HOST_DIR"
    elif [ -z "$MESON_CACHE_HOST_DIR" ]; then
        "$ENGINE" volume rm -f "$MESON_CACHE_VOLUME" >/dev/null 2>&1 || true
        "$ENGINE" volume create "$MESON_CACHE_VOLUME" >/dev/null
    fi
fi
echo "build-qemu: meson cache backend: $MESON_CACHE_KIND (ATOMOS_QEMU_MESON_CACHE_CLEAN=1 to wipe; ATOMOS_QEMU_MESON_CACHE_HOST_DIR=<path> for host bind mount)"

cleanup_volume() {
    # Note: the meson cache volume ($MESON_CACHE_VOLUME) is intentionally
    # *not* removed on exit so it persists across runs. Only the rootfs
    # volume (which is freshly built each run) gets cleaned up.
    "$ENGINE" volume rm -f "$ROOTFS_VOLUME" >/dev/null 2>&1 || true
}
trap cleanup_volume EXIT
cleanup_volume
"$ENGINE" volume create "$ROOTFS_VOLUME" >/dev/null

echo "=== build-qemu: creating disk image ($IMAGE_SIZE) ==="
rm -f "$IMAGE_PATH"
dd if=/dev/zero of="$IMAGE_PATH" bs=1 count=0 seek="$IMAGE_SIZE"

echo "=== build-qemu: bootstrap Alpine rootfs ==="
# Use Alpine edge exclusively - phoc/gmobile/phosh require edge versions
# Mixing 3.21 and edge causes library version mismatches
cat > "$REPOSITORIES_FILE" <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/edge/main
https://dl-cdn.alpinelinux.org/alpine/edge/community
https://dl-cdn.alpinelinux.org/alpine/edge/testing
EOF

BASE_APK_PACKAGES=(
    alpine-base
    linux-virt
    linux-firmware-none
    openssh
    openssh-server-pam
    sudo
    doas
    openrc
    # OpenRC scripts for busybox daemons (incl. syslog → /dev/log for logger(1)).
    busybox-openrc
    dbus
    dbus-openrc
    networkmanager
    networkmanager-openrc
    pipewire
    pipewire-pulse
    wireplumber
    dconf
    bash
    shadow
    util-linux
    util-linux-openrc
    e2fsprogs
    dosfstools
    # Phosh UI stack (phoc is the Wayland compositor phosh runs on)
    # gmobile is built from source (subprojects/gmobile) to match phosh/phoc versions
    phoc
    phoc-schemas
    phosh-schemas
    # greetd + phrog is the display manager combo used by postmarketOS for phosh
    greetd
    greetd-openrc
    greetd-phrog
    feedbackd
    # Phosh runtime dependencies (from postmarketos-ui-phosh + postmarketos-base-ui-gnome)
    gnome-session
    gnome-settings-daemon
    gnome-control-center
    gnome-shell-schemas
    gnome-bluetooth
    gnome-keyring
    xwayland
    adwaita-icon-theme
    mesa-dri-gallium
    # XDG portals (from postmarketos-ui-phosh)
    xdg-desktop-portal-gtk
    xdg-desktop-portal-wlr
    xdg-desktop-portal-phosh
    xdg-user-dirs
    # atomos-home-bg runtime dependencies.
    # These are ONLY compile deps in the build container; the rootfs needs the
    # *runtime* packages or the binary exits immediately with a missing-library
    # error. webkit2gtk-6.0 pulls gst-plugins-base + gstreamer transitively.
    webkit2gtk-6.0
    gtk4-layer-shell
    # OSK: pmaports postmarketos-ui-phosh default_osk uses phosh-osk-stub; on
    # Alpine that maps to stevia (alternative Phosh OSK) instead of squeekboard.
    stevia
    # simdutf: runtime dep of vte3-gtk4 on Alpine edge; some GNOME components
    # that transitively use vte (gnome-terminal, phosh app search) can crash or
    # fail to load symbols without it.
    simdutf
    # phosh-mobile-settings: phosh settings panel (parity with pmbootstrap path).
    phosh-mobile-settings
    # postmarketos-ui-phosh + postmarketos-base-ui-gnome (pmaports) parity on
    # vanilla Alpine: Bluetooth (init is linked below), udiskie, wallpapers,
    # DNS helper for tethering, SSH agent, glycin/gst thumbnailers, backgrounds,
    # sensor proxy, power profiles, GTK user-dirs, polkit openrc glue.
    bluez
    bluez-openrc
    udiskie
    phosh-wallpapers
    dnsmasq
    gcr-ssh-agent
    glycin-loaders-all
    glycin-thumbnailer
    gnome-backgrounds
    gst-thumbnailers
    iio-sensor-proxy
    iio-sensor-proxy-openrc
    power-profiles-daemon
    xdg-user-dirs-gtk
    apk-polkit-rs-openrc
    # Dev/debug tooling: mirrors arm64-virt.env PMOS_EXTRA_PACKAGES so the QEMU
    # image supports on-device `cargo build` and interactive debugging without
    # needing a separate cross-build cycle.
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
    # Seat/session management (required for Wayland compositors)
    elogind
    elogind-openrc
    sleep-inhibitor
    sleep-inhibitor-openrc
    openrc-settingsd
    openrc-settingsd-openrc
    polkit-elogind
    seatd
    seatd-openrc
    # Modem/network (from postmarketos-base-ui-gnome-openrc)
    modemmanager
    modemmanager-openrc
    # Device management
    eudev
    eudev-openrc
    # Services from postmarketos-base-ui-openrc
    haveged
    haveged-openrc
    chrony
    chrony-openrc
    # postmarketos-base-nftables-openrc.post-install
    nftables
    nftables-openrc
    # postmarketos-base-ui-wifi-wpa_supplicant (not iwd): wpa in default, iwd absent.
    wpa_supplicant
    wpa_supplicant-openrc
    # postmarketos-zram-swap analogue (Alpine)
    zram-init
    zram-init-openrc
    # postmarketos-base-ui-gnome _pmb_recommends (pmaports) — GNOME / core apps
    # on Alpine; rygel not in edge index; tuned-ppd covered by power-profiles-daemon.
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

# Mirror profile extras + helper script APK dependencies.
PROFILE_EXTRA_CSV="${PMOS_EXTRA_PACKAGES:-}"
HELPER_APK_CSV="python3,py3-pip,ca-certificates,git,build-base,libffi-dev,openssl-dev,bluez,bluez-deprecated,bluez-hcidump,rfkill,figlet,android-tools-adb,py3-cairo,py3-dbus,py3-gobject3,py3-serial,dbus-dev,libbluetooth-dev,bluez-dev,cmake,py3-numpy,pkgconf,linux-headers,curl,graphene-dev,gsettings-desktop-schemas,gcompat,libstdc++"
PARITY_CSV="${PMOS_PARITY_PACKAGE_CANDIDATES:-}"

PACKAGE_MANIFEST="$(
    python3 - "$PROFILE_EXTRA_CSV" "$HELPER_APK_CSV" "$PARITY_CSV" "${BASE_APK_PACKAGES[*]}" <<'PY'
import sys

profile = [p.strip() for p in sys.argv[1].split(",") if p.strip()]
helpers = [p.strip() for p in sys.argv[2].split(",") if p.strip()]
parity = [p.strip() for p in sys.argv[3].split(",") if p.strip()]
base = [p.strip() for p in sys.argv[4].split() if p.strip()]

replacements = {
    "libbluetooth-dev": "bluez-dev",
    "py3-serial": "py3-pyserial",
    "rfkill": "util-linux",
    "bluez-hcidump": "bluez-btmon",
    "webkit6.0-gtk4-dev": "webkit2gtk-6.0-dev",
}
drop = {""}

ordered = []
for group in (base, profile, helpers, parity):
    for p in group:
        p = replacements.get(p, p)
        if p in drop:
            continue
        if p not in ordered:
            ordered.append(p)
print(" ".join(ordered))
PY
)"

echo "Effective APK package set:"
echo "  $PACKAGE_MANIFEST"

"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
    -v "$REPOSITORIES_FILE:/tmp/repositories:ro" \
    "$ALPINE_IMAGE" /bin/sh -eu -c "
        mkdir -p /target/etc/apk/keys
        cp -r /etc/apk/keys/. /target/etc/apk/keys/
        cp /tmp/repositories /target/etc/apk/repositories
        set +e
        apk --root /target \
            --initdb \
            --keys-dir /target/etc/apk/keys \
            --repositories-file /target/etc/apk/repositories \
            --update-cache \
            --no-interactive \
            add $PACKAGE_MANIFEST >/tmp/apk-manifest.log 2>&1
        rc_manifest=\$?
        set -e
        cat /tmp/apk-manifest.log
        if [ \"\$rc_manifest\" -ne 0 ]; then
            echo \"WARN: manifest install returned non-zero (\$rc_manifest); continuing with base package pass.\" >&2
        fi
        # Keep build moving when optional parity/helper packages are unavailable.
        set +e
        apk --root /target \
            --keys-dir /target/etc/apk/keys \
            --repositories-file /target/etc/apk/repositories \
            --no-interactive \
            add ${BASE_APK_PACKAGES[*]} >/tmp/apk-base.log 2>&1
        rc=\$?
        set -e
        cat /tmp/apk-base.log
        if [ \"\$rc\" -ne 0 ]; then
            echo \"WARN: base package install returned non-zero (\$rc); continuing with rootfs sanity checks.\" >&2
        fi
        # Hard fail only when bootstrap produced an obviously unusable rootfs.
        test -x /target/bin/sh
        test -x /target/usr/sbin/sshd
        test -e /target/boot/vmlinuz-virt
        test -e /target/boot/initramfs-virt
    "

echo "=== build-qemu: base rootfs configuration ==="
"$ENGINE" run --rm --platform linux/arm64 \
    -e PROFILE_NAME="$PROFILE_NAME" \
    -e INSTALL_PASSWORD="$INSTALL_PASSWORD" \
    -e ATOMOS_QEMU_ENABLE_NFTABLES="$ATOMOS_QEMU_ENABLE_NFTABLES" \
    -e PMOS_USER_UID="${PMOS_USER_UID:-10000}" \
    -v "$ROOTFS_VOLUME:/target" \
    -v "$ROOT_DIR:/iso:ro" \
    "$ALPINE_IMAGE" /bin/sh -eu -c '
        mkdir -p /target/etc /target/boot /target/etc/network
        printf "%s\n" "$PROFILE_NAME" > /target/etc/hostname
        cat > /target/etc/fstab <<EOF
/dev/vda2 / ext4 defaults 0 1
/dev/vda1 /boot vfat defaults 0 2
EOF
        mkdir -p /target/etc/runlevels/sysinit /target/etc/runlevels/boot /target/etc/runlevels/default
        # Sysinit: device manager
        ln -sf /etc/init.d/udev /target/etc/runlevels/sysinit/udev || true
        ln -sf /etc/init.d/udev-trigger /target/etc/runlevels/sysinit/udev-trigger || true
        ln -sf /etc/init.d/udev-settle /target/etc/runlevels/sysinit/udev-settle || true
        # Boot level
        ln -sf /etc/init.d/hostname /target/etc/runlevels/boot/hostname || true
        ln -sf /etc/init.d/bootmisc /target/etc/runlevels/boot/bootmisc || true
        # busybox syslogd: creates /dev/log so logger(1) and autostart scripts work.
        if [ -f /target/etc/init.d/syslog ]; then
            ln -sf /etc/init.d/syslog /target/etc/runlevels/boot/syslog
        else
            echo "build-qemu: note: no /etc/init.d/syslog (logger will warn about /dev/log until syslog is available)" >&2
        fi
        ln -sf /etc/init.d/modules /target/etc/runlevels/boot/modules || true
        # Default runlevel services (from postmarketos-base-ui-openrc.post-install)
        ln -sf /etc/init.d/cgroups /target/etc/runlevels/default/cgroups || true
        ln -sf /etc/init.d/dbus /target/etc/runlevels/default/dbus || true
        ln -sf /etc/init.d/haveged /target/etc/runlevels/default/haveged || true
        ln -sf /etc/init.d/chronyd /target/etc/runlevels/default/chronyd || true
        if [ "${ATOMOS_QEMU_ENABLE_NFTABLES:-0}" = "1" ]; then
            ln -sf /etc/init.d/nftables /target/etc/runlevels/default/nftables || true
        else
            rm -f /target/etc/runlevels/default/nftables
        fi
        # postmarketos-base-ui-openrc.post-install also enables rfkill.
        ln -sf /etc/init.d/rfkill /target/etc/runlevels/default/rfkill || true
        # postmarketos-base-openrc.post-install
        ln -sf /etc/init.d/udev-postmount /target/etc/runlevels/default/udev-postmount || true
        # Default runlevel services (from postmarketos-base-ui-gnome-openrc.post-install)
        ln -sf /etc/init.d/bluetooth /target/etc/runlevels/default/bluetooth || true
        ln -sf /etc/init.d/iio-sensor-proxy /target/etc/runlevels/default/iio-sensor-proxy || true
        ln -sf /etc/init.d/apk-polkit-server /target/etc/runlevels/default/apk-polkit-server || true
        ln -sf /etc/init.d/elogind /target/etc/runlevels/default/elogind || true
        # postmarketos-base-ui-elogind.post-install + openrc-settingsd.post-install
        ln -sf /etc/init.d/sleep-inhibitor /target/etc/runlevels/default/sleep-inhibitor || true
        ln -sf /etc/init.d/openrc-settingsd /target/etc/runlevels/default/openrc-settingsd || true
        ln -sf /etc/init.d/modemmanager /target/etc/runlevels/default/modemmanager || true
        ln -sf /etc/init.d/networkmanager /target/etc/runlevels/default/networkmanager || true
        # postmarketos-base-ui-wifi-wpa_supplicant-openrc: wpa only (no iwd in default)
        ln -sf /etc/init.d/wpa_supplicant /target/etc/runlevels/default/wpa_supplicant || true
        # postmarketos-base-openrc.post-upgrade: zram-swap (Alpine zram-init)
        ln -sf /etc/init.d/zram-init /target/etc/runlevels/default/zram-init || true
        # Additional services
        ln -sf /etc/init.d/sshd /target/etc/runlevels/default/sshd || true
        ln -sf /etc/init.d/seatd /target/etc/runlevels/default/seatd || true
        ln -sf /etc/init.d/greetd /target/etc/runlevels/default/greetd || true

        mkdir -p /target/etc/conf.d

        # Ship pmaports Phosh + GNOME UI config when this checkout includes pmaports/
        # (otherwise fall back to the embedded gschema snippet).
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
        if [ -f "$PM/postmarketos-ui-phosh/greetd.confd" ]; then
            install -Dm644 "$PM/postmarketos-ui-phosh/greetd.confd" /target/etc/conf.d/greetd
        else
            cat > /target/etc/conf.d/greetd <<'GREETD_CONFD'
# Configuration for greetd
# Path to config file to use (phrog provides this)
cfgfile="/etc/phrog/greetd-config.toml"
GREETD_CONFD
        fi
        if [ -f "$PM/postmarketos-ui-phosh/01_postmarketos-ui-phosh.gschema.override" ]; then
            install -Dm644 "$PM/postmarketos-ui-phosh/01_postmarketos-ui-phosh.gschema.override" \
                /target/usr/share/glib-2.0/schemas/01_postmarketos-ui-phosh.gschema.override
        else
            {
                printf "[sm.puri.phosh]\n"
                printf "# disable filtering apps based on adaptive tag\n"
                printf "app-filter-mode=[]\n"
                printf "favorites=['"'"'org.gnome.Calls.desktop'"'"', '"'"'sm.puri.Chatty.desktop'"'"', '"'"'org.gnome.Contacts.desktop'"'"', '"'"'firefox-esr.desktop'"'"']\n"
                printf "\n"
                printf "[mobi.phosh.osk.Terminal]\n"
                printf "# Add arrow keys to the default\n"
                printf "shortcuts=['"'"'<ctrl>'"'"', '"'"'<alt>'"'"', '"'"'Left'"'"', '"'"'Up'"'"', '"'"'Down'"'"', '"'"'Right'"'"', '"'"'<ctrl>r'"'"', '"'"'Home'"'"', '"'"'End'"'"', '"'"'<ctrl>w'"'"', '"'"'<alt>b'"'"', '"'"'<alt>f'"'"', '"'"'<ctrl>v'"'"', '"'"'<ctrl>c'"'"', '"'"'<ctrl><shift>v'"'"', '"'"'<ctrl><shift>c'"'"', '"'"'Menu'"'"']\n"
            } > /target/usr/share/glib-2.0/schemas/01_postmarketos-ui-phosh.gschema.override
        fi
        if [ -f "$PM/postmarketos-ui-phosh/mimeapps.list" ]; then
            install -Dm644 "$PM/postmarketos-ui-phosh/mimeapps.list" \
                /target/usr/share/applications/mimeapps.list
        fi
        if [ -f "$PM/postmarketos-ui-phosh/udiskie.desktop" ]; then
            install -Dm644 "$PM/postmarketos-ui-phosh/udiskie.desktop" \
                /target/etc/xdg/autostart/udiskie.desktop
        fi
        if [ -f "$PM/postmarketos-base-ui-gnome/00_postmarketos-base-ui-gnome.gschema.override" ]; then
            install -Dm644 "$PM/postmarketos-base-ui-gnome/00_postmarketos-base-ui-gnome.gschema.override" \
                /target/usr/share/glib-2.0/schemas/00_postmarketos-base-ui-gnome.gschema.override
        fi
        if [ -f "$PM/postmarketos-base-ui-gnome/10_postmarketos-green-accent.gschema.override" ]; then
            install -Dm644 "$PM/postmarketos-base-ui-gnome/10_postmarketos-green-accent.gschema.override" \
                /target/usr/share/glib-2.0/schemas/10_postmarketos-green-accent.gschema.override
        fi
        BUI="$PM/postmarketos-base-ui"
        if [ -d "$BUI" ]; then
            install -Dm644 "$BUI/rootfs-etc-chrony-chrony.conf" /target/etc/chrony/chrony.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-elogind-logind.conf" /target/etc/elogind/logind.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-sleep-inhibitor.conf" /target/etc/sleep-inhibitor.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-conf.d-bluetooth" /target/etc/conf.d/bluetooth 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-conf.d-openrc-settingsd" /target/etc/conf.d/openrc-settingsd 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-conf.d-modemmanager" /target/etc/conf.d/modemmanager 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-conf.d-wpa_supplicant" /target/etc/conf.d/wpa_supplicant 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-skel-.profile" /target/etc/skel/.profile 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-NetworkManager-conf.d-50-connectivity.conf" \
                /target/usr/lib/NetworkManager/conf.d/50-connectivity.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-NetworkManager-conf.d-50-hostname-mode.conf" \
                /target/usr/lib/NetworkManager/conf.d/50-hostname-mode.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-NetworkManager-conf.d-50-iwd.conf" \
                /target/usr/lib/NetworkManager/conf.d/50-iwd.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-NetworkManager-conf.d-50-random-mac.conf" \
                /target/usr/lib/NetworkManager/conf.d/50-random-mac.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-NetworkManager-conf.d-50-use-dnsmasq.conf" \
                /target/usr/lib/NetworkManager/conf.d/50-use-dnsmasq.conf 2>/dev/null || true
            install -Dm755 "$BUI/rootfs-usr-lib-NetworkManager-dispatcher.d-50-dns-filter.sh" \
                /target/usr/lib/NetworkManager/dispatcher.d/50-dns-filter.sh 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-share-wireplumber-wireplumber.conf.d-50-bluetooth.conf" \
                /target/usr/share/wireplumber/wireplumber.conf.d/50-bluetooth.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-udev-rules.d-50-udmabuf.rules" \
                /target/usr/lib/udev/rules.d/50-udmabuf.rules 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-udev-rules.d-90-iio-sensor-proxy-proximity-sensor-enable.rules" \
                /target/usr/lib/udev/rules.d/90-iio-sensor-proxy-proximity-sensor-enable.rules 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-share-mkinitfs-files-10-wireless-regdb.files" \
                /target/usr/share/mkinitfs/files/10-wireless-regdb.files 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-share-flatpak-remotes.d-flathub.flatpakrepo" \
                /target/usr/share/flatpak/remotes.d/flathub.flatpakrepo 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-profile.d-qt-mobile-controls.sh" \
                /target/etc/profile.d/qt-mobile-controls.sh 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-profile.d-qt-wayland.sh" \
                /target/etc/profile.d/qt-wayland.sh 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-X11-Xwrapper.config" /target/etc/X11/Xwrapper.config 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-etc-conf.d-tinydm" /target/etc/conf.d/tinydm 2>/dev/null || true
            mkdir -p /target/etc/pulse/default.pa.d
            install -Dm644 "$BUI/rootfs-etc-pulse-default.pa.d-postmarketos.pa" \
                /target/etc/pulse/default.pa.d/postmarketos.pa 2>/dev/null || true
            # Systemd unit drop-ins (for systemd guests / documentation; inert on OpenRC).
            mkdir -p /target/usr/lib/systemd/system/flatpak-system-helper.service.d \
                /target/usr/lib/systemd/system/ModemManager.service.d \
                /target/usr/lib/systemd/system/iio-sensor-proxy.service.d
            install -Dm644 "$BUI/rootfs-usr-lib-systemd-system-flatpak-system-helper.service.d-wait-for-ntp.conf" \
                /target/usr/lib/systemd/system/flatpak-system-helper.service.d/wait-for-ntp.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-systemd-system-ModemManager.service.d-quick-suspend-resume.conf" \
                /target/usr/lib/systemd/system/ModemManager.service.d/quick-suspend-resume.conf 2>/dev/null || true
            install -Dm644 "$BUI/rootfs-usr-lib-systemd-system-iio-sensor-proxy.service.d-shutdown.conf" \
                /target/usr/lib/systemd/system/iio-sensor-proxy.service.d/shutdown.conf 2>/dev/null || true
        fi
        PART="$PM/postmarketos-artwork"
        if [ -f "$PART/10_pmOS-wallpaper.gschema.override" ]; then
            install -Dm644 "$PART/10_pmOS-wallpaper.gschema.override" \
                /target/usr/share/glib-2.0/schemas/10_pmOS-wallpaper.gschema.override
        fi
        PBASE="$PM/postmarketos-base"
        if [ -d "$PBASE" ]; then
            mkdir -p /target/etc/ssh/sshd_config.d /target/etc/sudoers.d /target/etc/doas.d \
                /target/usr/lib/sysctl.d /target/usr/lib/kernel-cmdline.d
            install -Dm600 "$PBASE/rootfs-etc-ssh-sshd_config.d-50-postmarketos-ui-policy.conf" \
                /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf 2>/dev/null || true
            # Some OpenSSH builds in this image path do not support UsePAM.
            # If left in place, sshd exits on boot and hostfwd :2222 appears hung/reset.
            if [ -f /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf ]; then
                sed -i '/^[[:space:]]*UsePAM[[:space:]]\+/d' \
                    /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
            fi
            install -Dm440 "$PBASE/rootfs-etc-sudoers" /target/etc/sudoers 2>/dev/null || true
            install -Dm640 "$PBASE/rootfs-etc-doas.d-10-postmarketos.conf" \
                /target/etc/doas.d/10-postmarketos.conf 2>/dev/null || true
            # Identity (postmarketOS). Alpine normally symlinks /etc/os-release; replace with pm file.
            install -Dm644 "$PBASE/rootfs-usr-lib-os-release" /target/usr/lib/os-release 2>/dev/null || true
            rm -f /target/etc/os-release
            ln -sf /usr/lib/os-release /target/etc/os-release
            install -Dm644 "$PBASE/rootfs-usr-lib-kernel-cmdline.d-00-base.conf" \
                /target/usr/lib/kernel-cmdline.d/00-base.conf 2>/dev/null || true
            install -Dm644 "$PBASE/rootfs-usr-lib-kernel-cmdline.d-90-nosplash.conf" \
                /target/usr/lib/kernel-cmdline.d/90-nosplash.conf 2>/dev/null || true
            install -Dm644 "$PBASE/rootfs-usr-lib-sysctl.d-90-disable-rp-filter.conf" \
                /target/usr/lib/sysctl.d/90-disable-rp-filter.conf 2>/dev/null || true
            install -Dm644 "$PBASE/rootfs-usr-lib-sysctl.d-90-steam.conf" \
                /target/usr/lib/sysctl.d/90-steam.conf 2>/dev/null || true
            for n in 20-imagis-input 20-tm2-touchkey-input 20-tm2-touchkey-leds 20-zinitix-input; do
                install -Dm644 "$PBASE/rootfs-usr-lib-udev-rules.d-${n}.rules" \
                    "/target/usr/lib/udev/rules.d/${n}.rules" 2>/dev/null || true
            done
            install -Dm644 "$PBASE/rootfs-usr-lib-apk-config" /target/usr/lib/apk/config 2>/dev/null || true
            install -Dm644 "$PBASE/rootfs-etc-issue" /target/etc/issue 2>/dev/null || true
            install -Dm644 "$PBASE/rootfs-etc-motd" /target/etc/motd 2>/dev/null || true
        fi
        if [ -f "$PM/postmarketos-qemu-common/wlr-no-hw-cursor.sh" ]; then
            install -Dm644 "$PM/postmarketos-qemu-common/wlr-no-hw-cursor.sh" \
                /target/etc/profile.d/10-wlr-no-hw-cursor.sh
        fi
        glib-compile-schemas /target/usr/share/glib-2.0/schemas/ 2>/dev/null || true

        # Create phoc.ini configuration for virtio-gpu output
        mkdir -p /target/etc
        cat > /target/etc/phoc.ini <<'PHOCINI'
[output:Virtual-1]
scale = 1

[core]
xwayland = true
PHOCINI

        # Create XDG_RUNTIME_DIR for the user session (UID matches postmarketOS default 10000)
        mkdir -p "/target/run/user/${PMOS_USER_UID}"
        chmod 700 "/target/run/user/${PMOS_USER_UID}"
        # Install openssl in container to generate password hash
        apk add --no-cache openssl >/dev/null 2>&1 || true
        pass_hash="$(openssl passwd -6 "$INSTALL_PASSWORD" 2>/dev/null || true)"
        if [ -z "$pass_hash" ]; then
            echo "WARN: openssl passwd failed, trying mkpasswd..." >&2
            apk add --no-cache libxcrypt >/dev/null 2>&1 || true
            pass_hash="$(echo "$INSTALL_PASSWORD" | mkpasswd -s -m sha-512 2>/dev/null || true)"
        fi
        [ -n "$pass_hash" ] || { echo "ERROR: could not generate password hash" >&2; exit 1; }
        awk -F: -v h="$pass_hash" '"'"'BEGIN{OFS=":"} $1=="root"{$2=h} {print}'"'"' /target/etc/shadow > /target/etc/shadow.new
        mv /target/etc/shadow.new /target/etc/shadow
        mkdir -p /target/home/user
        printf "user:x:%s:%s:AtomOS User:/home/user:/bin/bash\n" "${PMOS_USER_UID}" "${PMOS_USER_UID}" >> /target/etc/passwd
        # Add user to required groups for graphical session (video, audio, input, seat)
        printf "user:x:%s:\n" "${PMOS_USER_UID}" >> /target/etc/group
        printf "%s\n" "wheel:x:10:user" >> /target/etc/group
        # Append user to existing groups (video, audio, input, seat, plugdev, feedbackd)
        # feedbackd group is required by postmarketos-ui-phosh for haptic feedback
        for grp in video audio input plugdev seat feedbackd; do
            if grep -q "^${grp}:" /target/etc/group 2>/dev/null; then
                sed -i "s/^${grp}:\\([^:]*\\):\\([^:]*\\):\\(.*\\)$/${grp}:\\1:\\2:\\3,user/" /target/etc/group
                sed -i "s/:,user/:user/" /target/etc/group
            else
                printf "%s:x:100:user\n" "$grp" >> /target/etc/group || true
            fi
        done
        printf "user:%s:19000:0:99999:7:::\n" "$pass_hash" >> /target/etc/shadow
        chown -R "${PMOS_USER_UID}:${PMOS_USER_UID}" /target/home/user || true
        
        # Create XDG runtime directory structure (will be populated at runtime)
        mkdir -p /target/run/user
        chmod 755 /target/run/user
        
        # Create phosh session startup script in user profile
        mkdir -p /target/home/user/.config
        printf "%s\n" "export XDG_RUNTIME_DIR=/run/user/${PMOS_USER_UID}" > /target/home/user/.bash_profile
        printf "%s\n" "export XDG_SESSION_TYPE=wayland" >> /target/home/user/.bash_profile
        printf "%s\n" "export XDG_CURRENT_DESKTOP=Phosh:GNOME" >> /target/home/user/.bash_profile
        printf "%s\n" "export WAYLAND_DISPLAY=wayland-0" >> /target/home/user/.bash_profile
        chown -R "${PMOS_USER_UID}:${PMOS_USER_UID}" /target/home/user/.config

        # Pre-generate SSH host keys so first boot has a ready sshd.
        if [ -x /target/usr/bin/ssh-keygen ]; then
            chroot /target /usr/bin/ssh-keygen -A >/dev/null 2>&1 || \
                echo "WARN: ssh-keygen -A failed in target rootfs; first boot may need manual keygen." >&2
        fi
    '

echo "=== build-qemu: regenerate initramfs with virtio modules ==="
"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
    -v "$ROOT_DIR:/iso:ro" \
    "$ALPINE_IMAGE" /bin/sh -eu -c '
        # Configure modules to load at boot for QEMU virtio devices.
        # This file will be included in the initramfs and read by the init script.
        mkdir -p /target/etc
        cat > /target/etc/modules <<EOF
virtio_blk
virtio_net
virtio_gpu
virtio_input
evdev
ext4
drm
EOF

        # Regenerate initramfs to include /etc/modules
        KVER=$(ls /target/lib/modules/ 2>/dev/null | head -1)
        if [ -z "$KVER" ]; then
            echo "WARN: no kernel modules found; skipping initramfs regeneration"
        else
            echo "Regenerating initramfs for kernel $KVER..."
            # Install mkinitfs in the container to regenerate initramfs
            apk add --no-interactive mkinitfs >/dev/null 2>&1
            
            # Create /etc/modules in container (not just target) for mkinitfs
            cp /target/etc/modules /etc/modules
            
            # Create custom feature file to include /etc/modules in initramfs
            # Alpine mkinitfs does NOT include /etc/modules by default!
            mkdir -p /etc/mkinitfs/features.d
            echo "/etc/modules" > /etc/mkinitfs/features.d/qemu.files
            # postmarketos-base-ui wireless-regdb fragment (pmaports)
            if [ -f /iso/pmaports/main/postmarketos-base-ui/rootfs-usr-share-mkinitfs-files-10-wireless-regdb.files ]; then
                cat /iso/pmaports/main/postmarketos-base-ui/rootfs-usr-share-mkinitfs-files-10-wireless-regdb.files \
                    >> /etc/mkinitfs/features.d/qemu.files
            fi
            if [ -f /iso/pmaports/main/postmarketos-base/rootfs-usr-share-mkinitfs-files-postmarketos-base.files ]; then
                cat /iso/pmaports/main/postmarketos-base/rootfs-usr-share-mkinitfs-files-postmarketos-base.files \
                    >> /etc/mkinitfs/features.d/qemu.files
            fi
            
            # Create mkinitfs config with qemu feature that includes /etc/modules
            cat > /tmp/mkinitfs.conf <<MKCONF
features="base ext4 virtio qemu"
MKCONF
            
            # Run mkinitfs against the target kernel modules
            mkinitfs -c /tmp/mkinitfs.conf \
                -b /target \
                -o /target/boot/initramfs-virt \
                "$KVER" 2>&1 || {
                echo "WARN: mkinitfs failed; using stock initramfs"
            }
            
            # Verify /etc/modules is in the generated initramfs
            mkdir -p /tmp/verify
            cd /tmp/verify
            zcat /target/boot/initramfs-virt 2>/dev/null | cpio -idm 2>/dev/null
            if [ -f etc/modules ]; then
                echo "Verified: /etc/modules included in initramfs"
                cat etc/modules
            else
                echo "ERROR: /etc/modules NOT included in initramfs!"
            fi
        fi
    '

echo "=== build-qemu: build/install custom phosh + rust components ==="
PHOSH_SRC="$ROOT_DIR/rust/phosh/phosh"
if [ ! -f "$PHOSH_SRC/meson.build" ]; then
    echo "ERROR: custom phosh source missing: $PHOSH_SRC" >&2
    exit 4
fi

for _atomos_local_meson in \
    "$VENDOR_DIR/phoc" \
    "$VENDOR_DIR/phosh-mobile-settings" \
    "$VENDOR_DIR/phosh-wallpapers"
do
    if [ -f "$_atomos_local_meson/meson.build" ]; then
        _atomos_vendor_name="${_atomos_local_meson#"$VENDOR_DIR"/}"
        echo "build-qemu: will compile vendor/$_atomos_vendor_name from $_atomos_local_meson (container: /work/iso-postmarketos/vendor/$_atomos_vendor_name)"
    fi
done
unset _atomos_local_meson _atomos_vendor_name 2>/dev/null || true

build_container_script='
set -eu
printf "%s\n" \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/main" \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/community" \
  "https://dl-cdn.alpinelinux.org/alpine/edge/main" \
  "https://dl-cdn.alpinelinux.org/alpine/edge/community" \
  "https://dl-cdn.alpinelinux.org/alpine/edge/testing" > /etc/apk/repositories
apk update >/dev/null
apk add --no-interactive \
  build-base git meson ninja-build pkgconf \
  rust cargo \
  glib-dev gtk4.0-dev libadwaita-dev \
  evolution-data-server-dev \
  gnome-bluetooth-dev \
  gnome-desktop-dev \
  libgudev-dev \
  libhandy1-dev \
  callaudiod-dev \
  feedbackd-dev \
  pulseaudio-dev \
  networkmanager-dev \
  modemmanager-dev \
  upower-dev \
  evince-dev \
  qrcodegen-dev \
  polkit-dev \
  elogind-dev \
  webkit2gtk-6.0-dev gstreamer-dev \
  gobject-introspection-dev vala \
  wayland-dev wayland-protocols \
  libxkbcommon-dev dbus-dev linux-pam-dev \
  pango-dev cairo-dev gdk-pixbuf-dev libsoup3-dev json-glib-dev
# gtk4-layer-shell comes from edge/testing and may still be unavailable on some mirrors.
apk add --no-interactive gtk4-layer-shell-dev >/dev/null 2>&1 || \
  apk add --no-interactive gtk4-layer-shell >/dev/null 2>&1 || true

# `ar` shim that strips the T (thin archive) flag.
#
# Meson on GCC + Alpine binutils 2.42+ defaults to thin archives for internal
# convenience static libs (libphosh-tool.a, libgvc.a, libcall-ui.a). A thin .a
# only stores *paths* to the underlying .o files; at link time `ld` opens every
# member through whatever filesystem holds /cache/<component>. With many member
# objects (phosh links ~90 .o files into libphosh.so) the macOS Docker bind
# mount returns EPERM on members semi-randomly, surfacing as:
#   ld: subprojects/gvc/libgvc.a(.../gvc-mixer-ui-device.c.o):
#       error opening thin archive member: Operation not permitted
# Raising --ulimit nofile only delays the failure (it lands on a different
# member next run). The reliable fix is to make ar produce regular archives,
# which embed the member content and never re-open files at link time. The
# tradeoff is slightly larger .a files in the cache, which we never install.
mkdir -p /usr/local/bin
# Heredoc terminator MUST be quoted so the container `sh` does not expand $1,
# $#, $@, etc. inside the shim body at write time (set -u in this script
# would otherwise abort with "sh: 1: parameter not set"). We use DOUBLE
# quotes here, not single, because this entire build_container_script is
# itself wrapped in single quotes by the host bash; an inner single quote
# would terminate the surrounding string and silently un-quote the heredoc.
cat > /usr/local/bin/ar <<"AR_SHIM"
#!/bin/sh
# Strip the "T" (thin) flag from ar operation modifiers. Forward everything
# else verbatim. Operation modifiers are the FIRST positional arg, optionally
# preceded by "-" (e.g. "csrTD" or "-csrTD"); long options ("--version",
# "--help", "--target=...") and file names must pass through untouched.
if [ "$#" -eq 0 ]; then
    exec /usr/bin/ar
fi
_first="$1"
shift
case "$_first" in
    --*) ;;
    -[a-zA-Z]*|[a-zA-Z]*)
        _first=$(printf "%s" "$_first" | tr -d "T")
        ;;
esac
exec /usr/bin/ar "$_first" "$@"
AR_SHIM
chmod 0755 /usr/local/bin/ar
export PATH="/usr/local/bin:$PATH"
export AR="/usr/local/bin/ar"
echo "build-qemu: installed ar shim that strips thin-archive flag (AR=$AR)"

# Belt-and-suspenders: bump the per-process fd limit too. The docker run flag
# already sets nofile=65536:65536, but inside the container `ulimit -n` reports
# what each forked process actually inherits and surfaces drift if a future
# refactor drops the --ulimit flag.
if ulimit -n 65536 2>/dev/null; then
    echo "build-qemu: ulimit -n raised to $(ulimit -n)"
else
    echo "build-qemu: WARN: could not raise ulimit -n (current=$(ulimit -n))"
fi

# Delete any pre-existing thin archives in the meson cache. Older runs (before
# the AR shim landed) populated /cache/<component>/.../*.a as thin archives;
# their member paths are resolved by ld at link time and would still trip the
# EPERM. Removing them is safe: ninja sees the missing output and re-invokes
# ar via the new shim, producing a regular archive in the same place. We do
# this in a forked subshell so EPIPE/find quirks cannot abort `set -e`.
#
# Note: the find argument uses double quotes, not single, because the entire
# build_container_script lives inside a single-quoted host bash string; a
# nested single quote would prematurely terminate that string and silently
# corrupt everything that follows.
unthin_cached_archives() {
    if ! command -v file >/dev/null 2>&1; then
        apk add --no-interactive file >/dev/null 2>&1 || return 0
    fi
    _list=$(find /cache -type f -name "*.a" 2>/dev/null)
    [ -n "$_list" ] || return 0
    _count=0
    printf "%s\n" "$_list" | while IFS= read -r _a; do
        [ -n "$_a" ] || continue
        if file "$_a" 2>/dev/null | grep -qi "thin archive"; then
            rm -f "$_a"
            _count=$((_count + 1))
            echo "build-qemu: removed stale thin archive: $_a"
        fi
    done
}
unthin_cached_archives || true

# ccache: each `apk update && apk add` between build-qemu runs reinstalls
# header packages (glib-dev, gtk4.0-dev, libadwaita-dev, ...). Reinstall bumps
# header mtimes even when contents are identical, which makes ninja re-run
# every compile rule despite the cached build dir. ccache short-circuits those
# "rebuilds" by hashing input file *content*, returning the previously stored
# .o on a hit. Persist the cache under /cache so it survives across runs.
mkdir -p /cache
apk add --no-interactive ccache >/dev/null 2>&1 || true
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR=/cache/.ccache
    mkdir -p "$CCACHE_DIR"
    export CCACHE_COMPRESS=1
    export CCACHE_MAXSIZE="${ATOMOS_CCACHE_MAXSIZE:-5G}"
    # Set CC/CXX so meson records `ccache gcc` in build.ninja (vs absolute
    # /usr/bin/gcc). Existing caches built before ccache was wired in will see
    # a hash mismatch from the meson_cache_setup args hash below and run
    # --reconfigure once to pick this up.
    export CC="ccache gcc"
    export CXX="ccache g++"
    echo "build-qemu: ccache enabled (dir=$CCACHE_DIR, max=$CCACHE_MAXSIZE)"
    ccache --version 2>/dev/null | head -1 || true
    ccache -s 2>/dev/null | head -8 || true
else
    echo "build-qemu: ccache unavailable; compile cache disabled"
fi

# Meson build cache: each component reuses /cache/<name> across build-qemu runs
# so ninja does incremental rebuilds. The host bind-mounts
# build/qemu-meson-cache-<profile> -> /cache. To force a clean build, run with
# ATOMOS_QEMU_MESON_CACHE_CLEAN=1.
meson_cache_setup() {
    _build_dir="$1"; shift
    _src_dir="$1"; shift
    # Hash of (src + compiler env + meson args) detects when the caller changes
    # -D flags or when CC/CXX/AR flips (e.g. ccache wired in, or the no-thin
    # ar shim landed) so we do not silently keep building with stale options.
    _hash=$(printf "%s\n" "$_src_dir" "CC=${CC:-}" "CXX=${CXX:-}" "AR=${AR:-}" "$@" \
            | sha256sum | cut -d" " -f1)
    _marker="$_build_dir/.atomos-meson-args"
    if [ -f "$_build_dir/build.ninja" ] && [ -f "$_marker" ] \
        && [ "$(cat "$_marker" 2>/dev/null)" = "$_hash" ]; then
        echo "build-qemu: reusing meson cache: $_build_dir"
    elif [ -f "$_build_dir/build.ninja" ]; then
        echo "build-qemu: meson args changed -> reconfigure: $_build_dir"
        meson setup --reconfigure "$_build_dir" "$_src_dir" "$@"
        printf "%s" "$_hash" > "$_marker"
    else
        rm -rf "$_build_dir"
        mkdir -p "$(dirname "$_build_dir")"
        meson setup "$_build_dir" "$_src_dir" "$@"
        printf "%s" "$_hash" > "$_marker"
    fi
    unset _build_dir _src_dir _hash _marker
}

# Build and install gmobile: prefer vendored phoc subproject (matches vendor/phoc),
# else phosh subproject. Same host /usr + DESTDIR pattern as phosh below.
GMOBILE_DIR=/work/iso-postmarketos/vendor/phoc/subprojects/gmobile
if [ ! -f "$GMOBILE_DIR/meson.build" ]; then
    GMOBILE_DIR=/work/iso-postmarketos/rust/phosh/phosh/subprojects/gmobile
fi
GMOBILE_BUILD=/cache/gmobile
echo "Building gmobile from: $GMOBILE_DIR (cache: $GMOBILE_BUILD)"
apk add --no-interactive libgudev-dev >/dev/null 2>&1 || true
meson_cache_setup "$GMOBILE_BUILD" "$GMOBILE_DIR" --prefix=/usr -Dtests=false -Dgtk_doc=false
ninja -C "$GMOBILE_BUILD"
# Install into the *build* /usr, not only DESTDIR: gmobile-1.pc reports
# Cflags: -I/usr/include/gmobile. With DESTDIR-only, those
# paths are missing in the container and phosh fails with: gmobile.h: No such file.
ninja -C "$GMOBILE_BUILD" install
DESTDIR=/target ninja -C "$GMOBILE_BUILD" install

# Verify gmobile installation
if [ -f /target/usr/lib/libgmobile.so.0 ] && [ -f /usr/include/gmobile/gmobile.h ]; then
    echo "gmobile installed successfully (host + /target rootfs)"
    ls -la /target/usr/lib/libgmobile*
else
    echo "ERROR: gmobile library or host headers missing!"
    exit 1
fi

# Staged installs under /target must be visible to pkg-config for later Meson
# builds (phosh, phoc, phosh-mobile-settings).
export PKG_CONFIG_PATH="/target/usr/lib/pkgconfig:/target/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Build and stage custom phosh.
PHOSH_BUILD=/cache/phosh
meson_cache_setup "$PHOSH_BUILD" /work/iso-postmarketos/rust/phosh/phosh --prefix=/usr -Dtests=false
ninja -C "$PHOSH_BUILD"
# Install to the build host /usr, not only DESTDIR: phosh-settings .pc uses
# -I/usr/include/phosh; phosh-mobile-settings includes <phosh-settings-enums.h>
# and fails if that path only exists under /target.
ninja -C "$PHOSH_BUILD" install
DESTDIR=/target ninja -C "$PHOSH_BUILD" install
if [ ! -f /usr/include/phosh/phosh-settings-enums.h ]; then
    echo "ERROR: phosh headers missing under /usr/include/phosh after host install" >&2
    exit 1
fi

# Optional: local phoc checkout under iso-postmarketos/vendor/.
if [ -f /work/iso-postmarketos/vendor/phoc/meson.build ]; then
    echo "Building phoc from /work/iso-postmarketos/vendor/phoc..."
    PHOC_SP=/work/iso-postmarketos/vendor/phoc/subprojects
    for _v in \
        "$PHOC_SP/gvdb/meson.build" \
        "$PHOC_SP/gmobile/meson.build" \
        "$PHOC_SP/wlroots/meson.build"
    do
        if [ ! -f "$_v" ]; then
            echo "ERROR: phoc vendored subproject missing: $_v (see vendor/phoc/README.md)" >&2
            exit 1
        fi
    done
    unset _v PHOC_SP
    apk add --no-interactive \
        wlroots-dev libinput-dev libdrm-dev pixman-dev libxkbcommon-dev \
        wayland-dev wayland-protocols eudev-dev json-glib-dev \
        gnome-desktop-dev gsettings-desktop-schemas-dev libseat-dev hwdata-dev
    # hwdata-dev: provides hwdata.pc; wlroots DRM backend needs it (pnp.ids -> pnpids.c). Plain
    # `hwdata` is runtime data only—without the .pc Meson skips DRM and phoc fails linking
    # wlr_output_is_drm / wlr_drm_connector_*.
    PHOC_BUILD=/cache/phoc
    # Static wlroots avoids runtime mismatch: distro libwlroots.so can be older/newer
    # than symbols phoc linked against (e.g. wlr_surface_set_preferred_buffer_scale).
    # Embed only the GLES2 renderer: phosh default wlroots opts include vulkan, which needs
    # glslang/glslangValidator at build time; AtomOS QMI targets GLES2-only anyway.
    # Disable Xwayland in embedded wlroots: no xserver subproject/pkg-config fallback in-tree;
    # phoc must match (-Dxwayland) or meson errors if phoc expects Xwayland but wlroots lacks it.
    # Disable libliftoff in embedded wlroots: linking would otherwise DT_NEEDED libliftoff.so; the
    # rootfs often has an older libliftoff than the build image (missing e.g.
    # liftoff_plane_destroy). WLroots falls back to the non-libliftoff DRM path (HAVE_LIBLIFTOFF=0).
    meson_cache_setup "$PHOC_BUILD" /work/iso-postmarketos/vendor/phoc --prefix=/usr \
        -Dtests=false \
        -Dman=false \
        -Dembed-wlroots=enabled \
        -Dxwayland=disabled \
        -Dwlroots:renderers=gles2 \
        -Dwlroots:xwayland=disabled \
        -Dwlroots:libliftoff=disabled \
        --default-library=static
    ninja -C "$PHOC_BUILD"
    # Host + staged rootfs: .pc and headers use prefix=/usr (see gmobile comment).
    ninja -C "$PHOC_BUILD" install
    DESTDIR=/target ninja -C "$PHOC_BUILD" install
    if [ ! -x /usr/bin/phoc ]; then
        echo "ERROR: phoc not in host PATH after install (check meson --prefix and install rules)" >&2
        exit 1
    fi
fi

# Optional: phosh-mobile-settings (depends on phosh .pc files in /target).
if [ -f /work/iso-postmarketos/vendor/phosh-mobile-settings/meson.build ]; then
    echo "Building phosh-mobile-settings from /work/iso-postmarketos/vendor/phosh-mobile-settings..."
    PMS_SP=/work/iso-postmarketos/vendor/phosh-mobile-settings/subprojects
    for _v in \
        "$PMS_SP/gmobile/meson.build" \
        "$PMS_SP/gvc/meson.build" \
        "$PMS_SP/libadwaita/meson.build" \
        "$PMS_SP/libcellbroadcast/meson.build"
    do
        if [ ! -f "$_v" ]; then
            echo "ERROR: phosh-mobile-settings vendored subproject missing: $_v (see vendor/phosh-mobile-settings/README.md)" >&2
            exit 1
        fi
    done
    unset _v PMS_SP
    apk add --no-interactive \
        desktop-file-utils \
        gsound-dev libportal-dev libportal-gtk4 yaml-dev \
        feedbackd-dev lm-sensors-dev cellbroadcastd-dev gnome-desktop-dev
    PMS_BUILD=/cache/phosh-mobile-settings
    # No project-level `tests` option in this meson.build (Meson errors on unknown -D).
    meson_cache_setup "$PMS_BUILD" /work/iso-postmarketos/vendor/phosh-mobile-settings \
        --prefix=/usr
    ninja -C "$PMS_BUILD"
    ninja -C "$PMS_BUILD" install
    DESTDIR=/target ninja -C "$PMS_BUILD" install
fi

# Optional: wallpapers / plymouth theme / sound theme (mostly data).
if [ -f /work/iso-postmarketos/vendor/phosh-wallpapers/meson.build ]; then
    echo "Building phosh-wallpapers from /work/iso-postmarketos/vendor/phosh-wallpapers..."
    PWP_BUILD=/cache/phosh-wallpapers
    meson_cache_setup "$PWP_BUILD" /work/iso-postmarketos/vendor/phosh-wallpapers --prefix=/usr
    ninja -C "$PWP_BUILD"
    DESTDIR=/target ninja -C "$PWP_BUILD" install
fi

# Surface ccache hit rate so a cached run is visibly cheap (high "cache hits"
# count vs "cache miss"). On a clean cache the first run is all misses; on
# subsequent runs hits should be 90%+ for the C/C++ portion.
if command -v ccache >/dev/null 2>&1; then
    echo "build-qemu: ccache stats after C/C++ builds:"
    ccache -s 2>/dev/null || true
fi

# Build/install overview chat UI.
cargo build --manifest-path /work/iso-postmarketos/rust/atomos-overview-chat-ui/Cargo.toml \
  -p atomos-overview-chat-ui-app \
  --release \
  --bin atomos-overview-chat-ui
install -d /target/usr/local/bin /target/usr/libexec
install -m 0755 /work/iso-postmarketos/rust/atomos-overview-chat-ui/target/release/atomos-overview-chat-ui /target/usr/local/bin/atomos-overview-chat-ui
ln -sf ../local/bin/atomos-overview-chat-ui /target/usr/bin/atomos-overview-chat-ui

# Build atomos-home-bg binary into the workspace target dir. The actual
# install (binary + launcher + HTML) is handled by install-atomos-home-bg.sh
# in ROOTFS_DIR mode in the next container step, so the launcher contract
# (lifecycle envs, runtime gate, disable marker) stays identical to
# build-image.sh and the `verify_home_bg_launcher_contract` check passes.
if [ "${BUILD_HOME_BG:-0}" = "1" ] && [ -f /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml ]; then
  cargo build --manifest-path /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml \
    --release \
    --bin atomos-home-bg
  test -x /work/iso-postmarketos/rust/atomos-home-bg/target/release/atomos-home-bg
else
  echo "Skipping atomos-home-bg build (manifest missing or disabled)."
fi

# Meson skips post-install glib-compile-schemas when DESTDIR is set ("Skipping custom install script..."),
# so schemas staged under /target exist as .xml only and gschemas.compiled is missing or stale. The
# initial rootfs build already ran glib-compile-schemas once before these installs; rerun after staged
# phosh/phoc/schemas so mobi.phosh.phoc resolves at runtime (fixes phoc: schema not installed).
apk add --no-interactive glib >/dev/null 2>&1 || true
glib-compile-schemas /target/usr/share/glib-2.0/schemas/
'

# --ulimit nofile=65536:65536: belt-and-suspenders against the EPERM cascade
# documented in colima#911 (small-file open via macOS bind mount returns
# EPERM rather than EMFILE once the container's default nofile=1024 is
# exceeded). On the meson cache mount this is now also avoided structurally
# by routing /cache through a named docker volume by default (see
# MESON_CACHE_VOLUME up top); the ulimit bump remains useful for /work and
# any other bind mount that may still be in play.
"$ENGINE" run --rm --platform linux/arm64 \
    --ulimit nofile=65536:65536 \
    -v "$ROOTFS_VOLUME:/target" \
    -v "$REPO_TOP:/work" \
    -v "$MESON_CACHE_MOUNT:/cache" \
    -e BUILD_HOME_BG="$BUILD_HOME_BG" \
    "$ALPINE_IMAGE" /bin/sh -c "$build_container_script"

echo "=== build-qemu: apply direct-rootfs customizations ==="
PROFILE_ENV_CONTAINER="$PROFILE_ENV_SOURCE"
if [[ "$PROFILE_ENV_SOURCE" == "$REPO_TOP/"* ]]; then
    PROFILE_ENV_CONTAINER="/work/${PROFILE_ENV_SOURCE#"$REPO_TOP"/}"
elif [[ "$PROFILE_ENV_SOURCE" != /* ]]; then
    PROFILE_ENV_CONTAINER="/work/iso-postmarketos/$PROFILE_ENV_SOURCE"
fi

"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
    -v "$REPO_TOP:/work" \
    "$ALPINE_IMAGE" /bin/sh -eu -c "
        # Do not pull `coreutils` here. On some host/container combinations this
        # stage can resolve a coreutils build that expects newer libc symbols
        # (e.g. renameat2), which breaks dirname/mkdir/mktemp during helper
        # installs. BusyBox tools are sufficient for these direct-rootfs scripts.
        apk add --no-interactive bash python3 grep sed tar >/dev/null
        if [ -f /work/iso-postmarketos/scripts/rootfs/install-atomos-agents.sh ]; then
            ROOTFS_DIR=/target bash /work/iso-postmarketos/scripts/rootfs/install-atomos-agents.sh \"$PROFILE_ENV_CONTAINER\" || true
        fi
        if [ -f /work/iso-postmarketos/scripts/rootfs/install-bt-tools.sh ]; then
            ROOTFS_DIR=/target bash /work/iso-postmarketos/scripts/rootfs/install-bt-tools.sh \"$PROFILE_ENV_CONTAINER\" || true
        fi
        if [ -f /work/iso-postmarketos/scripts/rootfs/install-btlescan.sh ]; then
            ROOTFS_DIR=/target bash /work/iso-postmarketos/scripts/rootfs/install-btlescan.sh \"$PROFILE_ENV_CONTAINER\" || true
        fi
        if [ -f /work/iso-postmarketos/scripts/overview-chat-ui/install-overview-chat-ui.sh ]; then
            # QEMU-specific launcher defaults:
            # - LAYER_SHELL_DEFAULT=1  : use wlr-layer-shell (phoc supports it)
            # - RUNTIME_DEFAULT=1      : open the --show runtime gate
            #
            # Window transparency is now handled in style.rs as an always-on
            # CSS provider that doesn't depend on the DISABLE_CUSTOM_CSS env
            # var, so home-bg is visible beneath the chat-ui surface even on
            # hardware-safe builds where decorative CSS is disabled.
            ROOTFS_DIR=/target \
                ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL_DEFAULT=1 \
                ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT=1 \
                bash /work/iso-postmarketos/scripts/overview-chat-ui/install-overview-chat-ui.sh \"$PROFILE_ENV_CONTAINER\"
        fi
        if [ -f /work/iso-postmarketos/scripts/home-bg/install-atomos-home-bg.sh ]; then
            if [ \"$BUILD_HOME_BG\" = \"1\" ]; then
                # On the QEMU image we want home-bg to actually appear at
                # session login: flip the launcher's runtime gate ON by
                # default, and let install-atomos-home-bg.sh ship the XDG
                # autostart entry that fires --show. Drop the '|| true' so
                # an install failure surfaces here instead of being masked
                # until the final-verify diagnostic.
                ROOTFS_DIR=/target \
                    ATOMOS_HOME_BG_ENABLE_RUNTIME_DEFAULT=1 \
                    ATOMOS_HOME_BG_INSTALL_AUTOSTART=1 \
                    bash /work/iso-postmarketos/scripts/home-bg/install-atomos-home-bg.sh \"$PROFILE_ENV_CONTAINER\"
            else
                echo 'Skipping home-bg install helper (BUILD_HOME_BG=0).'
            fi
        fi
        if [ -f /work/iso-postmarketos/data/wallpapers/gargantua-black.jpg ]; then
            mkdir -p /target/usr/share/backgrounds/gnome /target/usr/share/backgrounds/atomos /target/usr/share/backgrounds
            cp -f /work/iso-postmarketos/data/wallpapers/gargantua-black.jpg /target/usr/share/backgrounds/gnome/gargantua-black.jpg
            cp -f /work/iso-postmarketos/data/wallpapers/gargantua-black.jpg /target/usr/share/backgrounds/gargantua-black.jpg
            cp -f /work/iso-postmarketos/data/wallpapers/gargantua-black.jpg /target/usr/share/backgrounds/atomos/gargantua-black.jpg
        fi
        if [ "${ATOMOS_QEMU_ENABLE_NFTABLES:-0}" != "1" ]; then
            rm -f /target/etc/runlevels/default/nftables
        fi

        # Last-mile SSH hardening for this build path: later helper scripts may
        # install/refresh packages and re-drop pmaports defaults. Re-apply the
        # sshd policy sanitize right before final verification so first boot
        # doesn't regress into banner timeout/reset on unsupported UsePAM.
        if [ -f /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf ]; then
            sed -i '/^[[:space:]]*UsePAM[[:space:]]\+/d' \
                /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
        fi
        if [ -x /target/usr/bin/ssh-keygen ]; then
            chroot /target /usr/bin/ssh-keygen -A >/dev/null 2>&1 || true
        fi
    "

echo "=== build-qemu: final verification ==="
test -f "$IMAGE_PATH"
"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
    -e BUILD_HOME_BG="$BUILD_HOME_BG" \
    "$ALPINE_IMAGE" /bin/sh -eu -c '
        # Diagnostic verify: report each missing file individually and tally
        # failures so build-qemu prints something more useful than "Error 1".
        FAIL=0
        check_x() {
            if [ -x "$1" ]; then
                echo "  ok  -x $1"
            else
                echo "  FAIL -x $1 (missing or not executable)" >&2
                if [ -e "$1" ]; then
                    echo "       (exists; ls -l $(ls -l "$1" 2>&1))" >&2
                else
                    echo "       (parent listing: $(ls -ld "$(dirname "$1")" 2>&1))" >&2
                fi
                FAIL=1
            fi
        }
        check_f() {
            if [ -f "$1" ]; then
                echo "  ok  -f $1"
            else
                echo "  FAIL -f $1 (file missing)" >&2
                FAIL=1
            fi
        }
        check_grep() {
            local pat="$1" file="$2"
            if [ -f "$file" ] && grep -q "$pat" "$file"; then
                echo "  ok  grep $pat in $file"
            else
                echo "  FAIL grep $pat in $file" >&2
                FAIL=1
            fi
        }
        check_not_grep() {
            local pat="$1" file="$2"
            if [ -f "$file" ] && ! grep -q "$pat" "$file"; then
                echo "  ok  no $pat in $file"
            else
                echo "  FAIL unexpected $pat in $file" >&2
                FAIL=1
            fi
        }

        echo "--- core binaries ---"
        check_x /target/usr/libexec/phosh
        check_x /target/usr/local/bin/atomos-overview-chat-ui
        check_x /target/usr/sbin/sshd
        check_f /target/etc/ssh/ssh_host_ed25519_key
        check_f /target/etc/ssh/ssh_host_rsa_key
        check_not_grep "^[[:space:]]*UsePAM[[:space:]]" /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf

        if [ "${BUILD_HOME_BG:-0}" = "1" ]; then
            echo "--- atomos-home-bg files ---"
            check_x /target/usr/local/bin/atomos-home-bg
            check_x /target/usr/bin/atomos-home-bg
            check_x /target/usr/libexec/atomos-home-bg
            check_f /target/usr/share/atomos-home-bg/index.html

            echo "--- atomos-home-bg launcher contract ---"
            check_grep "ATOMOS_HOME_BG_ENABLE_RUNTIME" /target/usr/libexec/atomos-home-bg
            check_grep "atomos-home-bg.disabled"       /target/usr/libexec/atomos-home-bg
            check_grep "ATOMOS_HOME_BG_LAYER"          /target/usr/libexec/atomos-home-bg
            check_grep "ATOMOS_HOME_BG_INTERACTIVE"    /target/usr/libexec/atomos-home-bg

            echo "--- atomos-home-bg autostart wiring ---"
            check_f /target/etc/xdg/autostart/atomos-home-bg.desktop
            check_grep "Exec=/usr/libexec/atomos-home-bg --show" /target/etc/xdg/autostart/atomos-home-bg.desktop
            check_grep "OnlyShowIn=GNOME;Phosh;"                 /target/etc/xdg/autostart/atomos-home-bg.desktop
            # Runtime gate must be ON in the launcher, otherwise --show is a
            # no-op even with autostart firing it.
            if grep -q ":-1}" /target/usr/libexec/atomos-home-bg \
                || grep -Eq "ATOMOS_HOME_BG_ENABLE_RUNTIME=\"\\\$\\{ATOMOS_HOME_BG_ENABLE_RUNTIME:-1\\}\"" /target/usr/libexec/atomos-home-bg; then
                echo "  ok  launcher has ATOMOS_HOME_BG_ENABLE_RUNTIME default=1"
            else
                echo "  FAIL launcher runtime gate is not 1 by default; --show will no-op" >&2
                echo "       grep ATOMOS_HOME_BG_ENABLE_RUNTIME /target/usr/libexec/atomos-home-bg:" >&2
                grep ATOMOS_HOME_BG_ENABLE_RUNTIME /target/usr/libexec/atomos-home-bg >&2 || true
                FAIL=1
            fi
            echo "--- atomos-home-bg runtime library check ---"
            # Confirm the WebKitGTK and gtk4-layer-shell runtime libraries are
            # present in the rootfs. Missing libs = binary exits rc=127 at
            # session start with no visible error on screen.
            #
            # WebKitGTK 6.0 (GTK4) ships as:
            #   package:  webkit2gtk-6.0
            #   soname:   libwebkitgtk-6.0.so.0   (note: no "2" in the lib name)
            # Earlier GTK3 era used libwebkit2gtk-4.0.so.37 — different name.
            # The rust crate (webkit6) uses pkg-config ID "webkitgtk-6.0".
            for lib in \
                "libwebkitgtk-6.0.so" \
                "libgtk4-layer-shell.so" \
                "libgtk-4.so"; do
                if find /target/usr/lib /target/lib -name "${lib}*" -maxdepth 3 2>/dev/null | grep -q .; then
                    echo "  ok  found ${lib}*"
                else
                    echo "  FAIL ${lib}* not found in rootfs — home-bg will fail to start" >&2
                    FAIL=1
                fi
            done

            echo "--- atomos-home-bg content ---"
            if [ -f /target/usr/share/atomos-home-bg/index.html ]; then
                if grep -q "atomos-home-bg placeholder" /target/usr/share/atomos-home-bg/index.html \
                    || grep -q "atomos-home-bg preview test" /target/usr/share/atomos-home-bg/index.html \
                    || grep -q "fallback placeholder" /target/usr/share/atomos-home-bg/index.html; then
                    echo "  ok  index.html ships expected atomos-home-bg marker"
                else
                    echo "  FAIL index.html lacks the atomos-home-bg marker" >&2
                    echo "       head: $(head -c 200 /target/usr/share/atomos-home-bg/index.html | tr -d "\n")" >&2
                    FAIL=1
                fi
                # The shipped placeholder loads the event-horizon WebGL
                # shader from a sibling file; if the <script> tag is
                # there but the file isn't, the home-bg would silently
                # render only its dark base color on device.
                if grep -q "event-horizon.js" /target/usr/share/atomos-home-bg/index.html; then
                    if [ -f /target/usr/share/atomos-home-bg/event-horizon.js ]; then
                        echo "  ok  event-horizon.js sibling shipped alongside index.html"
                    else
                        echo "  FAIL index.html references event-horizon.js but the file is missing in the rootfs" >&2
                        FAIL=1
                    fi
                fi
            fi
        fi

        if [ "$FAIL" -ne 0 ]; then
            echo "ERROR: build-qemu final verification failed (see above)." >&2
            exit 1
        fi
        echo "build-qemu: final verification OK"
    '

echo "=== build-qemu: pack rootfs into image (containerized) ==="
"$ENGINE" run --rm --privileged \
    -v "$ROOTFS_VOLUME:/target:ro" \
    -v "$EXPORT_DIR:/exportdir" \
    -e PROFILE_NAME="$PROFILE_NAME" \
    "$ALPINE_IMAGE" /bin/sh -eu -c '
        echo "https://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories
        echo "https://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories
        apk update >/dev/null
        apk add --no-interactive parted dosfstools e2fsprogs util-linux mount rsync systemd-boot multipath-tools >/dev/null
        IMAGE=/exportdir/${PROFILE_NAME}.img
        parted -s "$IMAGE" mklabel gpt
        parted -s "$IMAGE" mkpart ESP fat32 1MiB 513MiB
        parted -s "$IMAGE" set 1 esp on
        parted -s "$IMAGE" mkpart rootfs ext4 513MiB 100%
        # Use losetup -P to create partition-aware loop devices
        LOOP_DEV=$(losetup --show -f -P "$IMAGE")
        LOOP_NAME=$(basename "$LOOP_DEV")
        # Re-read partition table (patterns from resync-rootfs-to-disk-image.sh and pmb-container-root-entry.sh)
        if command -v partx >/dev/null 2>&1; then
            partx -u "$LOOP_DEV" 2>/dev/null || true
        fi
        if command -v blockdev >/dev/null 2>&1; then
            blockdev --rereadpt "$LOOP_DEV" 2>/dev/null || true
        fi
        # Wait for partition devices to appear
        LOOP_BOOT="${LOOP_DEV}p1"
        LOOP_ROOT="${LOOP_DEV}p2"
        for i in 1 2 3 4 5; do
            [ -b "$LOOP_BOOT" ] && [ -b "$LOOP_ROOT" ] && break
            sleep 0.5
        done
        # Fallback: use kpartx to create device-mapper partitions (from pmb-container-root-entry.sh)
        USE_KPARTX=0
        if [ ! -b "$LOOP_BOOT" ] || [ ! -b "$LOOP_ROOT" ]; then
            echo "Partition nodes not found; using kpartx fallback..."
            kpartx -av "$LOOP_DEV" 2>/dev/null || true
            sleep 1
            # kpartx creates /dev/mapper/loopXp1, /dev/mapper/loopXp2
            if [ -b "/dev/mapper/${LOOP_NAME}p1" ]; then
                LOOP_BOOT="/dev/mapper/${LOOP_NAME}p1"
                LOOP_ROOT="/dev/mapper/${LOOP_NAME}p2"
                USE_KPARTX=1
            fi
        fi
        if [ ! -b "$LOOP_BOOT" ] || [ ! -b "$LOOP_ROOT" ]; then
            echo "ERROR: partition devices not found: $LOOP_BOOT $LOOP_ROOT" >&2
            ls -la /dev/loop* /dev/mapper/ 2>/dev/null || true
            exit 1
        fi
        cleanup() {
            set +e
            if mountpoint -q /mnt/root/boot 2>/dev/null; then umount /mnt/root/boot; fi
            if mountpoint -q /mnt/root 2>/dev/null; then umount /mnt/root; fi
            if [ "$USE_KPARTX" = "1" ]; then
                kpartx -d "$LOOP_DEV" 2>/dev/null || true
            fi
            if [ -n "${LOOP_DEV:-}" ]; then losetup -d "$LOOP_DEV"; fi
        }
        trap cleanup EXIT
        mkfs.vfat -F 32 "$LOOP_BOOT"
        mkfs.ext4 -F "$LOOP_ROOT"
        mkdir -p /mnt/root
        mount "$LOOP_ROOT" /mnt/root
        mkdir -p /mnt/root/boot
        mount "$LOOP_BOOT" /mnt/root/boot
        # Sync rootfs and boot separately:
        # - /mnt/root/boot is FAT32 and cannot store symlinks
        # - some roots may carry /boot/boot -> . helper symlink
        rsync -a --delete --exclude /boot/ /target/ /mnt/root/
        rsync -a --delete --no-links --exclude boot /target/boot/ /mnt/root/boot/
        mkdir -p /mnt/root/boot/EFI/BOOT
        cp /usr/lib/systemd/boot/efi/systemd-bootaa64.efi /mnt/root/boot/EFI/BOOT/BOOTAA64.EFI
        mkdir -p /mnt/root/boot/loader/entries
        cat > /mnt/root/boot/loader/loader.conf <<EOF
default atomos.conf
timeout 0
console-mode auto
EOF
        cat > /mnt/root/boot/loader/entries/atomos.conf <<EOF
title   AtomOS
linux   /vmlinuz-virt
initrd  /initramfs-virt
options root=/dev/vda2 rw rootwait console=ttyAMA0 console=tty1 modules=virtio_blk debug_init=yes
EOF
    '
if [ "${ATOMOS_SKIP_EXPORT_CHOWN:-0}" != "1" ]; then
    if ! "$ENGINE" run --rm \
        -v "$EXPORT_DIR:/export" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "chown -R $HOST_UID:$HOST_GID /export" >/dev/null 2>&1; then
        echo "Note: skipped export ownership adjustment (expected on some rootless runtimes)."
    fi
fi

echo "Build complete:"
echo "  $IMAGE_PATH"
