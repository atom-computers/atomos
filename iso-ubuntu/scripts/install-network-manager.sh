#!/bin/bash
set -ex
echo "Configuring NetworkManager for globally managed devices..."
if [ -d "/etc/NetworkManager/conf.d" ]; then
    touch "/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"
fi
