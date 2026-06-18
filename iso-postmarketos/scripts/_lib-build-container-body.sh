#!/bin/sh
# scripts/_lib-build-container-body.sh -- the long compile script that
# runs INSIDE the heavy aarch64 build container. Bind-mounted at
# /work/iso-postmarketos/scripts/_lib-build-container-body.sh and
# executed via `sh /work/.../_lib-build-container-body.sh`.
#
# Why a separate file: the original build-fairphone4.sh / build-qemu.sh
# embedded this body as a single-quoted heredoc inside the host bash
# script, which made it almost impossible to shellcheck and required
# extra escaping for every single quote. Mounting it as a real file
# keeps the body legible and cleanly diffable.
#
# Required environment (set by the engine -e flags):
#   PMOS_REPO_URL          -- pmOS mirror URL (for `apk add` extras)
#   USE_VENDOR_PHOSH       -- "1" to build vendor phosh + phoc + pms (default in v2)
#   BUILD_HOME_BG          -- "1" to build atomos-home-bg
#   ATOMOS_CCACHE_MAXSIZE  -- ccache size cap (default 5G)
#
# Mounts the engine arranges:
#   /target  -- rootfs volume
#   /work    -- repo top (so /work/iso-postmarketos/... is visible)
#   /cache   -- meson + ccache backend
#   /tmp/pmos.rsa.pub -- pmOS signing key (for apk update against the pmOS mirror)

set -eu
export CARGO_TARGET_DIR=/cache/cargo-target
export CARGO_INCREMENTAL=0
export PKG_CONFIG_PATH="/target/usr/lib/pkgconfig:/target/usr/share/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# --- local-first package store (AtomOS) ---------------------------------
# apk: install the PATH shim so every dev-dependency `apk add` below
# reuses the persistent cache dir and honours the host-selected network
# mode ($ATOMOS_APK_NET). See scripts/container-apk-shim.sh.
mkdir -p /usr/local/bin
install -m0755 /work/iso-postmarketos/scripts/container-apk-shim.sh /usr/local/bin/apk
export PATH="/usr/local/bin:$PATH"
# cargo: CARGO_HOME is bind-mounted from the local store so crates.io
# downloads (registry index + crate sources) persist across builds. When
# the host says the crate cache is warm and no refresh was requested
# ($ATOMOS_CARGO_OFFLINE=1) build fully offline; otherwise cargo fetches
# from the network and repopulates the store.
mkdir -p "${CARGO_HOME:-/pkgcache/cargo-home}"
if [ "${ATOMOS_CARGO_OFFLINE:-0}" = "1" ]; then
    export CARGO_NET_OFFLINE=true
fi

ATOMOS_BUILD_LOG_PREFIX="${ATOMOS_BUILD_LOG_PREFIX:-build-fairphone4-v2}"
# shellcheck source=scripts/_lib-meson-cache-body.sh
. /work/iso-postmarketos/scripts/_lib-meson-cache-body.sh

printf "%s\n" \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/main" \
  "https://dl-cdn.alpinelinux.org/alpine/v3.21/community" \
  "https://dl-cdn.alpinelinux.org/alpine/edge/main" \
  "https://dl-cdn.alpinelinux.org/alpine/edge/community" \
  "https://dl-cdn.alpinelinux.org/alpine/edge/testing" \
  "${PMOS_REPO_URL}" > /etc/apk/repositories
mkdir -p /etc/apk/keys
cp /tmp/pmos.rsa.pub /etc/apk/keys/build.postmarketos.org.rsa.pub
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
apk add --no-interactive gtk4-layer-shell-dev >/dev/null 2>&1 \
  || apk add --no-interactive gtk4-layer-shell >/dev/null 2>&1 || true

# ---- ar shim that strips T (thin archive) ------------------------------
# colima#911: macOS bind-mounted /cache returns EPERM at random when
# linking thin .a files (member files re-opened by ld). Make ar produce
# regular archives instead.
mkdir -p /usr/local/bin
cat > /usr/local/bin/ar <<'AR_SHIM'
#!/bin/sh
if [ "$#" -eq 0 ]; then exec /usr/bin/ar; fi
_first="$1"; shift
case "$_first" in
    --*) ;;
    -[a-zA-Z]*|[a-zA-Z]*) _first=$(printf "%s" "$_first" | tr -d "T") ;;
esac
exec /usr/bin/ar "$_first" "$@"
AR_SHIM
chmod 0755 /usr/local/bin/ar
export PATH="/usr/local/bin:$PATH"
export AR="/usr/local/bin/ar"
ulimit -n 65536 2>/dev/null || true

# ---- ccache so apk-update header reinstalls don't trash cached objects --
apk add --no-interactive ccache file >/dev/null 2>&1 || true
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_DIR=/cache/.ccache
    mkdir -p "$CCACHE_DIR"
    export CCACHE_COMPRESS=1
    export CCACHE_MAXSIZE="${ATOMOS_CCACHE_MAXSIZE:-5G}"
    export CC="ccache gcc"
    export CXX="ccache g++"
fi

# ---- gnome-settings-daemon (patched for gsd-xsettings startup fix) ------
# Rebuild from source with startup-chain-fix so gsd-xsettings chains up to
# GApplication::startup at the beginning, preventing the GLib-CRITICAL
# assertion on FP4 hardware where X11 display init can fail.
GSD_VER=50.1
GSD_SRC_DIR=/tmp/gsd-src
GSD_BUILD_DIR=/cache/gsd-build

echo "Building patched gnome-settings-daemon ${GSD_VER}..."
rm -rf "$GSD_SRC_DIR" "$GSD_BUILD_DIR"
apk add --no-interactive \
    alsa-lib-dev colord-dev cups-dev geoclue-dev geocode-glib-dev \
    gcr4-dev gsettings-desktop-schemas-dev gtk+3.0-dev \
    libcanberra-dev libgweather4-dev libnotify-dev libwacom-dev \
    libxml2-utils wget >/dev/null 2>&1

GSD_TARBALL=/tmp/gsd.tar.xz
wget -q -O "$GSD_TARBALL" \
    "https://download.gnome.org/sources/gnome-settings-daemon/${GSD_VER%.*}/gnome-settings-daemon-${GSD_VER}.tar.xz"
mkdir -p "$GSD_SRC_DIR"
xz -dc "$GSD_TARBALL" | tar -x -C "$GSD_SRC_DIR" --strip-components=1
rm -f "$GSD_TARBALL"

patch -d "$GSD_SRC_DIR" -p1 -N < /work/iso-postmarketos/vendor/aports/community/gnome-settings-daemon/desktop-files.patch
patch -d "$GSD_SRC_DIR" -p1 -N < /work/iso-postmarketos/vendor/aports/community/gnome-settings-daemon/startup-chain-fix.patch

PKG_CONFIG_PATH="${PKG_CONFIG_PATH}" \
meson setup "$GSD_BUILD_DIR" "$GSD_SRC_DIR" \
    --prefix=/usr --sysconfdir=/etc \
    -Db_lto=true -Dsystemd=false -Dsystemd-units=true -Delogind=true
ninja -C "$GSD_BUILD_DIR"
DESTDIR=/target meson install -C "$GSD_BUILD_DIR" --no-rebuild
rm -rf "$GSD_SRC_DIR" "$GSD_BUILD_DIR"
echo "Patched gnome-settings-daemon installed."

# ---- vendor phosh stack (ON by default in v2) --------------------------
if [ "${USE_VENDOR_PHOSH:-1}" = "1" ]; then
    GMOBILE_DIR=/work/iso-postmarketos/vendor/phoc/subprojects/gmobile
    if [ ! -f "$GMOBILE_DIR/meson.build" ]; then
        GMOBILE_DIR=/work/iso-postmarketos/rust/phosh/phosh/subprojects/gmobile
    fi
    GMOBILE_BUILD=/cache/gmobile
    if [ -f "$GMOBILE_DIR/meson.build" ]; then
        echo "Building gmobile from: $GMOBILE_DIR (cache: $GMOBILE_BUILD)"
        apk add --no-interactive libgudev-dev >/dev/null 2>&1 || true
        atomos_meson_ninja_build_install gmobile "$GMOBILE_BUILD" "$GMOBILE_DIR" \
            --prefix=/usr -Dtests=false -Dgtk_doc=false
    else
        echo "build-fairphone4-v2: WARN no gmobile/meson.build found; skipping gmobile build."
    fi

    export PKG_CONFIG_PATH="/target/usr/lib/pkgconfig:/target/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    PHOSH_SRC=/work/iso-postmarketos/rust/phosh/phosh
    PHOSH_BUILD=/cache/phosh
    if [ -f "$PHOSH_SRC/meson.build" ]; then
        echo "Building vendor phosh from: $PHOSH_SRC"
        atomos_meson_ninja_build_install phosh "$PHOSH_BUILD" "$PHOSH_SRC" \
            --prefix=/usr -Dtests=false -Dbindings-lib=true
        if [ ! -f /usr/include/phosh/phosh-settings-enums.h ]; then
            echo "ERROR: phosh headers missing under /usr/include/phosh after host install" >&2
            exit 1
        fi
        # Gate (1): fail the image build if vendor phosh lacks org.atomos.PhoshHome.
        # shellcheck source=scripts/phosh/_lib-verify-vendor-phosh-atomos.sh
        source /work/iso-postmarketos/scripts/phosh/_lib-verify-vendor-phosh-atomos.sh
        atomos_verify_phosh_source_atomos_dbus "$PHOSH_SRC"
        atomos_verify_phosh_meson_build_has_atomos_dbus "$PHOSH_BUILD"
        atomos_verify_built_libphosh_has_atomos_dbus ""
    else
        echo "build-fairphone4-v2: WARN no rust/phosh/phosh/meson.build; using stock pmOS phosh."
    fi

    # Optional: vendor phoc (matches build-qemu).
    if [ -f /work/iso-postmarketos/vendor/phoc/meson.build ]; then
        echo "Building phoc from /work/iso-postmarketos/vendor/phoc..."
        apk add --no-interactive \
            wlroots-dev libinput-dev libdrm-dev pixman-dev libxkbcommon-dev \
            wayland-dev wayland-protocols eudev-dev json-glib-dev \
            gnome-desktop-dev gsettings-desktop-schemas-dev libseat-dev hwdata-dev
        PHOC_BUILD=/cache/phoc
        atomos_meson_ninja_build_install phoc "$PHOC_BUILD" /work/iso-postmarketos/vendor/phoc \
            --prefix=/usr \
            -Dtests=false -Dman=false \
            -Dembed-wlroots=enabled -Dxwayland=disabled \
            -Dwlroots:renderers=gles2 -Dwlroots:xwayland=disabled \
            -Dwlroots:libliftoff=disabled \
            --default-library=static
    fi

    # Optional: phosh-mobile-settings (depends on phosh .pc files).
    if [ -f /work/iso-postmarketos/vendor/phosh-mobile-settings/meson.build ]; then
        echo "Building phosh-mobile-settings..."
        apk add --no-interactive \
            desktop-file-utils gsound-dev libportal-dev libportal-gtk4 yaml-dev \
            feedbackd-dev lm-sensors-dev cellbroadcastd-dev gnome-desktop-dev
        PMS_BUILD=/cache/phosh-mobile-settings
        atomos_meson_ninja_build_install phosh-mobile-settings "$PMS_BUILD" \
            /work/iso-postmarketos/vendor/phosh-mobile-settings --prefix=/usr
    fi

    # Optional: vendor phosh-wallpapers / plymouth theme / sound theme.
    if [ -f /work/iso-postmarketos/vendor/phosh-wallpapers/meson.build ]; then
        echo "Building phosh-wallpapers..."
        PWP_BUILD=/cache/phosh-wallpapers
        atomos_meson_ninja_build_install phosh-wallpapers "$PWP_BUILD" \
            /work/iso-postmarketos/vendor/phosh-wallpapers --prefix=/usr
    fi
fi

if [ "${ATOMOS_V2:-0}" = "1" ]; then
    echo "Installing atomos-comp build dependencies..."
    apk add --no-interactive \
        libinput-dev libdrm-dev pixman-dev \
        eudev-dev libseat-dev hwdata-dev mesa-dev libdisplay-info-dev || true

    echo "Building atomos-comp..."
    cargo build --manifest-path /work/atomos-comp/Cargo.toml \
        --release --bin cosmic-comp
    install -d /target/usr/bin
    install -m 0755 /cache/cargo-target/release/cosmic-comp \
        /target/usr/bin/atomos-comp

    echo "Building AtomOS V2 Rust Components..."
    for component in atomos-lockscreen atomos-quick-settings atomos-top-bar; do
        if [ -f /work/iso-postmarketos/rust/$component/app-egui/Cargo.toml ]; then
            echo "Building $component..."
            cargo build --manifest-path /work/iso-postmarketos/rust/$component/app-egui/Cargo.toml \
                --release --bin ${component}-egui
            install -m 0755 /cache/cargo-target/release/${component}-egui \
                /target/usr/bin/$component
        fi
    done
    
    # Write atomos-session autostart script
    cat > /target/usr/bin/atomos-session <<EOF
#!/bin/sh
export XDG_CURRENT_DESKTOP=atomos
export XDG_SESSION_TYPE=wayland

(
    # Wait for compositor to create the Wayland socket
    while [ ! -S "\$XDG_RUNTIME_DIR/wayland-0" ] && [ ! -S "\$XDG_RUNTIME_DIR/wayland-1" ]; do
        sleep 0.1
    done
    
    if [ -S "\$XDG_RUNTIME_DIR/wayland-0" ]; then
        export WAYLAND_DISPLAY=wayland-0
    else
        export WAYLAND_DISPLAY=wayland-1
    fi

    # Start our UI components
    /usr/bin/atomos-home-bg &
    /usr/bin/atomos-top-bar &
    /usr/bin/atomos-quick-settings &
    /usr/bin/atomos-lockscreen &
    /usr/bin/atomos-overview-chat-ui --start &
    /usr/bin/atomos-app-handler --start &
) &

exec /usr/bin/atomos-comp
EOF
    chmod +x /target/usr/bin/atomos-session
fi

# ---- AtomOS Rust components --------------------------------------------
echo "Building atomos-overview-chat-ui..."
cargo build --manifest-path /work/iso-postmarketos/rust/atomos-overview-chat-ui/Cargo.toml \
    -p atomos-overview-chat-ui-app --release --bin atomos-overview-chat-ui
install -d /target/usr/local/bin /target/usr/libexec
install -m 0755 /cache/cargo-target/release/atomos-overview-chat-ui \
    /target/usr/local/bin/atomos-overview-chat-ui
ln -sf ../local/bin/atomos-overview-chat-ui /target/usr/bin/atomos-overview-chat-ui

if [ "${BUILD_HOME_BG:-1}" = "1" ] && [ -f /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml ]; then
    echo "Building atomos-home-bg..."
    cargo build --manifest-path /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml \
        --release --bin atomos-home-bg
    test -x /cache/cargo-target/release/atomos-home-bg
    install -d /target/usr/bin
    install -m 0755 /cache/cargo-target/release/atomos-home-bg \
        /target/usr/bin/atomos-home-bg
fi

if [ "${BUILD_APP_HANDLER:-1}" = "1" ] && [ -f /work/iso-postmarketos/rust/atomos-app-handler/app-gtk/Cargo.toml ]; then
    echo "Building atomos-app-handler..."
    cargo build --manifest-path /work/iso-postmarketos/rust/atomos-app-handler/app-gtk/Cargo.toml \
        --release --bin atomos-app-handler
    test -x /cache/cargo-target/release/atomos-app-handler
    install -d /target/usr/bin
    install -m 0755 /cache/cargo-target/release/atomos-app-handler \
        /target/usr/bin/atomos-app-handler
fi

if [ "${BUILD_TOP_BAR:-1}" = "1" ] && [ -f /work/iso-postmarketos/rust/atomos-top-bar/app-gtk/Cargo.toml ]; then
    echo "Building atomos-top-bar (Phosh)..."
    cargo build --manifest-path /work/iso-postmarketos/rust/atomos-top-bar/app-gtk/Cargo.toml \
        --release --bin atomos-top-bar
    test -x /cache/cargo-target/release/atomos-top-bar
    install -d /target/usr/bin
    install -m 0755 /cache/cargo-target/release/atomos-top-bar \
        /target/usr/bin/atomos-top-bar

    echo "Creating atomos-top-bar autostart entry..."
    install -d /target/etc/xdg/autostart
    cat > /target/etc/xdg/autostart/atomos-top-bar.desktop <<EOF
[Desktop Entry]
Type=Application
Name=AtomOS Top Bar
Comment=GTK4 layer-shell top bar replacement
Exec=/usr/bin/atomos-top-bar
OnlyShowIn=GNOME;Phosh;
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod 0644 /target/etc/xdg/autostart/atomos-top-bar.desktop
fi

# Recompile gschemas after staged installs (Meson skips this when DESTDIR is set).
apk add --no-interactive glib >/dev/null 2>&1 || true
glib-compile-schemas /target/usr/share/glib-2.0/schemas/ 2>/dev/null || true

if command -v ccache >/dev/null 2>&1; then
    echo "build-fairphone4-v2: ccache stats:"
    ccache -s 2>/dev/null || true
fi
