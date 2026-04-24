#!/bin/bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: build-qemu.sh [profile-env]

Builds a bootable ARM64 QEMU image from Alpine Linux without pmbootstrap.
EOF
}

PROFILE_ENV="${1:-config/arm64-virt.env}"
if [ "$#" -gt 1 ]; then
    usage
    exit 1
fi
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

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
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
REPO_TOP="$(cd "$ROOT_DIR/.." && pwd)"
ROOTFS_VOLUME="atomos-qemu-rootfs-${PROFILE_NAME}"
REPOSITORIES_FILE="$WORK_DIR/etc_apk_repositories"
HOME_BG_MANIFEST="$ROOT_DIR/rust/atomos-home-bg/app-gtk/Cargo.toml"
BUILD_HOME_BG=1
if [ ! -f "$HOME_BG_MANIFEST" ]; then
    BUILD_HOME_BG=0
    echo "WARN: atomos-home-bg manifest missing; skipping home-bg build/install."
    echo "  missing: $HOME_BG_MANIFEST"
fi

mkdir -p "$EXPORT_DIR" "$WORK_DIR"
rm -f "$REPOSITORIES_FILE"

cleanup_volume() {
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
    openrc
    dbus
    networkmanager
    pipewire
    pipewire-pulse
    wireplumber
    dconf
    bash
    shadow
    util-linux
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
    # Seat/session management (required for Wayland compositors)
    elogind
    elogind-openrc
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
)

# Mirror profile extras + helper script APK dependencies.
PROFILE_EXTRA_CSV="${PMOS_EXTRA_PACKAGES:-}"
HELPER_APK_CSV="python3,py3-pip,ca-certificates,git,build-base,libffi-dev,openssl-dev,bluez,bluez-deprecated,bluez-hcidump,rfkill,figlet,android-tools-adb,py3-cairo,py3-dbus,py3-gobject3,py3-serial,dbus-dev,libbluetooth-dev,bluez-dev,cmake,py3-numpy,pkgconf,linux-headers,curl,graphene-dev,gsettings-desktop-schemas,gcompat"
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
    -v "$ROOTFS_VOLUME:/target" \
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
        ln -sf /etc/init.d/modules /target/etc/runlevels/boot/modules || true
        # Default runlevel services (from postmarketos-base-ui-openrc.post-install)
        ln -sf /etc/init.d/cgroups /target/etc/runlevels/default/cgroups || true
        ln -sf /etc/init.d/dbus /target/etc/runlevels/default/dbus || true
        ln -sf /etc/init.d/haveged /target/etc/runlevels/default/haveged || true
        ln -sf /etc/init.d/chronyd /target/etc/runlevels/default/chronyd || true
        # Default runlevel services (from postmarketos-base-ui-gnome-openrc.post-install)
        ln -sf /etc/init.d/bluetooth /target/etc/runlevels/default/bluetooth || true
        ln -sf /etc/init.d/elogind /target/etc/runlevels/default/elogind || true
        ln -sf /etc/init.d/modemmanager /target/etc/runlevels/default/modemmanager || true
        ln -sf /etc/init.d/networkmanager /target/etc/runlevels/default/networkmanager || true
        # Additional services
        ln -sf /etc/init.d/sshd /target/etc/runlevels/default/sshd || true
        ln -sf /etc/init.d/seatd /target/etc/runlevels/default/seatd || true
        ln -sf /etc/init.d/greetd /target/etc/runlevels/default/greetd || true

        # Configure greetd to use phrog config (same as postmarketos-ui-phosh)
        # This matches pmaports/main/postmarketos-ui-phosh/greetd.confd
        mkdir -p /target/etc/conf.d
        cat > /target/etc/conf.d/greetd <<'GREETD_CONFD'
# Configuration for greetd
# Path to config file to use (phrog provides this)
cfgfile="/etc/phrog/greetd-config.toml"
GREETD_CONFD

        # Install gschema override from postmarketos-ui-phosh
        # This matches pmaports/main/postmarketos-ui-phosh/01_postmarketos-ui-phosh.gschema.override
        mkdir -p /target/usr/share/glib-2.0/schemas
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
        # Recompile gschemas
        glib-compile-schemas /target/usr/share/glib-2.0/schemas/ 2>/dev/null || true

        # Create phoc.ini configuration for virtio-gpu output
        mkdir -p /target/etc
        cat > /target/etc/phoc.ini <<'PHOCINI'
[output:Virtual-1]
scale = 1

[core]
xwayland = true
PHOCINI

        # Create XDG_RUNTIME_DIR for the user session
        mkdir -p /target/run/user/1000
        chmod 700 /target/run/user/1000
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
        printf "%s\n" "user:x:1000:1000:AtomOS User:/home/user:/bin/bash" >> /target/etc/passwd
        # Add user to required groups for graphical session (video, audio, input, seat)
        printf "%s\n" "user:x:1000:" >> /target/etc/group
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
        chown -R 1000:1000 /target/home/user || true
        
        # Create XDG runtime directory structure (will be populated at runtime)
        mkdir -p /target/run/user
        chmod 755 /target/run/user
        
        # Create phosh session startup script in user profile
        mkdir -p /target/home/user/.config
        printf "%s\n" "export XDG_RUNTIME_DIR=/run/user/1000" > /target/home/user/.bash_profile
        printf "%s\n" "export XDG_SESSION_TYPE=wayland" >> /target/home/user/.bash_profile
        printf "%s\n" "export XDG_CURRENT_DESKTOP=Phosh:GNOME" >> /target/home/user/.bash_profile
        printf "%s\n" "export WAYLAND_DISPLAY=wayland-0" >> /target/home/user/.bash_profile
        chown -R 1000:1000 /target/home/user/.config
    '

echo "=== build-qemu: regenerate initramfs with virtio modules ==="
"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
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

# Build and install gmobile from local subproject (required by Alpine phoc)
GMOBILE_DIR=/work/iso-postmarketos/rust/phosh/phosh/subprojects/gmobile
echo "Building gmobile from local subproject..."
rm -rf /tmp/gmobile-build
apk add --no-interactive libgudev-dev >/dev/null 2>&1 || true
meson setup /tmp/gmobile-build "$GMOBILE_DIR" --prefix=/usr -Dtests=false -Dgtk_doc=false
ninja -C /tmp/gmobile-build
DESTDIR=/target ninja -C /tmp/gmobile-build install

# Verify gmobile installation
if [ -f /target/usr/lib/libgmobile.so.0 ]; then
    echo "gmobile installed successfully"
    ls -la /target/usr/lib/libgmobile*
else
    echo "ERROR: gmobile library not installed!"
    exit 1
fi

# Build and stage custom phosh.
rm -rf /tmp/phosh-build
meson setup /tmp/phosh-build /work/iso-postmarketos/rust/phosh/phosh --prefix=/usr -Dtests=false
ninja -C /tmp/phosh-build
DESTDIR=/target ninja -C /tmp/phosh-build install

# Build/install overview chat UI.
cargo build --manifest-path /work/iso-postmarketos/rust/atomos-overview-chat-ui/Cargo.toml \
  -p atomos-overview-chat-ui-app \
  --release \
  --bin atomos-overview-chat-ui
install -d /target/usr/local/bin /target/usr/libexec
install -m 0755 /work/iso-postmarketos/rust/atomos-overview-chat-ui/target/release/atomos-overview-chat-ui /target/usr/local/bin/atomos-overview-chat-ui
ln -sf /usr/local/bin/atomos-overview-chat-ui /target/usr/bin/atomos-overview-chat-ui

# Build/install home-bg UI.
if [ "${BUILD_HOME_BG:-0}" = "1" ] && [ -f /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml ]; then
  cargo build --manifest-path /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml \
    --release \
    --bin atomos-home-bg
  install -m 0755 /work/iso-postmarketos/rust/atomos-home-bg/target/release/atomos-home-bg /target/usr/local/bin/atomos-home-bg
  ln -sf /usr/local/bin/atomos-home-bg /target/usr/bin/atomos-home-bg
  install -d /target/usr/share/atomos-home-bg
  cat > /target/usr/share/atomos-home-bg/index.html <<EOF
<!doctype html><html><body style="margin:0;background:#000;color:#fff;font-family:sans-serif;"><main style="padding:2rem;">AtomOS Home Background</main></body></html>
EOF
else
  echo "Skipping atomos-home-bg build/install (manifest missing or disabled)."
fi
'

"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
    -v "$REPO_TOP:/work" \
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
        apk add --no-interactive bash python3 coreutils grep sed tar >/dev/null
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
            ROOTFS_DIR=/target bash /work/iso-postmarketos/scripts/overview-chat-ui/install-overview-chat-ui.sh \"$PROFILE_ENV_CONTAINER\" || true
        fi
        if [ -f /work/iso-postmarketos/scripts/home-bg/install-atomos-home-bg.sh ]; then
            if [ \"$BUILD_HOME_BG\" = \"1\" ]; then
                ROOTFS_DIR=/target bash /work/iso-postmarketos/scripts/home-bg/install-atomos-home-bg.sh \"$PROFILE_ENV_CONTAINER\" || true
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
    "

echo "=== build-qemu: final verification ==="
test -f "$IMAGE_PATH"
"$ENGINE" run --rm --platform linux/arm64 \
    -v "$ROOTFS_VOLUME:/target" \
    -e BUILD_HOME_BG="$BUILD_HOME_BG" \
    "$ALPINE_IMAGE" /bin/sh -eu -c '
        test -x /target/usr/libexec/phosh
        test -x /target/usr/local/bin/atomos-overview-chat-ui
        if [ "${BUILD_HOME_BG:-0}" = "1" ]; then
            test -x /target/usr/local/bin/atomos-home-bg
        fi
        test -x /target/usr/sbin/sshd
    '

echo "=== build-qemu: pack rootfs into image (containerized) ==="
"$ENGINE" run --rm --privileged \
    -v "$ROOTFS_VOLUME:/target:ro" \
    -v "$EXPORT_DIR:/exportdir" \
    "$ALPINE_IMAGE" /bin/sh -eu -c "
        echo 'https://dl-cdn.alpinelinux.org/alpine/edge/main' >> /etc/apk/repositories
        echo 'https://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories
        apk update >/dev/null
        apk add --no-interactive parted dosfstools e2fsprogs util-linux mount rsync systemd-boot multipath-tools >/dev/null
        IMAGE=/exportdir/${PROFILE_NAME}.img
        parted -s \"\$IMAGE\" mklabel gpt
        parted -s \"\$IMAGE\" mkpart ESP fat32 1MiB 513MiB
        parted -s \"\$IMAGE\" set 1 esp on
        parted -s \"\$IMAGE\" mkpart rootfs ext4 513MiB 100%
        # Use losetup -P to create partition-aware loop devices
        LOOP_DEV=\$(losetup --show -f -P \"\$IMAGE\")
        LOOP_NAME=\$(basename \"\$LOOP_DEV\")
        # Re-read partition table (patterns from resync-rootfs-to-disk-image.sh and pmb-container-root-entry.sh)
        if command -v partx >/dev/null 2>&1; then
            partx -u \"\$LOOP_DEV\" 2>/dev/null || true
        fi
        if command -v blockdev >/dev/null 2>&1; then
            blockdev --rereadpt \"\$LOOP_DEV\" 2>/dev/null || true
        fi
        # Wait for partition devices to appear
        LOOP_BOOT=\"\${LOOP_DEV}p1\"
        LOOP_ROOT=\"\${LOOP_DEV}p2\"
        for i in 1 2 3 4 5; do
            [ -b \"\$LOOP_BOOT\" ] && [ -b \"\$LOOP_ROOT\" ] && break
            sleep 0.5
        done
        # Fallback: use kpartx to create device-mapper partitions (from pmb-container-root-entry.sh)
        USE_KPARTX=0
        if [ ! -b \"\$LOOP_BOOT\" ] || [ ! -b \"\$LOOP_ROOT\" ]; then
            echo \"Partition nodes not found; using kpartx fallback...\"
            kpartx -av \"\$LOOP_DEV\" 2>/dev/null || true
            sleep 1
            # kpartx creates /dev/mapper/loopXp1, /dev/mapper/loopXp2
            if [ -b \"/dev/mapper/\${LOOP_NAME}p1\" ]; then
                LOOP_BOOT=\"/dev/mapper/\${LOOP_NAME}p1\"
                LOOP_ROOT=\"/dev/mapper/\${LOOP_NAME}p2\"
                USE_KPARTX=1
            fi
        fi
        if [ ! -b \"\$LOOP_BOOT\" ] || [ ! -b \"\$LOOP_ROOT\" ]; then
            echo \"ERROR: partition devices not found: \$LOOP_BOOT \$LOOP_ROOT\" >&2
            ls -la /dev/loop* /dev/mapper/ 2>/dev/null || true
            exit 1
        fi
        cleanup() {
            set +e
            if mountpoint -q /mnt/root/boot 2>/dev/null; then umount /mnt/root/boot; fi
            if mountpoint -q /mnt/root 2>/dev/null; then umount /mnt/root; fi
            if [ \"\$USE_KPARTX\" = \"1\" ]; then
                kpartx -d \"\$LOOP_DEV\" 2>/dev/null || true
            fi
            if [ -n \"\${LOOP_DEV:-}\" ]; then losetup -d \"\$LOOP_DEV\"; fi
        }
        trap cleanup EXIT
        mkfs.vfat -F 32 \"\$LOOP_BOOT\"
        mkfs.ext4 -F \"\$LOOP_ROOT\"
        mkdir -p /mnt/root
        mount \"\$LOOP_ROOT\" /mnt/root
        mkdir -p /mnt/root/boot
        mount \"\$LOOP_BOOT\" /mnt/root/boot
        # Sync rootfs and boot separately:
        # - /mnt/root/boot is FAT32 and cannot store symlinks
        # - some roots may carry /boot/boot -> . helper symlink
        rsync -a --delete --exclude /boot/ /target/ /mnt/root/
        rsync -a --delete --no-links --exclude boot /target/boot/ /mnt/root/boot/
        mkdir -p /mnt/root/boot/EFI/BOOT
        cp /usr/lib/systemd/boot/efi/systemd-bootaa64.efi /mnt/root/boot/EFI/BOOT/BOOTAA64.EFI
        mkdir -p /mnt/root/boot/loader/entries
        cat > /mnt/root/boot/loader/loader.conf <<'EOF'
default atomos.conf
timeout 0
console-mode auto
EOF
        cat > /mnt/root/boot/loader/entries/atomos.conf <<'EOF'
title   AtomOS
linux   /vmlinuz-virt
initrd  /initramfs-virt
options root=/dev/vda2 rw rootwait console=ttyAMA0 console=tty1 modules=virtio_blk debug_init=yes
EOF
    "
if [ "${ATOMOS_SKIP_EXPORT_CHOWN:-0}" != "1" ]; then
    if ! "$ENGINE" run --rm \
        -v "$EXPORT_DIR:/export" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "chown -R $HOST_UID:$HOST_GID /export" >/dev/null 2>&1; then
        echo "Note: skipped export ownership adjustment (expected on some rootless runtimes)."
    fi
fi

echo "Build complete:"
echo "  $IMAGE_PATH"
