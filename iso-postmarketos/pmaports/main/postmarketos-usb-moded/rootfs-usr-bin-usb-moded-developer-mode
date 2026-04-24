#!/bin/sh
# Enable/disable developer USB mode by delegating network operations to NetworkManager
# Dynamically generate NetworkManager connection because it is only available in the right USB mode
#
# Copyright (c) Dylan Van Assche (2025)

IFACE=usb0
IP_ADDRESS_SERVER=172.16.42.1
IP_ADDRESS_CLIENT=172.16.42.2
CONNECTION_NAME="USB Developer Mode"

up() {
    # Bring interface and NetworkManager connection up
    nmcli connection add con-name "$CONNECTION_NAME" type ethernet \
        ifname "$IFACE" ipv4.method manual ipv4.addresses "$IP_ADDRESS_SERVER"/16
    nmcli connection up "$CONNECTION_NAME"

    # Start DHCP server
    unudhcpd -i "$IFACE" -s "$IP_ADDRESS_SERVER" -c "$IP_ADDRESS_CLIENT" &
}

down() {
    # Stop DHCP server
    killall -9 unudhcpd

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

