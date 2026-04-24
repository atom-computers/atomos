#!/bin/sh
# Enable/disable tethering USB mode by delegating network operations to NetworkManager.
# Dynamically generate NetworkManager connection because it is only available in the right USB mode.
#
# Copyright (c) Dylan Van Assche (2025)

IFACE=usb0
CONNECTION_NAME="USB Tethering Mode"

up() {
    # Bring interface and NetworkManager connection up
    nmcli connection add con-name "$CONNECTION_NAME" type ethernet \
        ifname "$IFACE" ipv4.method shared
    nmcli connection up "$CONNECTION_NAME"
}

down() {
    # Bring NetworkManager connection down
    nmcli connection down "$CONNECTION_NAME"
    nmcli connection delete "$CONNECTION_NAME"

    # NetworkManager brings the interface up automatically,
    # but doesn't remove it when bringing down.
    ifconfig "$IFACE" down
}

case $1 in
    up)
        up
        ;;
    down)
        down
        ;;
    *)
        echo "need an argument (up|down)"
        exit 0
        ;;
esac

