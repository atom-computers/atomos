# shellcheck shell=bash
# scripts/_lib-rootfs-overlays.sh -- run the AtomOS overlay installers
# (agents, bt-tools, btlescan, overview-chat-ui, home-bg, wallpaper).
#
# Mirrors Step 4 of the original build-fairphone4.sh but in a focused
# helper. Re-runs the sshd policy sanitize at the end because some
# overlay scripts can re-drop the pmaports defaults.
#
# Required globals: ENGINE ALPINE_IMAGE ROOTFS_VOLUME REPO_TOP
# PROFILE_ENV_SOURCE BUILD_OVERVIEW_CHAT_UI BUILD_HOME_BG BUILD_APP_HANDLER

# Translate the host profile env path to its in-container equivalent
# (the heavy mount makes /work = $REPO_TOP, so anything under
# $REPO_TOP/<x> appears at /work/<x>).
_atomos_overlay_profile_env_in_container() {
    local p="$PROFILE_ENV_SOURCE"
    if [[ "$p" == "$REPO_TOP/"* ]]; then
        echo "/work/${p#"$REPO_TOP"/}"
    elif [[ "$p" != /* ]]; then
        echo "/work/iso-postmarketos/$p"
    else
        echo "$p"
    fi
}

_atomos_overlay_container_body() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=scripts/_lib-build-common.sh
    source "$lib_dir/_lib-build-common.sh"
    atomos_overlay_container_bash_setup
    cat <<'OVERLAY_BODY'

# --- local-first apk wrapper (AtomOS local package store) ------------
# Install the PATH `apk` shim. Overlay installers run as their own
# processes (atomos_bash sub-shells) but inherit PATH, so any `apk` they
# call transparently reuses the persistent cache dir and honours the
# host-selected network mode ($ATOMOS_APK_NET).
mkdir -p /usr/local/bin
install -m0755 /work/iso-postmarketos/scripts/container-apk-shim.sh /usr/local/bin/apk
export PATH="/usr/local/bin:$PATH"

run_helper() {
    local script="$1"; shift
    if [ -f "/work/iso-postmarketos/$script" ]; then
        echo "  -> $script $*"
        ROOTFS_DIR=/target "$@" atomos_bash "/work/iso-postmarketos/$script" "$PROFILE_ENV_CONTAINER" || true
    fi
}

run_helper scripts/rootfs/install-atomos-agents.sh
run_helper scripts/rootfs/install-bt-tools.sh
run_helper scripts/rootfs/install-btlescan.sh

if [ "${BUILD_OVERVIEW_CHAT_UI:-1}" = "1" ] \
    && [ -f /work/iso-postmarketos/scripts/overview-chat-ui/install-overview-chat-ui.sh ]; then
    echo "  -> install-overview-chat-ui.sh (layer-shell ON, runtime ON, autostart ON)"
    ROOTFS_DIR=/target \
        ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL_DEFAULT=1 \
        ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT=1 \
        ATOMOS_OVERVIEW_CHAT_UI_INSTALL_AUTOSTART=1 \
        ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT=0 \
        ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT=0 \
        atomos_bash /work/iso-postmarketos/scripts/overview-chat-ui/install-overview-chat-ui.sh \
        "$PROFILE_ENV_CONTAINER"
fi

if [ "${BUILD_HOME_BG:-1}" = "1" ] \
    && [ -f /work/iso-postmarketos/scripts/home-bg/install-atomos-home-bg.sh ]; then
    echo "  -> install-atomos-home-bg.sh (autostart ON, runtime ON)"
    ROOTFS_DIR=/target \
        ATOMOS_HOME_BG_ENABLE_RUNTIME_DEFAULT=1 \
        ATOMOS_HOME_BG_INSTALL_AUTOSTART=1 \
        atomos_bash /work/iso-postmarketos/scripts/home-bg/install-atomos-home-bg.sh \
        "$PROFILE_ENV_CONTAINER"
fi

if [ "${BUILD_APP_HANDLER:-1}" = "1" ] \
    && [ -f /work/iso-postmarketos/scripts/app-handler/install-app-handler.sh ]; then
    echo "  -> install-app-handler.sh (autostart ON, runtime ON)"
    ROOTFS_DIR=/target \
        ATOMOS_APP_HANDLER_ENABLE_RUNTIME_DEFAULT=1 \
        ATOMOS_APP_HANDLER_INSTALL_AUTOSTART=1 \
        atomos_bash /work/iso-postmarketos/scripts/app-handler/install-app-handler.sh \
        "$PROFILE_ENV_CONTAINER"
fi

# Wallpapers.
if [ -f /work/iso-postmarketos/data/wallpapers/gargantua-black.jpg ]; then
    mkdir -p /target/usr/share/backgrounds/gnome \
             /target/usr/share/backgrounds/atomos \
             /target/usr/share/backgrounds
    for d in gnome atomos ""; do
        cp -f /work/iso-postmarketos/data/wallpapers/gargantua-black.jpg \
              "/target/usr/share/backgrounds/${d:+$d/}gargantua-black.jpg"
    done
fi

# sshd policy sanitize (overlay installers can re-drop pmaports defaults).
if [ -f /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf ]; then
    sed -i '/^[[:space:]]*UsePAM[[:space:]]\+/d' /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    sed -i '/^[[:space:]]*PasswordAuthentication/d' /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    echo "PasswordAuthentication yes" >> /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    sed -i '/^[[:space:]]*PermitRootLogin/d' /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
    echo "PermitRootLogin no" >> /target/etc/ssh/sshd_config.d/50-postmarketos-ui-policy.conf
fi
if [ -x /target/usr/bin/ssh-keygen ]; then
    chroot /target /usr/bin/ssh-keygen -A >/dev/null 2>&1 || true
fi

# apk post-installs may re-enable nftables in default; keep developer USB/SSH
# reachable unless the profile explicitly opts in.
if [ "${ATOMOS_ENABLE_NFTABLES:-0}" != "1" ]; then
    rm -f /target/etc/runlevels/default/nftables \
          /target/etc/runlevels/boot/nftables
fi
if [ "${ATOMOS_DEBUG_FIREWALL:-0}" = "1" ]; then
    rm -f /target/etc/nftables.d/99_drop_log.nft
fi
OVERLAY_BODY
}

atomos_apply_overlays() {
    echo "=== build-fairphone4-v2: apply AtomOS overlays ==="
    local profile_in_container
    profile_in_container="$(_atomos_overlay_profile_env_in_container)"
    "$ENGINE" run --rm --platform "linux/arm64" \
        -v "$ROOTFS_VOLUME:/target" \
        -v "$REPO_TOP:/work" \
        -v "$MESON_CACHE_MOUNT:/cache" \
        -e ATOMOS_ENABLE_NFTABLES="${ATOMOS_ENABLE_NFTABLES:-0}" \
        -e ATOMOS_DEBUG_FIREWALL="${ATOMOS_DEBUG_FIREWALL:-${ATOMOS_DEVELOPER_MODE:-0}}" \
        -v "$PKG_CACHE_MOUNT_SRC:$PKG_CACHE_MOUNT" \
        -e BUILD_OVERVIEW_CHAT_UI="$BUILD_OVERVIEW_CHAT_UI" \
        -e BUILD_HOME_BG="$BUILD_HOME_BG" \
        -e BUILD_APP_HANDLER="${BUILD_APP_HANDLER:-1}" \
        -e PROFILE_ENV_CONTAINER="$profile_in_container" \
        -e ATOMOS_APK_CACHE_DIR="$APK_CACHE_CONTAINER_DIR" \
        -e ATOMOS_APK_NET="${ATOMOS_APK_NET:---update-cache}" \
        "$ALPINE_IMAGE" /bin/sh -eu -c "$(_atomos_overlay_container_body)"
}
