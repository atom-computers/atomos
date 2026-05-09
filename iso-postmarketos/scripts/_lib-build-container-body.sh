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

# ---- meson cache helper ------------------------------------------------
meson_cache_setup() {
    _build_dir="$1"; shift
    _src_dir="$1"; shift
    _hash=$(printf "%s\n" "$_src_dir" "CC=${CC:-}" "CXX=${CXX:-}" "AR=${AR:-}" "$@" \
            | sha256sum | cut -d" " -f1)
    _marker="$_build_dir/.atomos-meson-args"
    if [ -f "$_build_dir/build.ninja" ] && [ -f "$_marker" ] \
        && [ "$(cat "$_marker" 2>/dev/null)" = "$_hash" ]; then
        echo "build-fairphone4-v2: reusing meson cache: $_build_dir"
    elif [ -f "$_build_dir/build.ninja" ]; then
        echo "build-fairphone4-v2: meson args changed -> reconfigure: $_build_dir"
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
        meson_cache_setup "$GMOBILE_BUILD" "$GMOBILE_DIR" --prefix=/usr -Dtests=false -Dgtk_doc=false
        ninja -C "$GMOBILE_BUILD"
        # Install into the BUILD /usr too (not just /target) so phosh can
        # find gmobile.h via pkg-config Cflags.
        ninja -C "$GMOBILE_BUILD" install
        DESTDIR=/target ninja -C "$GMOBILE_BUILD" install
    else
        echo "build-fairphone4-v2: WARN no gmobile/meson.build found; skipping gmobile build."
    fi

    export PKG_CONFIG_PATH="/target/usr/lib/pkgconfig:/target/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

    PHOSH_SRC=/work/iso-postmarketos/rust/phosh/phosh
    PHOSH_BUILD=/cache/phosh
    if [ -f "$PHOSH_SRC/meson.build" ]; then
        echo "Building vendor phosh from: $PHOSH_SRC"
        meson_cache_setup "$PHOSH_BUILD" "$PHOSH_SRC" --prefix=/usr -Dtests=false
        ninja -C "$PHOSH_BUILD"
        ninja -C "$PHOSH_BUILD" install
        DESTDIR=/target ninja -C "$PHOSH_BUILD" install
        if [ ! -f /usr/include/phosh/phosh-settings-enums.h ]; then
            echo "ERROR: phosh headers missing under /usr/include/phosh after host install" >&2
            exit 1
        fi
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
        meson_cache_setup "$PHOC_BUILD" /work/iso-postmarketos/vendor/phoc --prefix=/usr \
            -Dtests=false -Dman=false \
            -Dembed-wlroots=enabled -Dxwayland=disabled \
            -Dwlroots:renderers=gles2 -Dwlroots:xwayland=disabled \
            -Dwlroots:libliftoff=disabled \
            --default-library=static
        ninja -C "$PHOC_BUILD"
        ninja -C "$PHOC_BUILD" install
        DESTDIR=/target ninja -C "$PHOC_BUILD" install
    fi

    # Optional: phosh-mobile-settings (depends on phosh .pc files).
    if [ -f /work/iso-postmarketos/vendor/phosh-mobile-settings/meson.build ]; then
        echo "Building phosh-mobile-settings..."
        apk add --no-interactive \
            desktop-file-utils gsound-dev libportal-dev libportal-gtk4 yaml-dev \
            feedbackd-dev lm-sensors-dev cellbroadcastd-dev gnome-desktop-dev
        PMS_BUILD=/cache/phosh-mobile-settings
        meson_cache_setup "$PMS_BUILD" /work/iso-postmarketos/vendor/phosh-mobile-settings --prefix=/usr
        ninja -C "$PMS_BUILD"
        ninja -C "$PMS_BUILD" install
        DESTDIR=/target ninja -C "$PMS_BUILD" install
    fi

    # Optional: vendor phosh-wallpapers / plymouth theme / sound theme.
    if [ -f /work/iso-postmarketos/vendor/phosh-wallpapers/meson.build ]; then
        echo "Building phosh-wallpapers..."
        PWP_BUILD=/cache/phosh-wallpapers
        meson_cache_setup "$PWP_BUILD" /work/iso-postmarketos/vendor/phosh-wallpapers --prefix=/usr
        ninja -C "$PWP_BUILD"
        DESTDIR=/target ninja -C "$PWP_BUILD" install
    fi
fi

# ---- AtomOS Rust components --------------------------------------------
echo "Building atomos-overview-chat-ui..."
cargo build --manifest-path /work/iso-postmarketos/rust/atomos-overview-chat-ui/Cargo.toml \
    -p atomos-overview-chat-ui-app --release --bin atomos-overview-chat-ui
install -d /target/usr/local/bin /target/usr/libexec
install -m 0755 /work/iso-postmarketos/rust/atomos-overview-chat-ui/target/release/atomos-overview-chat-ui \
    /target/usr/local/bin/atomos-overview-chat-ui
ln -sf ../local/bin/atomos-overview-chat-ui /target/usr/bin/atomos-overview-chat-ui

if [ "${BUILD_HOME_BG:-1}" = "1" ] && [ -f /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml ]; then
    echo "Building atomos-home-bg..."
    cargo build --manifest-path /work/iso-postmarketos/rust/atomos-home-bg/app-gtk/Cargo.toml \
        --release --bin atomos-home-bg
    test -x /work/iso-postmarketos/rust/atomos-home-bg/target/release/atomos-home-bg
fi

# Recompile gschemas after staged installs (Meson skips this when DESTDIR is set).
apk add --no-interactive glib >/dev/null 2>&1 || true
glib-compile-schemas /target/usr/share/glib-2.0/schemas/ 2>/dev/null || true

if command -v ccache >/dev/null 2>&1; then
    echo "build-fairphone4-v2: ccache stats:"
    ccache -s 2>/dev/null || true
fi
