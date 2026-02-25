#!/bin/bash
set -ex
echo "Configuring default netplan for DHCP..."
mkdir -p /etc/netplan
cat > /etc/netplan/01-netcfg.yaml << 'NETPLAN'
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s8:
      dhcp4: true
    eth0:
      dhcp4: true
NETPLAN
chmod 600 /etc/netplan/01-netcfg.yaml
