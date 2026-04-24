#!/bin/sh
# shellcheck disable=SC1091,SC2154

export MIR_SERVER_CURSOR=null
# Set maliit-keyboard as the input module
export QT_IM_MODULE=maliit
export MALIIT_FORCE_DBUS_CONNECTION=1
# Declare the Lomiri UI Toolkit icon theme
export UITK_ICON_THEME=suru
# logind only sets DISPLAY so we need to set this
export WAYLAND_DISPLAY=wayland-0
# Use logind for session management
export LOMIRI_AS_SYSTEMD_UNIT=1
# Applications require unthrottled touch input
export QML_NO_TOUCH_COMPRESSION=1
# Fix font rendering on some Adreno GPUs
export QT_ENABLE_GLYPH_CACHE_WORKAROUND=1

# Enable Xwayland
export MIR_SERVER_ENABLE_X11=1
export MIR_SERVER_XWAYLAND_PATH=/usr/bin/Xwayland

# Setup base HOME directories
xdg-user-dirs-update

# Debug environment variables
#export G_MESSAGES_DEBUG=all
#export env QT_LOGGING_RULES='qt.qpa.miral.*=true'
#export env QT_LOGGING_RULES='qt.qpa.miroil.*=true'
#export env QT_LOGGING_RULES='qtmir.*=true'

# Pass required env variables to dbus
dbus-update-activation-environment MALIIT_FORCE_DBUS_CONNECTION=1
dbus-update-activation-environment WAYLAND_DISPLAY

# Device-specific adjustments
. /usr/share/misc/source_deviceinfo
if [ "$deviceinfo_codename" = "qemu-amd64" ]; then
	export MIR_MESA_KMS_DISABLE_MODESET_PROBE=1
elif [ "$deviceinfo_codename" = "pine64-pinephone" ]; then
	export MIR_MESA_KMS_USE_DRM_DEVICE=card1
	export QT_SCALE_FACTOR=2 # TODO: Automatically set this based upon device scaling factor instead of adding it in a per-device adjustment
fi

superd &

# Start Pipewire
/usr/libexec/pipewire-launcher &

lomiri
