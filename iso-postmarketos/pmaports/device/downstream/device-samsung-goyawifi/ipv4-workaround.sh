#!/bin/sh
# It's seems that the networkmanager can't properly set the interface IP
# and routes on this device. Setting them using iproute2 or net-tools
# makes the interface to work with network, using static or DHCP ipv4.

IF=$1
STATUS=$2

if [ "$IF" == "wlan0" ]; then
	if [ "$STATUS" == "up" ]; then
		logger -s "Setting IP on $IF"
		logger -s "IP4_ADDRESS_0 $IP4_ADDRESS_0"
		logger -s "IP4_GATEWAY $IP4_GATEWAY"
		logger -s "IP4_ROUTE_0 $IP4_ROUTE_0"
		ip address add ${IP4_ADDRESS_0% *} brd + dev $IF
		ip route add default via ${IP4_ADDRESS_0#* } dev $IF
	fi
fi
