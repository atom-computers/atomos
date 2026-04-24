#!/bin/sh

# This is a trimmed down version of setup_usb_network_configfs from
# pmOS's init_functions.sh

# See: https://www.kernel.org/doc/Documentation/usb/gadget_configfs.txt
CONFIGFS=/sys/kernel/config/usb_gadget
SYS=/sys/class/android_usb/android0

# Create an usb gadet configuration
mkdir $CONFIGFS/g1 || echo "initfs-hook: Couldn't create $CONFIGFS/g1"

# Create rndis function.
mkdir $CONFIGFS/g1/functions/rndis.usb0 \
	|| echo "initfs-hook: Couldn't create $CONFIGFS/g1/functions/rndis.usb0"

# Create configuration instance for the gadget
mkdir $CONFIGFS/g1/configs/c.1 \
	|| echo "initfs-hook: Couldn't create $CONFIGFS/g1/configs/c.1"

# Link the rndis instance to the configuration
ln -s $CONFIGFS/g1/functions/rndis.usb0 $CONFIGFS/g1/configs/c.1 \
	|| echo "initfs-hook: Couldn't symlink rndis.usb0"

echo "0" >"$SYS/enable"
echo "$(ls /sys/class/udc)" > $CONFIGFS/g1/UDC || echo "  Couldn't write UDC"
echo "rndis" >"$SYS/functions"
echo "1" >"$SYS/enable"
